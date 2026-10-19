import Foundation
import Synchronization
import Testing
@testable import ManagerKit

/// Zählt gestartete, laufende und abgebrochene Scans sowie die höchste Parallelität.
private final class ScanLedger: Sendable {
    /// Zählerstand, unter einem einzigen Lock gelesen, damit die Werte zueinander passen.
    struct Snapshot {
        var started = 0, running = 0, peak = 0, cancelled = 0
    }

    private let state = Mutex(Snapshot())
    var snapshot: Snapshot { state.withLock { $0 } }

    func enter() {
        state.withLock { $0.started += 1; $0.running += 1; $0.peak = max($0.peak, $0.running) }
    }

    func leave(cancelled: Bool) {
        state.withLock { $0.running -= 1; if cancelled { $0.cancelled += 1 } }
    }

    /// Wartet höchstens `timeout`, bis ein Zählerstand `condition` erfüllt, und liefert genau diesen (sonst `nil`).
    func wait(timeout: Duration = .seconds(5), until condition: (Snapshot) -> Bool) async -> Snapshot? {
        let deadline = ContinuousClock.now + timeout
        while true {
            let current = snapshot
            if condition(current) { return current }
            guard ContinuousClock.now < deadline else { return nil }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Scan mit fester Dauer; vermerkt, ob er durch Abbruch vorzeitig endete.
private struct SlowProvider: StorageCategoryProvider {
    let category: StorageCategory
    let ledger: ScanLedger
    let duration: Duration

    init(_ id: String, _ ledger: ScanLedger, duration: Duration = .milliseconds(30)) {
        category = StorageCategory(id: id, title: id, summary: "", risk: .low, roots: [])
        self.ledger = ledger
        self.duration = duration
    }

    func scan() async -> StorageCategoryReport {
        ledger.enter()
        let wasCancelled = (try? await Task.sleep(for: duration)) == nil
        ledger.leave(cancelled: wasCancelled)
        return StorageCategoryReport(category: category, status: .available, items: [])
    }
}

@Suite struct StorageScannerTests {
    @Test func yieldsEveryReportWithBoundedConcurrency() async {
        let ledger = ScanLedger()
        let scanner = StorageScanner(providers: (0..<8).map { SlowProvider("p\($0)", ledger) }, maximumConcurrency: 3)
        var ids: [String] = []
        for await report in scanner.scan() { ids.append(report.id) }
        #expect(Set(ids) == Set((0..<8).map { "p\($0)" }))
        #expect(ids.count == 8)
        let final = ledger.snapshot
        #expect(final.peak <= 3)
        #expect(final.cancelled == 0)
    }

    @Test func stoppingEarlyCancelsRemainingScans() async throws {
        // p0 ist sofort fertig, alle anderen liefen ohne Abbruch eine Minute.
        let ledger = ScanLedger()
        let providers = (0..<8).map { SlowProvider("p\($0)", ledger, duration: $0 == 0 ? .zero : .seconds(60)) }
        let scanner = StorageScanner(providers: providers, maximumConcurrency: 2)
        var ids: [String] = []
        for await report in scanner.scan() { ids.append(report.id); break }

        #expect(ids == ["p0"])
        // Ein spät startender Nachrücker (p2) kann erst nach dem Stand eintreten; der Stand selbst bleibt stimmig.
        let settled = await ledger.wait { $0.running == 0 }
        let snapshot = try #require(settled, "laufende Scans wurden nach dem Abbruch nicht beendet")
        // Höchstens die beiden ersten und der nach p0 nachgerückte Scan sind gestartet, und alle wartenden wurden abgebrochen.
        #expect(snapshot.started <= 3)
        #expect(snapshot.cancelled == snapshot.started - 1)
        #expect(snapshot.peak <= 2)
    }

    @Test func cancellingConsumerTaskCancelsScans() async throws {
        let ledger = ScanLedger()
        let scanner = StorageScanner(providers: (0..<8).map { SlowProvider("p\($0)", ledger, duration: .seconds(60)) },
                                     maximumConcurrency: 2)
        let consumer = Task {
            var count = 0
            for await _ in scanner.scan() { count += 1 }
            return count
        }
        #expect(await ledger.wait { $0.started == 2 } != nil)
        consumer.cancel()

        #expect(await consumer.value == 0)
        let settled = await ledger.wait { $0.running == 0 }
        let snapshot = try #require(settled, "laufende Scans wurden nach dem Abbruch nicht beendet")
        #expect(snapshot.started == 2)
        #expect(snapshot.cancelled == 2)
    }

    @Test func emptyProviderListFinishesImmediately() async {
        var count = 0
        for await _ in StorageScanner(providers: []).scan() { count += 1 }
        #expect(count == 0)
    }
}
