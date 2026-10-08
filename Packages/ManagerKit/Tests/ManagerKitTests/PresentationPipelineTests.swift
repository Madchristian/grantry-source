import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

/// Zählt Berechnungen und hält sie mit `gates` je Eingabe an.
private final class ScriptedComputation: Sendable {
    private let calls = Mutex<[Int]>([])
    private let gates: [Int: Gate]

    init(gates: [Int: Gate] = [:]) {
        self.gates = gates
    }

    var computedCounts: [Int] { calls.withLock { $0 } }

    func compute(_ input: PresentationInput) async -> PresentationSnapshot {
        let count = input.findings.count
        calls.withLock { $0.append(count) }
        try? await gates[count]?.wait()
        return input.make(now: TestData.date)
    }
}

@MainActor
@Suite struct PresentationPipelineTests {
    private static func input(findings: Int, events: [HistoryEvent] = []) -> PresentationInput {
        let item = TestData.item("com.vendor.agent")
        return PresentationInput(
            snapshot: TestData.snapshot(items: [item]),
            findings: (0..<findings).map { index in
                RiskFinding(rule: .unsignedProgram, severity: .low, recordID: item.id, message: "Hinweis \(index)")
            },
            events: events,
            recentAdditions: []
        )
    }

    @Test(.timeLimit(.minutes(1))) func computesOnceAndDelivers() async {
        let computation = ScriptedComputation()
        var delivered: [PresentationSnapshot?] = []
        let pipeline = PresentationPipeline(compute: computation.compute) { delivered.append($0) }

        pipeline.update(Self.input(findings: 1))
        await pipeline.waitUntilIdle()

        #expect(computation.computedCounts == [1])
        #expect(delivered == [Self.input(findings: 1).make(now: TestData.date)])
    }

    @Test(.timeLimit(.minutes(1))) func unchangedInputIsNotRecomputed() async {
        let computation = ScriptedComputation()
        var deliveries = 0
        let pipeline = PresentationPipeline(compute: computation.compute) { _ in deliveries += 1 }

        pipeline.update(Self.input(findings: 1))
        await pipeline.waitUntilIdle()
        pipeline.update(Self.input(findings: 1))
        await pipeline.waitUntilIdle()

        #expect(computation.computedCounts == [1])
        #expect(deliveries == 1)
    }

    /// Eine ältere Berechnung, die erst nach einer neueren fertig wird, überschreibt deren Ergebnis nicht.
    @Test(.timeLimit(.minutes(1))) func staleResultIsDiscarded() async throws {
        let slow = Gate()
        let computation = ScriptedComputation(gates: [1: slow])
        var delivered: [PresentationSnapshot?] = []
        let pipeline = PresentationPipeline(compute: computation.compute) { delivered.append($0) }

        pipeline.update(Self.input(findings: 1))
        pipeline.update(Self.input(findings: 2))
        await pipeline.waitUntilIdle()
        slow.open()
        for _ in 0..<50 { await Task.yield() }

        #expect(delivered == [Self.input(findings: 2).make(now: TestData.date)])
    }

    @Test(.timeLimit(.minutes(1))) func missingSnapshotClearsThePresentationAtOnce() async {
        let computation = ScriptedComputation()
        var delivered: [PresentationSnapshot?] = []
        let pipeline = PresentationPipeline(compute: computation.compute) { delivered.append($0) }

        pipeline.update(Self.input(findings: 1))
        await pipeline.waitUntilIdle()
        pipeline.update(nil)

        #expect(delivered.count == 2 && delivered.last == .some(nil))
    }
}
