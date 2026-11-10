import Foundation
import Testing
import TestSupport
@testable import ManagerKit

/// Belegungsdaten nur im Speicher, nach 10 min ohne Ansicht verworfen (TM-15.2, #401; Spec § 4.4).
@Suite(.timeLimit(.minutes(1))) struct OccupancyStoreTests {
    private let fileSystem = FakeOccupancyFileSystem()
    private let journal = FakeOccupancyJournal()
    private let clock = TestClock()

    init() {
        fileSystem.addFile("a/b", bytes: 1_000)
    }

    private func makeStore() -> OccupancyStore {
        OccupancyStore(scanner: .testing(fileSystem, journal: journal), clock: clock)
    }

    /// Wartet, bis die Ablauffrist abgelaufen ist und der Speicher geleert hat.
    private func expectDiscarded(_ store: OccupancyStore) async {
        while await store.tree != nil { await Task.yield() }
    }

    @Test func discardsTheTreeTenMinutesAfterTheViewIsHidden() async throws {
        let store = makeStore()
        await store.setVisible(true)
        _ = try await store.scan(fileSystem.rootPath)
        await store.setVisible(false)

        await clock.waitForSleeper(until: .at(.seconds(600)))
        #expect(clock.advance(by: .seconds(599)) == 0)
        #expect(await store.tree != nil)
        clock.advance(by: .seconds(1))
        await expectDiscarded(store)
    }

    /// Die Ansicht nennt je Scan, was ausgelassen wird (ohne Festplattenvollzugriff die geschützten Orte).
    @Test func scanLeavesOutTheGivenFolders() async throws {
        fileSystem.addFile("geschuetzt/c", bytes: 500)
        let store = makeStore()

        let tree = try await store.scan(fileSystem.rootPath, excluding: [fileSystem.path("geschuetzt")])

        let excluded = try #require(tree.folder(atPath: fileSystem.path("geschuetzt")))
        #expect(excluded.state == .uncaptured(.excluded))
        #expect(tree.root.allocatedBytes == 1_000)
        #expect(try await store.scan(fileSystem.rootPath).root.allocatedBytes == 1_500)
    }

    @Test func keepsTheTreeWhileTheViewIsVisible() async throws {
        let store = makeStore()
        await store.setVisible(true)
        _ = try await store.scan(fileSystem.rootPath)
        #expect(clock.advance(by: .seconds(3_600)) == 0)
        #expect(await store.tree?.root.allocatedBytes == 1_000)
    }

    @Test func showingTheViewAgainCancelsTheDiscard() async throws {
        let store = makeStore()
        _ = try await store.scan(fileSystem.rootPath)
        await clock.waitForSleeper(until: .at(.seconds(600)))
        await store.setVisible(true)
        clock.advance(by: .seconds(600))
        #expect(await store.tree != nil)

        await store.setVisible(false)
        await clock.waitForSleeper(until: .at(.seconds(1_200)))
        clock.advance(by: .seconds(600))
        await expectDiscarded(store)
    }

    /// Ein Scan ohne Ansicht läuft ebenfalls nach 10 min ab.
    @Test func scanWithoutViewExpiresToo() async throws {
        let store = makeStore()
        _ = try await store.scan(fileSystem.rootPath)
        await clock.waitForSleeper(until: .at(.seconds(600)))
        clock.advance(by: .seconds(600))
        await expectDiscarded(store)
    }

    @Test func rescanReusesTheStoredTree() async throws {
        let store = makeStore()
        await store.setVisible(true)
        _ = try await store.scan(fileSystem.rootPath)
        fileSystem.resetReads()

        _ = try await store.scan(fileSystem.rootPath)

        #expect(fileSystem.reads.isEmpty)
        #expect(journal.calls.contains("changes"))
    }

    @Test func discardForgetsTheTree() async throws {
        let store = makeStore()
        await store.setVisible(true)
        _ = try await store.scan(fileSystem.rootPath)
        await store.discard()
        #expect(await store.tree == nil)
        fileSystem.resetReads()
        _ = try await store.scan(fileSystem.rootPath)
        #expect(fileSystem.reads.count == 2)
    }

    @Test func secondScanWhileRunningIsRejected() async throws {
        let reached = Latch(), proceed = Latch()
        fileSystem.onRead { path in
            guard path == fileSystem.rootPath else { return }
            reached.release()
            proceed.wait()
        }
        let store = makeStore()
        let first = Task { try await store.scan(fileSystem.rootPath) }
        await onOwnThread { reached.wait() }
        #expect(await store.isScanning)

        await #expect(throws: OccupancyScanError.busy) { try await store.scan(fileSystem.rootPath) }

        proceed.release()
        _ = try await first.value
        #expect(await !store.isScanning)
    }

    /// Ein abgebrochener Scan behält das letzte Ergebnis.
    @Test func cancelledScanKeepsThePreviousTree() async throws {
        let store = makeStore()
        await store.setVisible(true)
        let previous = try await store.scan(fileSystem.rootPath)
        journal.report(nil)
        let rescan = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.scan(fileSystem.rootPath)
        }
        await #expect(throws: CancellationError.self) { try await rescan.value }
        #expect(await store.tree?.root == previous.root)
    }
}
