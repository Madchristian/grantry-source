import Foundation
import GrantryShared
import Testing
@testable import ManagerKit

/// Regel „Drosselung“ (Spec 2026-11-08 §5.3, TM-14.2): thermischer Druck mindestens mäßig und Takt der
/// Leistungscluster unter 70 % des Höchsttakts bei über 60 % Last, für mindestens 60 s.
@Suite struct ThrottlingRuleTests {
    private typealias F = FindingFixtures
    private typealias Cluster = ThrottlingSample.Cluster

    /// Abstand der Sensor-Messungen (`SensorModel.interval` plus Messfenster, gerundet).
    private static let step: TimeInterval = 2
    private static let thresholds = FindingThresholds.standard
    private static var minimum: TimeInterval { thresholds.throttling.minimumDuration }
    private static var quiet: TimeInterval { thresholds.throttling.quietDuration }

    /// Gedrosselt: mäßiger Druck, ein Leistungscluster zu 90 % ausgelastet bei 50 % des Höchsttakts.
    private static let throttled = (pressure: ThermalPressureLevel.moderate,
                                    clusters: [Cluster(load: 0.9, clockShare: 0.5)])

    /// Messungen im Abstand `step` von `from` bis einschließlich `through` Sekunden.
    private static func samples(from: TimeInterval = 0, through: TimeInterval,
                                pressure: ThermalPressureLevel? = throttled.pressure,
                                clusters: [Cluster]? = throttled.clusters) -> [ThrottlingSample] {
        stride(from: from, through: through, by: step).map {
            ThrottlingSample(time: F.time($0), pressure: pressure, performanceClusters: clusters)
        }
    }

    private static func findings(_ samples: [ThrottlingSample]) -> [SystemFinding] {
        FindingRules.throttlingFindings(in: samples, thresholds: thresholds)
    }

    @Test func sustainedThrottlingBecomesAFinding() throws {
        let finding = try #require(Self.findings(Self.samples(through: Self.minimum)).first)
        #expect(finding.kind == .throttling)
        #expect(finding.tone == .finding)
        #expect(finding.start == F.time(0))
        #expect(finding.isOngoing)
        #expect(finding.subject == nil)
        // Belegwerte als Anteil am Höchsttakt: Grenze 70 %, niedrigster und mittlerer Takt.
        #expect(finding.evidence == .init(limit: 0.7, peak: 0.5, mean: 0.5))
        #expect(finding.reason.contains("70 %"))
    }

    @Test func shorterThanTheMinimumDurationIsNoFinding() {
        #expect(Self.findings(Self.samples(through: Self.minimum - Self.step)).isEmpty)
    }

    // MARK: Grenzwerte

    /// Genau 70 % des Höchsttakts ist nicht „unter 70 %“.
    @Test func clockExactlyAtTheLimitIsNotThrottled() {
        let atLimit = Self.samples(through: Self.minimum, clusters: [Cluster(load: 0.9, clockShare: 0.7)])
        let below = Self.samples(through: Self.minimum, clusters: [Cluster(load: 0.9, clockShare: 0.6999)])
        #expect(Self.findings(atLimit).isEmpty)
        #expect(Self.findings(below).count == 1)
    }

    /// Genau 60 % Last ist nicht „über 60 %“.
    @Test func loadExactlyAtTheLimitIsNotThrottled() {
        let atLimit = Self.samples(through: Self.minimum, clusters: [Cluster(load: 0.6, clockShare: 0.5)])
        let above = Self.samples(through: Self.minimum, clusters: [Cluster(load: 0.6001, clockShare: 0.5)])
        #expect(Self.findings(atLimit).isEmpty)
        #expect(Self.findings(above).count == 1)
    }

    /// Leichter Druck reicht nicht; mäßiger und höherer schon.
    @Test(arguments: [(ThermalPressureLevel.nominal, false), (.light, false), (.moderate, true), (.heavy, true),
                      (.critical, true)])
    func pressureMustBeAtLeastModerate(pressure: ThermalPressureLevel, throttles: Bool) {
        #expect(Self.findings(Self.samples(through: Self.minimum, pressure: pressure)).isEmpty == !throttles)
    }

    /// Ohne Last kein Befund: Ein ruhender Mac taktet ohnehin niedrig.
    @Test func lowClockWithoutLoadIsNoThrottling() {
        let idle = Self.samples(through: Self.minimum * 2, clusters: [Cluster(load: 0.1, clockShare: 0.2)])
        #expect(Self.findings(idle).isEmpty)
    }

    /// Von mehreren ausgelasteten Leistungsclustern zählt der schnellste: Drosselung nur, wenn auch er langsam ist.
    @Test func theFastestLoadedPerformanceClusterDecides() {
        let oneFast = Self.samples(through: Self.minimum, clusters: [Cluster(load: 0.9, clockShare: 0.5),
                                                                     Cluster(load: 0.8, clockShare: 0.95)])
        let unloadedFast = Self.samples(through: Self.minimum, clusters: [Cluster(load: 0.9, clockShare: 0.5),
                                                                          Cluster(load: 0.1, clockShare: 0.95)])
        #expect(Self.findings(oneFast).isEmpty)
        #expect(Self.findings(unloadedFast).first?.evidence.peak == 0.5)
    }

    // MARK: Ohne Helper und Lücken

    /// Ohne Helper gibt es keinen Takt: keine Drosselung, nur der thermische Zustand selbst (Regel `thermalState`).
    @Test func withoutClockDataThereIsNoThrottling() {
        #expect(Self.findings(Self.samples(through: Self.minimum * 2, pressure: .heavy, clusters: nil)).isEmpty)
        #expect(Self.findings(Self.samples(through: Self.minimum * 2, pressure: .heavy, clusters: [])).isEmpty)
    }

    /// Ohne Druck oder Takt ist der Punkt nicht gemessen: Die Lücke beginnt keinen Befund und beendet keinen.
    @Test func unmeasuredSampleIsAGap() {
        let gap = Self.samples(through: Self.minimum / 2)
            + Self.samples(from: Self.minimum / 2 + Self.step, through: Self.minimum / 2 + Self.step, pressure: nil)
            + Self.samples(from: Self.minimum / 2 + 2 * Self.step, through: Self.minimum + 2 * Self.step)
        #expect(Self.findings(gap).isEmpty)
    }

    /// Normaler Druck heißt gemessen und ruhig – auch wenn der Takt fehlt.
    @Test func nominalPressureIsQuietEvenWithoutClock() {
        let samples = Self.samples(through: Self.minimum)
            + Self.samples(from: Self.minimum + Self.step, through: Self.minimum + Self.quiet + Self.step,
                           pressure: .nominal, clusters: nil)
        let finding = Self.findings(samples).first
        #expect(finding?.end == F.time(Self.minimum))
    }

    @Test func endsAfterTheQuietDuration() {
        let samples = Self.samples(through: Self.minimum)
            + Self.samples(from: Self.minimum + Self.step, through: Self.minimum + Self.quiet + Self.step,
                           clusters: [Cluster(load: 0.9, clockShare: 0.95)])
        let finding = Self.findings(samples).first
        #expect(finding?.end == F.time(Self.minimum))
        #expect(finding?.isOngoing == false)
    }

    // MARK: Aus der Helper-Messung

    /// Druck aus dem Sampler `thermal`; fehlt er (älterer Helper) oder ist unbekannt, aus `ProcessInfo.thermalState`.
    @Test func pressureComesFromTheHelperWithProcessInfoAsFallback() {
        let time = F.time(0)
        let heavy = SensorReading(thermalPressure: .heavy)
        #expect(ThrottlingSample(time: time, sensors: heavy, thermalState: .nominal).pressure == .heavy)
        #expect(ThrottlingSample(time: time, sensors: SensorReading(), thermalState: .fair).pressure == .moderate)
        #expect(ThrottlingSample(time: time, sensors: SensorReading(thermalPressure: .unknown),
                                 thermalState: .serious).pressure == .heavy)
        #expect(ThrottlingSample(time: time, sensors: nil, thermalState: nil).pressure == nil)
        #expect(ThrottlingSample(time: time, sensors: SensorReading(thermalPressure: .trapping),
                                 thermalState: .nominal).pressure == .critical)
        #expect(ThrottlingSample(time: time, sensors: SensorReading(thermalPressure: .light),
                                 thermalState: .fair).pressure == .light)
    }

    /// Nur Leistungscluster; Takt als Anteil an der höchsten Taktstufe, Last als aktiver Anteil.
    @Test func performanceClustersFromTheHelperReading() {
        let reading = SensorReading(clusters: [
            .init(name: "E-Cluster", frequencyMHz: 1000, activeShare: 0.9, maximumFrequencyMHz: 2592),
            .init(name: "P0-Cluster", frequencyMHz: 2256, activeShare: 0.8, maximumFrequencyMHz: 4512),
            .init(name: "P1-Cluster", frequencyMHz: nil, activeShare: 0.1, maximumFrequencyMHz: 4512),
        ], thermalPressure: .moderate)
        let sample = ThrottlingSample(time: F.time(0), sensors: reading, thermalState: nil)
        #expect(sample.performanceClusters == [Cluster(load: 0.8, clockShare: 0.5), Cluster(load: 0.1, clockShare: nil)])
        #expect(ThrottlingSample(time: F.time(0), sensors: nil, thermalState: .fair).performanceClusters == nil)
    }

    /// Echte Aufnahme dieses M4 Max im Leerlauf: Druck „Nominal“, kein Leistungscluster über 60 % – ruhig, nicht Lücke.
    @Test func realM4MaxReadingIsQuiet() throws {
        let url = try #require(Bundle.module.url(forResource: "m4-max", withExtension: "plist",
                                                 subdirectory: "Fixtures/PowerMetrics"))
        let reading = try PowerMetricsParser.parse(Data(contentsOf: url))
        let sample = ThrottlingSample(time: F.time(0), sensors: reading, thermalState: .nominal)
        #expect(sample.pressure == .nominal)
        #expect(sample.performanceClusters?.count == 2)
        #expect(FindingRules.throttlingSeries([sample], thresholds: Self.thresholds).map(\.value) == [0])
    }
}
