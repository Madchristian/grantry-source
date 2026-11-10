import Foundation
import Testing
@testable import ManagerKit

/// Volle Auflösung um Befunde (Spec 2026-11-08 §5.1): Takte des Task-Managers werden nur ±2 min um einen Befund
/// geschrieben, sonst der 10-s-Punkt ihres Abschnitts.
@Suite struct WatchbookResolutionTests {
    private let start = WatchbookFixtures.dayStart
    private let holdback: TimeInterval = 440

    private func time(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func point(_ seconds: TimeInterval, cpu: Double = 0.25) -> WatchbookPoint {
        WatchbookFixtures.point(at: time(seconds), cpu: cpu, consumers: false)
    }

    /// Ein 10-s-Abschnitt aus Takten im Sekundenabstand und seinem Basispunkt.
    private func addPeriod(ending seconds: TimeInterval, to resolution: inout WatchbookResolution) {
        for second in stride(from: seconds - 9, through: seconds, by: 1) {
            resolution.addFrame(point(second, cpu: 0.5))
        }
        resolution.addBase(point(seconds))
    }

    private func finding(from start: TimeInterval, to end: TimeInterval?) -> SystemFinding {
        SystemFinding(kind: .systemLoad, tone: .finding, reason: "Last", start: time(start), end: end.map(time),
                      evidence: .init(limit: 0.8, peak: 1, mean: 0.9), subject: nil)
    }

    @Test func basePointsWithoutFramesPassImmediately() {
        var resolution = WatchbookResolution(holdback: holdback)
        resolution.addBase(point(10))
        #expect(resolution.release(now: time(10), findings: []) == [point(10)])
        resolution.addBase(point(20))
        #expect(resolution.release(now: time(20), findings: []) == [point(20)])
        #expect(resolution.heldPoints.isEmpty)
    }

    @Test func periodsWithFramesWaitUntilTheHoldbackHasPassed() {
        var resolution = WatchbookResolution(holdback: holdback)
        addPeriod(ending: 10, to: &resolution)
        #expect(resolution.release(now: time(10), findings: []).isEmpty)
        #expect(resolution.heldPoints == [point(10)])
        #expect(resolution.release(now: time(449), findings: []).isEmpty)
        #expect(resolution.release(now: time(450), findings: []) == [point(10)])
        #expect(resolution.heldPoints.isEmpty)
    }

    @Test func framesNearAFindingReplaceTheirBasePoint() {
        var resolution = WatchbookResolution(holdback: holdback)
        // Abschnitte bis 200 s; Befund ab 250 s: Abschnitte ab 130 s liegen im Fenster.
        for end in stride(from: 10.0, through: 200, by: 10) { addPeriod(ending: end, to: &resolution) }
        let released = resolution.release(now: time(700), findings: [finding(from: 250, to: nil)])
        #expect(released.filter { $0.values[.cpuTotal] == 0.25 }.map(\.time) == stride(from: 10.0, through: 120, by: 10)
            .map(time))
        let full = released.filter { $0.values[.cpuTotal] == 0.5 }.map(\.time)
        #expect(full == stride(from: 121.0, through: 200, by: 1).map(time))
    }

    @Test func fullResolutionEndsTwoMinutesAfterTheFinding() {
        var resolution = WatchbookResolution(holdback: holdback)
        for end in stride(from: 10.0, through: 300, by: 10) { addPeriod(ending: end, to: &resolution) }
        let released = resolution.release(now: time(800), findings: [finding(from: 0, to: 100)])
        let bases = released.filter { $0.values[.cpuTotal] == 0.25 }.map(\.time)
        #expect(bases == stride(from: 230.0, through: 300, by: 10).map(time))
        #expect(released.map(\.time) == released.map(\.time).sorted())
    }

    /// Sind keine Takte mehr da (etwa nach dem Schließen des Task-Managers), läuft die Abgabe ohne Rückhalt weiter.
    @Test func laterBasePointsWaitBehindHeldPeriods() {
        var resolution = WatchbookResolution(holdback: holdback)
        addPeriod(ending: 10, to: &resolution)
        resolution.addBase(point(20))
        #expect(resolution.release(now: time(20), findings: []).isEmpty)
        #expect(resolution.heldPoints == [point(10), point(20)])
        #expect(resolution.release(now: time(450), findings: []) == [point(10), point(20)])
    }

    @Test func releaseAllDecidesEveryHeldPeriodNow() {
        var resolution = WatchbookResolution(holdback: holdback)
        addPeriod(ending: 10, to: &resolution)
        addPeriod(ending: 20, to: &resolution)
        let released = resolution.releaseAll(findings: [finding(from: 15, to: nil)])
        #expect(released.count == 20)
        #expect(resolution.heldPoints.isEmpty)
    }

    /// Takte eines nicht abgeschlossenen Abschnitts entfallen bei einer Lücke (Ruhezustand), statt in den nächsten
    /// Abschnitt zu rutschen.
    @Test func droppedFramesDoNotJoinTheNextPeriod() {
        var resolution = WatchbookResolution(holdback: holdback)
        resolution.addFrame(point(5, cpu: 0.5))
        resolution.dropFrames()
        resolution.addBase(point(3_600))
        #expect(resolution.release(now: time(3_600), findings: []) == [point(3_600)])
    }

    @Test func holdbackCoversTheLongestMinimumDurationAndTheMargin() {
        let resolution = WatchbookResolution(thresholds: .standard)
        #expect(resolution.holdback == 300 + 120 + 20)
    }
}
