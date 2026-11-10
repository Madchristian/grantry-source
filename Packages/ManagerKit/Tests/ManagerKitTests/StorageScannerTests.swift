import Foundation
import Synchronization
import Testing
@testable import ManagerKit

/// Zählt gestartete, laufende und abgebrochene Scans sowie die höchste Parallelität.
///
/// Tests warten ereignisgesteuert auf einen Zählerstand statt mit Wanduhr-Frist: Unter Last starten die Scan-Tasks
/// spät, eine feste Frist flackert dann (Issue 214). Hänger fängt das `.timeLimit` der Suite ab.
private final class ScanLedger: Sendable {
    /// Zählerstand, unter einem einzigen Lock gelesen, damit die Werte zueinander passen.
    struct Snapshot {
        var started = 0, running = 0, peak = 0, cancelled = 0
    }

    private struct Waiter {
        let condition: @Sendable (Snapshot) -> Bool
        let continuation: CheckedContinuation<Snapshot, any Error>
    }

    private struct State {
        var snapshot = Snapshot()
        var nextID = 0
        var waiters: [Int: Waiter] = [:]
    }

    private let state = Mutex(State())
    var snapshot: Snapshot { state.withLock { $0.snapshot } }

    func enter() {
        update { $0.started += 1; $0.running += 1; $0.peak = max($0.peak, $0.running) }
    }

    func leave(cancelled: Bool) {
        update { $0.running -= 1; if cancelled { $0.cancelled += 1 } }
    }

    /// Kehrt zurück, sobald ein Zählerstand `condition` erfüllt, und liefert genau diesen. Ein Abbruch des wartenden
    /// Tasks (etwa durch `.timeLimit`) wirft `CancellationError`.
    func wait(until condition: @escaping @Sendable (Snapshot) -> Bool) async throws -> Snapshot {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Snapshot, any Error>) in
                // Unter der Sperre: Ein Abbruch vor der Registrierung wird hier gesehen, einer danach vom Handler.
                let outcome: Result<Snapshot, any Error>? = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if condition(state.snapshot) { return .success(state.snapshot) }
                    state.waiters[id] = Waiter(condition: condition, continuation: continuation)
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Ändert den Zählerstand und weckt jeden Wartenden, dessen Bedingung genau dieser Stand erfüllt.
    private func update(_ change: (inout Snapshot) -> Void) {
        let (satisfied, current) = state.withLock { state in
            change(&state.snapshot)
            let current = state.snapshot
            let ids = state.waiters.filter { $0.value.condition(current) }.map(\.key)
            return (ids.compactMap { state.waiters.removeValue(forKey: $0) }, current)
        }
        satisfied.forEach { $0.continuation.resume(returning: current) }
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

private extension Duration {
    /// Länger als das Zeitlimit der Suite: Ein solcher Scan endet im Test nur durch Abbruch.
    static let unlessCancelled = Duration.seconds(3_600)
}

@Suite(.timeLimit(.minutes(1))) struct StorageScannerTests {
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
        // p0 ist sofort fertig, alle anderen liefen ohne Abbruch länger als das Zeitlimit der Suite.
        let ledger = ScanLedger()
        let providers = (0..<8).map { SlowProvider("p\($0)", ledger, duration: $0 == 0 ? .zero : .unlessCancelled) }
        let scanner = StorageScanner(providers: providers, maximumConcurrency: 2)
        var ids: [String] = []
        for await report in scanner.scan() { ids.append(report.id); break }

        #expect(ids == ["p0"])
        // Ein spät startender Nachrücker (p2) kann erst nach dem Stand eintreten; der Stand selbst bleibt stimmig.
        let snapshot = try await ledger.wait { $0.running == 0 }
        // Höchstens die beiden ersten und der nach p0 nachgerückte Scan sind gestartet, und alle wartenden wurden abgebrochen.
        #expect(snapshot.started <= 3)
        #expect(snapshot.cancelled == snapshot.started - 1)
        #expect(snapshot.peak <= 2)
    }

    @Test func cancellingConsumerTaskCancelsScans() async throws {
        let ledger = ScanLedger()
        let providers = (0..<8).map { SlowProvider("p\($0)", ledger, duration: .unlessCancelled) }
        let scanner = StorageScanner(providers: providers, maximumConcurrency: 2)
        let consumer = Task {
            var count = 0
            for await _ in scanner.scan() { count += 1 }
            return count
        }
        _ = try await ledger.wait { $0.started == 2 }
        consumer.cancel()

        #expect(await consumer.value == 0)
        // Endet nur durch Abbruch der Scans; ohne ihn greift das Zeitlimit der Suite.
        let snapshot = try await ledger.wait { $0.running == 0 }
        #expect(snapshot.started == 2)
        #expect(snapshot.cancelled == 2)
    }

    @Test func emptyProviderListFinishesImmediately() async {
        var count = 0
        for await _ in StorageScanner(providers: []).scan() { count += 1 }
        #expect(count == 0)
    }
}
