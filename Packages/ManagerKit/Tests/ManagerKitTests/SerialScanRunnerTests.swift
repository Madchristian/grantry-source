import Testing
@testable import ManagerKit

/// Abbrechbarer Scan auf einer seriellen Queue (#611): Ein Abbruch verwirft das Ergebnis, ein neuer Lauf wartet auf das
/// tatsächliche Ende des vorigen, und wiederholtes Abbrechen und Neustarten reicht keine Arbeit zusätzlich ein. Die
/// Arbeit ist ein Test-Double, das bis zur Freigabe blockiert – wie ein Systemaufruf auf einer `BlockingWorkQueue`.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct SerialScanRunnerTests {
    private struct ConditionTimedOut: Error {}

    /// Zählt gestartete und gleichzeitig laufende Arbeiten; jede wartet, bis der Test sie freigibt.
    private actor Work {
        private(set) var started: [Int] = []
        private(set) var maximumRunning = 0
        private var running = 0
        private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
        private var released: Set<Int> = []

        func perform(_ id: Int) async -> Int {
            started.append(id)
            running += 1
            maximumRunning = max(maximumRunning, running)
            if !released.contains(id) {
                await withCheckedContinuation { gates[id] = $0 }
            }
            running -= 1
            return id
        }

        func release(_ id: Int) {
            released.insert(id)
            gates.removeValue(forKey: id)?.resume()
        }
    }

    private let work = Work()
    private let runner = SerialScanRunner()
    private var finished: [Int] { results.values }
    private let results = Results()

    @MainActor private final class Results {
        var values: [Int] = []
    }

    private func start(_ id: Int) {
        let work = work, results = results
        runner.start({ await work.perform(id) }) { results.values.append($0) }
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw ConditionTimedOut() }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Gibt laufenden Aufgaben Gelegenheit weiterzulaufen – für die Prüfung, dass etwas *nicht* geschieht.
    private func settle() async throws {
        for _ in 0..<20 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func finishedRunDeliversItsResult() async throws {
        start(1)
        await work.release(1)
        await runner.settled()
        #expect(finished == [1])
        #expect(!runner.isRunning)
    }

    @Test func cancelledRunDropsItsResult() async throws {
        start(1)
        try await eventually { await work.started == [1] }
        runner.cancel()
        #expect(!runner.isRunning)
        await work.release(1)
        await runner.settled()
        #expect(finished.isEmpty)
    }

    @Test func restartWaitsForTheCancelledWorkInsteadOfQueueingMore() async throws {
        start(1)
        try await eventually { await work.started == [1] }
        runner.cancel()
        start(2)
        #expect(runner.isRunning)
        try await settle()
        // Die abgebrochene Arbeit blockiert noch: Die neue wird erst nach ihrem Ende eingereicht.
        #expect(await work.started == [1])
        await work.release(1)
        try await eventually { await work.started == [1, 2] }
        await work.release(2)
        await runner.settled()
        #expect(finished == [2])
        #expect(await work.maximumRunning == 1)
    }

    @Test func repeatedCancelAndRestartRunsOnlyTheLatest() async throws {
        start(1)
        try await eventually { await work.started == [1] }
        for id in 2...5 {
            runner.cancel()
            start(id)
        }
        try await settle()
        #expect(await work.started == [1])
        await work.release(1)
        try await eventually { await work.started == [1, 5] }
        await work.release(5)
        await runner.settled()
        // Die Läufe 2 bis 4 wurden ersetzt, bevor sie Arbeit einreichen konnten.
        #expect(await work.started == [1, 5])
        #expect(finished == [5])
        #expect(await work.maximumRunning == 1)
    }

    @Test func cancellingTwiceIsHarmlessAndAFreshScanRunsAtOnce() async throws {
        start(1)
        try await eventually { await work.started == [1] }
        runner.cancel()
        runner.cancel()
        await work.release(1)
        await runner.settled()
        #expect(finished.isEmpty)
        await work.release(2)
        start(2)
        await runner.settled()
        #expect(finished == [2])
    }

    @Test func cancelWithoutRunDoesNothing() async {
        runner.cancel()
        #expect(!runner.isRunning)
        await runner.settled()
        #expect(finished.isEmpty)
    }
}
