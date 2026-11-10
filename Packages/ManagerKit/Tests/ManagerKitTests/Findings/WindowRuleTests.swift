import Foundation
import Testing
@testable import ManagerKit

/// Regeln über ein Zeitfenster (Spec 2026-11-08 §5.1): Swap-Zuwachs in 10 min und Entladung des Akkus je Stunde.
@Suite struct WindowRuleTests {
    private typealias F = FindingFixtures

    // MARK: Swap-Zuwachs

    private func swapFindings(_ values: [Double?], from offset: TimeInterval = 0) -> [SystemFinding] {
        FindingRules.findings(of: .swapGrowth, in: F.points(values, from: offset) { $0[.swapUsed] = $1 },
                              thresholds: F.thresholds)
    }

    /// Von 0 linear auf `total` in 5 min, danach gleichbleibend.
    private func swapRamp(to total: Double, flat: Int = 3) -> [Double?] {
        let steps = 30
        return [0, 0] + (1...steps).map { total * Double($0) / Double(steps) } + Array(repeating: total, count: flat)
    }

    @Test func swapGrowthJustAboveTheLimitIsAFinding() {
        let result = swapFindings(swapRamp(to: 2_000_000_000 + 1_048_576))
        #expect(result.count == 1)
        #expect(result.first?.kind == .swapGrowth)
        #expect(result.first?.start == F.time(31 * F.step))
        #expect(result.first?.evidence.limit == 2_000_000_000)
    }

    @Test func swapGrowthAtTheLimitIsNoFinding() {
        #expect(swapFindings(swapRamp(to: 2_000_000_000)).isEmpty)
    }

    /// 4,5 GB in 30 min sind nur 1,5 GB je 10 min.
    @Test func slowSwapGrowthIsNoFinding() {
        let values = (0...180).map { Double($0) * 25_000_000 } as [Double?]
        #expect(swapFindings(values).isEmpty)
    }

    /// Der Swap wächst während eines Ruhezustands: Die Werte vor und nach der Lücke werden nicht verglichen.
    @Test func swapGrowthAcrossAGapIsNoFinding() {
        let before = F.points(F.values([(0, 6)])) { $0[.swapUsed] = $1 }
        let after = F.points(F.values([(3_000_000_000, 10)]), from: 5 * F.step + 60) { $0[.swapUsed] = $1 }
        #expect(FindingRules.findings(of: .swapGrowth, in: before + after, thresholds: F.thresholds).isEmpty)
    }

    /// Wächst der Swap nicht weiter, fällt der Zuwachs nach dem Fenster unter die Schwelle; nach der Ruhezeit endet
    /// der Befund beim letzten Punkt darüber.
    @Test func swapGrowthEndsAfterTheWindowAndTheQuietPeriod() {
        let window = F.thresholds.swapGrowthWindow
        let quiet = F.thresholds.rule(for: .swapGrowth).quietDuration
        let flat = F.count(spanning: window + quiet) + 2
        let result = swapFindings(swapRamp(to: 3_000_000_000, flat: flat))
        #expect(result.count == 1)
        #expect(result.first?.end != nil)
    }

    // MARK: Akku

    /// Ladestand fällt um `perHour` je Stunde; `power` 0 = Akku, 1 = Netzteil.
    private func battery(perHour: Double, count: Int, power: Double? = 0, from offset: TimeInterval = 0,
                         charge start: Double = 0.9) -> [WatchbookPoint] {
        let values = (0..<count).map { start - perHour * Double($0) * F.step / 3_600 } as [Double?]
        return F.points(values, from: offset) { values, charge in
            values[.batteryCharge] = charge
            values[.externalPower] = power
        }
    }

    private func drainFindings(_ points: [WatchbookPoint]) -> [SystemFinding] {
        FindingRules.findings(of: .batteryDrain, in: points, thresholds: F.thresholds)
    }

    /// Ein Wert entsteht erst nach einem vollen Fenster; danach zählt die Mindestdauer.
    @Test func fastDrainIsAFinding() {
        let window = F.thresholds.batteryDrainWindow
        let minimum = F.thresholds.rule(for: .batteryDrain).minimumDuration
        let result = drainFindings(battery(perHour: 0.21, count: F.count(spanning: window + minimum)))
        #expect(result.map(\.kind) == [.batteryDrain])
        #expect(result.first?.start == F.time(window))
        #expect(abs((result.first?.evidence.peak ?? 0) - 0.21) < 1e-6)

        let tooShort = battery(perHour: 0.21, count: F.count(spanning: window + minimum) - 1)
        #expect(drainFindings(tooShort).isEmpty)
    }

    @Test func slowerDrainIsNoFinding() {
        #expect(drainFindings(battery(perHour: 0.19, count: 200)).isEmpty)
    }

    /// Am Netzteil gibt es keine Entladung; ohne Akku (Stromquelle nicht gemessen) auch nicht.
    @Test func noDrainOnExternalPowerOrWithoutBattery() {
        #expect(drainFindings(battery(perHour: 0.5, count: 200, power: 1)).isEmpty)
        #expect(drainFindings(battery(perHour: 0.5, count: 200, power: nil)).isEmpty)
    }

    /// Netzteil an beendet den Befund nach der Ruhezeit; das Ende ist der letzte Punkt mit schneller Entladung.
    @Test func connectingPowerEndsTheFinding() {
        let quiet = F.thresholds.rule(for: .batteryDrain).quietDuration
        let draining = battery(perHour: 0.3, count: 120)
        let plugged = battery(perHour: 0, count: F.count(spanning: quiet), power: 1, from: 120 * F.step, charge: 0.8)
        let result = drainFindings(draining + plugged)
        #expect(result.count == 1)
        #expect(result.first?.end == F.time(119 * F.step))
    }
}
