import Testing
@testable import GrantryCharts

/// Pfadstufen der Ordnerleiter: kurze Pfade ganz, lange mit der ersten und den letzten Stufen.
@Suite struct PathStepsTests {
    private static func steps(_ count: Int) -> [PathSteps.Step] {
        (0..<count).map { PathSteps.Step(id: $0, title: "Stufe \($0)") }
    }

    @Test func shortPathsShowEveryStep() {
        #expect(PathSteps.visible(Self.steps(PathSteps.maximumVisible)) == Self.steps(PathSteps.maximumVisible))
    }

    @Test func longPathsKeepTheFirstAndTheLastSteps() {
        let visible = PathSteps.visible(Self.steps(7))
        #expect(visible.map { $0?.id } == [0, nil, 4, 5, 6])
    }
}
