import Foundation
import Testing
@testable import ManagerKit

/// Regeln über einen Wert je Punkt (Spec 2026-11-08 §5.1): Schwelle, Mindestdauer bis zum Beginn, Ruhezeit bis zum Ende
/// und Lücken – je Regel dieselben Grenzfälle.
@Suite struct LevelRuleTests {
    /// Eine Regel mit einem Wert knapp an und knapp über der Schwelle und der Messgröße, in die er geschrieben wird.
    struct Case: Sendable, CustomTestStringConvertible {
        let kind: SystemFinding.Kind
        /// Genau an der Schwelle – noch kein Befund.
        let atLimit: Double
        /// Knapp darüber.
        let above: Double
        let write: @Sendable (inout WatchbookValues, Double?) -> Void

        var testDescription: String { kind.rawValue }
    }

    static let cases = [
        Case(kind: .systemLoad, atLimit: 0.8, above: 0.801) { $0[.cpuTotal] = $1 },
        Case(kind: .memoryPressure, atLimit: 0, above: 1) { $0[.memoryPressure] = $1 },
        Case(kind: .thermalState, atLimit: 0, above: 1) { $0[.thermalState] = $1 },
        // Lesen und Schreiben zählen zusammen.
        Case(kind: .diskLoad, atLimit: 100_000_000, above: 100_000_200) { values, total in
            values[.diskRead] = total.map { $0 / 2 }
            values[.diskWrite] = total.map { $0 / 2 }
        },
        Case(kind: .sustainedUpload, atLimit: 5_000_000, above: 5_000_100) { $0[.networkSent] = $1 },
    ]

    private typealias F = FindingFixtures

    private func findings(_ testCase: Case, _ values: [Double?], from offset: TimeInterval = 0) -> [SystemFinding] {
        FindingRules.findings(of: testCase.kind, in: F.points(values, from: offset, set: testCase.write),
                              thresholds: F.thresholds)
    }

    private func rule(_ testCase: Case) -> FindingRule { F.thresholds.rule(for: testCase.kind) }

    @Test(arguments: cases) func valueAtTheLimitIsNoFinding(_ testCase: Case) {
        let values = F.values([(testCase.atLimit, F.count(spanning: rule(testCase).minimumDuration * 3))])
        #expect(findings(testCase, values).isEmpty)
    }

    @Test(arguments: cases) func valueAboveForTheMinimumDurationStartsAFinding(_ testCase: Case) {
        let values = F.values([(0, 3), (testCase.above, F.count(spanning: rule(testCase).minimumDuration))])
        let result = findings(testCase, values)
        #expect(result.count == 1)
        #expect(result.first?.kind == testCase.kind)
        // Beginn ist der erste Punkt über der Schwelle, nicht der Zeitpunkt der Bestätigung.
        #expect(result.first?.start == F.time(3 * F.step))
        #expect(result.first?.end == nil)
        #expect(result.first?.evidence.limit == rule(testCase).limit)
        #expect(result.first?.evidence.peak == testCase.above)
        #expect(result.first?.reason.isEmpty == false)
    }

    @Test(arguments: cases) func justShortOfTheMinimumDurationIsNoFinding(_ testCase: Case) {
        let values = F.values([(testCase.above, F.count(spanning: rule(testCase).minimumDuration) - 1),
                               (testCase.atLimit, 30)])
        #expect(findings(testCase, values).isEmpty)
    }

    @Test(arguments: cases) func findingEndsOnlyAfterTheQuietPeriod(_ testCase: Case) {
        let active = F.count(spanning: rule(testCase).minimumDuration)
        let quiet = F.count(spanning: rule(testCase).quietDuration)
        let lastActive = F.time(Double(active - 1) * F.step)

        let stillOpen = findings(testCase, F.values([(testCase.above, active), (testCase.atLimit, quiet - 1)]))
        #expect(stillOpen.map(\.end) == [nil])

        let ended = findings(testCase, F.values([(testCase.above, active), (testCase.atLimit, quiet)]))
        #expect(ended.count == 1)
        // Das Ende ist der letzte Punkt über der Schwelle; die Ruhezeit bestätigt es nur.
        #expect(ended.first?.end == lastActive)
    }

    @Test(arguments: cases) func shortDipDuringAFindingKeepsOneFinding(_ testCase: Case) {
        let active = F.count(spanning: rule(testCase).minimumDuration)
        let quiet = F.count(spanning: rule(testCase).quietDuration)
        let values = F.values([(testCase.above, active), (testCase.atLimit, quiet - 1), (testCase.above, 3)])
        let result = findings(testCase, values)
        #expect(result.count == 1)
        #expect(result.first?.end == nil)
    }

    /// Je die Hälfte der Mindestdauer vor und nach einer nicht gemessenen Strecke ergibt keinen Befund.
    @Test(arguments: cases) func unmeasuredPointsDoNotStartAFinding(_ testCase: Case) {
        let half = F.count(spanning: rule(testCase).minimumDuration / 2) + 1
        let values = F.values([(testCase.above, half), (nil, 1), (testCase.above, half)])
        #expect(findings(testCase, values).isEmpty)
    }

    /// Fehlende Punkte (Ruhezustand): Der Abstand übersteigt `maximumGap`, die Reihe ist dort unterbrochen.
    @Test(arguments: cases) func missingPointsDoNotStartAFinding(_ testCase: Case) {
        let half = F.count(spanning: rule(testCase).minimumDuration / 2) + 1
        let before = F.points(F.values([(testCase.above, half)]), set: testCase.write)
        let resume = Double(half) * F.step + F.thresholds.maximumGap
        let after = F.points(F.values([(testCase.above, half)]), from: resume, set: testCase.write)
        #expect(FindingRules.findings(of: testCase.kind, in: before + after, thresholds: F.thresholds).isEmpty)
    }

    /// Eine Lücke beendet keinen Befund: Auf ihn folgen nicht gemessene Punkte und eine lange Pause, danach ruhige Werte
    /// kürzer als die Ruhezeit – er läuft weiter; danach wieder Last – es bleibt derselbe Befund.
    @Test(arguments: cases) func gapsDoNotEndAFinding(_ testCase: Case) {
        let active = F.count(spanning: rule(testCase).minimumDuration)
        let quiet = F.count(spanning: rule(testCase).quietDuration)
        let before = F.points(F.values([(testCase.above, active), (nil, 20)]), set: testCase.write)
        let resume = 3_600 + Double(active + 20) * F.step
        let after = F.points(F.values([(testCase.atLimit, quiet - 1), (testCase.above, 2)]), from: resume,
                             set: testCase.write)
        let result = FindingRules.findings(of: testCase.kind, in: before + after, thresholds: F.thresholds)
        #expect(result.count == 1)
        #expect(result.first?.start == F.start)
        #expect(result.first?.end == nil)
    }

    /// Nach einer Lücke zählt die Ruhezeit neu: Ruhe vor und nach der Lücke wird nicht zusammengezählt.
    @Test(arguments: cases) func quietPeriodDoesNotSpanAGap(_ testCase: Case) {
        let active = F.count(spanning: rule(testCase).minimumDuration)
        let quiet = F.count(spanning: rule(testCase).quietDuration)
        let half = quiet / 2 + 1
        let values = F.values([(testCase.above, active), (testCase.atLimit, half), (nil, 1), (testCase.atLimit, half)])
        #expect(findings(testCase, values).map(\.end) == [nil])
    }

    /// Nach einem Ruhezustand bestätigt erst gemessene Ruhe das Ende; es liegt beim letzten Punkt vor der Lücke.
    @Test(arguments: cases) func findingEndsBeforeTheGapOnceQuietIsMeasured(_ testCase: Case) {
        let active = F.count(spanning: rule(testCase).minimumDuration)
        let quiet = F.count(spanning: rule(testCase).quietDuration)
        let before = F.points(F.values([(testCase.above, active)]), set: testCase.write)
        let after = F.points(F.values([(testCase.atLimit, quiet)]), from: 7_200, set: testCase.write)
        let result = FindingRules.findings(of: testCase.kind, in: before + after, thresholds: F.thresholds)
        #expect(result.map(\.end) == [F.time(Double(active - 1) * F.step)])
    }

    @Test func memoryPressureAndThermalStateBecomeCritical() {
        let memory = F.points(F.values([(1, 3), (2, 1), (1, 3)])) { $0[.memoryPressure] = $1 }
        let pressure = FindingRules.findings(of: .memoryPressure, in: memory, thresholds: F.thresholds)
        #expect(pressure.map(\.tone) == [.critical])
        #expect(pressure.first?.evidence.peak == 2)

        let elevated = F.points(F.values([(1, F.count(spanning: 60))])) { $0[.memoryPressure] = $1 }
        #expect(FindingRules.findings(of: .memoryPressure, in: elevated, thresholds: F.thresholds).map(\.tone)
            == [.finding])

        let thermal = F.points(F.values([(2, 31), (3, 1)])) { $0[.thermalState] = $1 }
        let hot = FindingRules.findings(of: .thermalState, in: thermal, thresholds: F.thresholds)
        #expect(hot.map(\.tone) == [.critical])
        #expect(hot.first?.reason != FindingRules.findings(
            of: .thermalState, in: F.points(F.values([(2, 31)])) { $0[.thermalState] = $1 }, thresholds: F.thresholds
        ).first?.reason)
    }

    @Test func meanCoversThePointsAboveTheLimit() {
        let points = F.points(F.values([(0.85, 7), (0.95, 6), (0.1, 7)])) { $0[.cpuTotal] = $1 }
        let finding = FindingRules.findings(of: .systemLoad, in: points, thresholds: F.thresholds).first
        #expect(finding?.evidence.peak == 0.95)
        #expect(abs((finding?.evidence.mean ?? 0) - (0.85 * 7 + 0.95 * 6) / 13) < 1e-9)
    }

    /// Unsortierte Punkte (etwa aus mehreren Tagesdateien) werden zuerst nach Zeit geordnet.
    @Test func pointsAreOrderedByTime() {
        let points = F.points(F.values([(0.9, F.count(spanning: 120))])) { $0[.cpuTotal] = $1 }
        let result = FindingRules.findings(of: .systemLoad, in: points.reversed(), thresholds: F.thresholds)
        #expect(result.map(\.start) == [F.start])
    }

    /// Alle Regeln auf einmal, nach Beginn geordnet.
    @Test func allSystemRulesAtOnce() {
        let points = F.points(F.values([(0, 2), (1, F.count(spanning: 600))])) { values, level in
            values[.cpuTotal] = level.map { $0 * 0.9 }
            values[.thermalState] = level
            values[.memoryPressure] = level
        }
        let kinds = FindingRules.findings(in: points, thresholds: F.thresholds).map(\.kind)
        #expect(Set(kinds) == [.systemLoad, .thermalState, .memoryPressure])
        #expect(kinds.count == 3)
    }
}
