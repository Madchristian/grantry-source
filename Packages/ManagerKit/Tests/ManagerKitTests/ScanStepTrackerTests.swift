import Foundation
import Testing
@testable import ManagerKit

/// Fortschritt der „Scannen“-Buttons in „Aufräumen“ (#270): Schritte schließen nacheinander ab (Kategorien,
/// Kennungsgruppen, Prozess-Schritte), ihre Dauer ist der Abstand zum vorigen Abschluss. Sekunden seit Scan-Beginn,
/// keine Uhren, Pausen oder Systemabfragen.
@Suite struct ScanStepTrackerTests {
    private let steps: Set<String> = ["a", "b", "c"]
    /// Letzter Lauf: 1 s + 6 s + 1 s Schritte, 2 s Nachverarbeitung – 10 s gesamt.
    private let history = ScanStepDurations(steps: ["a": 1, "b": 6, "c": 1], processing: 2)

    @Test func firstRunCountsStepsMonotonicallyAndLearnsStepGaps() {
        var scan = ScanStepTracker(steps: steps, previous: nil, schedule: .sequential)
        #expect(scan.progress.fraction == 0)
        #expect(!scan.progress.isIndeterminate)
        var fractions: [Double] = []
        for (step, elapsed) in [("b", 1.0), ("a", 3.0), ("c", 6.0)] {
            _ = scan.complete(step, elapsed: elapsed, succeeded: true)
            fractions.append(scan.progress.fraction)
            #expect(scan.progress.remainingSeconds == nil)
        }
        #expect(fractions == [0.25, 0.5, 0.75])
        scan.finish(elapsed: 7)
        #expect(scan.progress.fraction == 1)
        #expect(scan.completedDurations == ScanStepDurations(steps: ["b": 1, "a": 2, "c": 3], processing: 1))
    }

    @Test func weightsStepsWithTheDurationsOfTheLastRun() {
        var scan = ScanStepTracker(steps: steps, previous: history, schedule: .sequential)
        _ = scan.complete("a", elapsed: 1, succeeded: true)
        #expect(abs(scan.progress.fraction - 0.1) < 0.0001)
        // Offene Schritte (6 s + 1 s) plus Nachverarbeitung (2 s), nacheinander statt nur der längste.
        #expect(scan.progress.remainingSeconds == 9)
        _ = scan.complete("b", elapsed: 7, succeeded: true)
        #expect(abs(scan.progress.fraction - 0.7) < 0.0001)
        #expect(scan.progress.remainingSeconds == 3)
        _ = scan.complete("c", elapsed: 8, succeeded: true)
        #expect(abs(scan.progress.fraction - 0.8) < 0.0001)
        scan.finish(elapsed: 10)
        #expect(scan.progress.fraction == 1)
        #expect(scan.completedDurations == history)
    }

    @Test(arguments: [0.5, 2.0]) func scalesTheEstimateWithThePaceOfThisRun(pace: Double) {
        var scan = ScanStepTracker(steps: steps, previous: history, schedule: .sequential)
        _ = scan.complete("a", elapsed: 1 * pace, succeeded: true)
        #expect(scan.progress.remainingSeconds == 9 * pace)
    }

    @Test func dropsTheEstimateWhenThisRunIsFarOffTheLastOne() {
        var scan = ScanStepTracker(steps: steps, previous: history, schedule: .sequential)
        _ = scan.complete("a", elapsed: 3, succeeded: true)
        #expect(scan.progress.remainingSeconds == nil)
        #expect(scan.progress.fraction > 0)
    }

    @Test func neverGoesBackwardsWhenStepsFinishInAnotherOrder() {
        var scan = ScanStepTracker(steps: steps, previous: history, schedule: .sequential)
        var last = scan.progress.fraction
        for (step, elapsed) in [("b", 6.0), ("c", 6.5), ("a", 7.0)] {
            _ = scan.complete(step, elapsed: elapsed, succeeded: true)
            #expect(scan.progress.fraction >= last)
            #expect(scan.progress.fraction <= 0.99)
            last = scan.progress.fraction
        }
    }

    @Test func aRunTooShortForMeaningfulProgressIsIndeterminateButFinishesAtOneHundredPercent() {
        let quick = ScanStepDurations(steps: ["a": 0.1, "b": 0.2, "c": 0.1], processing: 0.1)
        var scan = ScanStepTracker(steps: steps, previous: quick, schedule: .sequential)
        #expect(scan.progress.isIndeterminate)
        _ = scan.complete("a", elapsed: 0.3, succeeded: true)
        #expect(scan.progress.isIndeterminate)
        #expect(scan.progress.remainingSeconds == nil)
        scan.finish(elapsed: 0.5)
        #expect(scan.progress == ScanProgress(fraction: 1))
        #expect(!scan.progress.isIndeterminate)
    }

    @Test func failedStepsAdvanceButDoNotTrainOrEstimate() {
        var scan = ScanStepTracker(steps: steps, previous: history, schedule: .sequential)
        _ = scan.complete("a", elapsed: 1, succeeded: false)
        #expect(scan.progress.fraction > 0)
        #expect(scan.progress.remainingSeconds == nil)
        _ = scan.complete("b", elapsed: 7, succeeded: true)
        _ = scan.complete("c", elapsed: 8, succeeded: true)
        scan.finish(elapsed: 10)
        #expect(scan.progress.fraction == 1)
        #expect(scan.completedDurations == nil)
    }

    @Test func cancellationKeepsTheReachedFractionAndForgetsTheRun() {
        var scan = ScanStepTracker(steps: steps, previous: history, schedule: .sequential)
        _ = scan.complete("a", elapsed: 1, succeeded: true)
        scan.cancel()
        #expect(abs(scan.progress.fraction - 0.1) < 0.0001)
        #expect(scan.progress.remainingSeconds == nil)
        #expect(scan.completedDurations == nil)
        let publishedAfterCancel = scan.complete("b", elapsed: 7, succeeded: true)
        #expect(!publishedAfterCancel)
    }

    @Test func unfinishedRunsLeaveNoDurations() {
        var scan = ScanStepTracker(steps: steps, previous: nil, schedule: .sequential)
        _ = scan.complete("a", elapsed: 1, succeeded: true)
        scan.finish(elapsed: 2)
        #expect(scan.progress.fraction == 1)
        #expect(scan.completedDurations == nil)
    }

    @Test func unknownAndRepeatedStepsAreIgnored() {
        var scan = ScanStepTracker(steps: steps, previous: nil, schedule: .sequential)
        _ = scan.complete("a", elapsed: 1, succeeded: true)
        _ = scan.complete("a", elapsed: 2, succeeded: true)
        _ = scan.complete("x", elapsed: 3, succeeded: true)
        #expect(scan.progress.fraction == 0.25)
    }

    @Test func historyOfOtherStepsFallsBackToCounting() {
        var scan = ScanStepTracker(steps: ["a", "b"], previous: history, schedule: .sequential)
        _ = scan.complete("a", elapsed: 1, succeeded: true)
        #expect(abs(scan.progress.fraction - 1.0 / 3) < 0.0001)
        #expect(scan.progress.remainingSeconds == nil)
    }

    @Test func publishesAtMostFourTimesPerSecond() {
        var scan = ScanStepTracker(steps: steps, previous: nil, schedule: .sequential)
        let tooSoon = scan.complete("a", elapsed: 0.1, succeeded: true)
        let nextWindow = scan.complete("b", elapsed: 0.3, succeeded: true)
        let tooSoonAgain = scan.complete("c", elapsed: 0.4, succeeded: true)
        #expect(!tooSoon)
        #expect(nextWindow)
        #expect(!tooSoonAgain)
        #expect(scan.progress.fraction == 0.75)
    }

    /// Die gespeicherte Datei des Vollscans behält ihr Format (`sources`), auch nach der Verallgemeinerung.
    @Test func persistedFullScanDurationsKeepTheirFormat() throws {
        let durations = ScanDurations(steps: [.launchd: 2], processing: 1)
        let json = try #require(String(data: try JSONEncoder().encode(durations), encoding: .utf8))
        #expect(json.contains("\"sources\""))
        #expect(try JSONDecoder().decode(ScanDurations.self, from: Data(json.utf8)) == durations)
    }
}

/// Die Segment-Scanner melden echte Schritte: genau einen Abschluss je Schritt, die App-Reste vorher ihren Plan.
@Suite struct SegmentScanStepTests {
    @Test func processScanReportsBothStepsInOrder() async throws {
        struct Table: ProcessTableReading {
            func entries() throws -> [ProcessEntry] { [] }
        }
        let scanner = ProcessOverviewScanner(
            table: Table(), detector: OrphanAgentTreeDetector(),
            simulators: BootedSimulatorReader(runner: ProcessCommandRunner(), home: "/nonexistent", isDirectory: { _ in false })
        )
        let events = StepEvents<ProcessScanStep>()
        _ = try await scanner.scan { await events.append($0) }
        #expect(await events.all == [.completed(.processTable, succeeded: true), .completed(.simulators, succeeded: true)])
        #expect(ProcessScanStep.allCases == [.processTable, .simulators])
    }

    @Test func eventsMapToAnotherStepType() {
        #expect(ScanStepEvent.completed(ProcessScanStep.simulators, succeeded: false).map(\.rawValue)
                == .completed("simulators", succeeded: false))
        #expect(ScanStepEvent.planned([ProcessScanStep.processTable]).map(\.rawValue) == .planned(["processTable"]))
    }
}

actor StepEvents<Step: Hashable & Sendable> {
    private(set) var all: [ScanStepEvent<Step>] = []
    func append(_ event: ScanStepEvent<Step>) { all.append(event) }
}
