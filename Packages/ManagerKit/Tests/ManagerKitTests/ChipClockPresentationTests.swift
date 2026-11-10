import Foundation
import Testing
@testable import ManagerKit

/// Panel „Takt und Thermik“ (TM-14.3): Peilkopf, Taktbänder je Cluster, Thermikband, Drosselung.
@Suite struct ChipClockPresentationTests {
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func cluster(_ name: String, _ cores: ClosedRange<Int>, megahertz: Double, active: Double,
                        steps: [(Double, Double)]) -> SensorReading.Cluster {
        SensorReading.Cluster(name: name, frequencyMHz: megahertz, activeShare: active,
                              maximumFrequencyMHz: steps.last?.0,
                              cores: cores.map { SensorReading.Core(id: $0, frequencyMHz: megahertz, activeShare: nil) },
                              frequencySteps: steps.map { SensorReading.FrequencyStep(frequencyMHz: $0.0, share: $0.1) })
    }

    /// M4 Max: P0 unter Last nahe am Höchsttakt, P1 in Ruhe, E dazwischen.
    static let sensors = SensorReading(
        clusters: [cluster("E-Cluster", 0...3, megahertz: 2112, active: 0.5,
                           steps: [(1020, 0.2), (2112, 0.5), (2592, 0.3)]),
                   cluster("P0-Cluster", 4...9, megahertz: 4104, active: 0.9,
                           steps: [(1260, 0.004), (3000, 0.196), (4104, 0.4), (4512, 0.4)]),
                   cluster("P1-Cluster", 10...15, megahertz: 1260, active: 0.1, steps: [(1260, 1), (4512, 0)])],
        thermalPressure: .light)

    static func close(_ values: [Double], _ expected: [Double]) -> Bool {
        values.count == expected.count && zip(values, expected).allSatisfy { abs($0 - $1) < 1e-9 }
    }

    static func distribution(_ reading: SensorReading = sensors) -> ClockDistributionHistory {
        var history = ClockDistributionHistory()
        history.record(reading, at: now)
        return history
    }

    static func thermal(_ changes: [(TimeInterval, ProcessInfo.ThermalState)]) -> ThermalStateHistory {
        var history = ThermalStateHistory(span: 900)
        for (offset, state) in changes {
            history.record(ThermalCondition(state: state, isLowPowerModeEnabled: false), at: now.addingTimeInterval(offset))
        }
        return history
    }

    static func clock(sensors: SensorReading? = sensors, distribution: ClockDistributionHistory = distribution(),
                      thermal: ThermalStateHistory = thermal([(-900, .nominal)]),
                      findings: [SystemFinding] = []) throws -> ChipPage.Clock {
        ChipPresentation.clock(profile: try ChipPresentationTests.profile("m4-max"), sensors: sensors,
                               distribution: distribution, thermal: thermal, now: now, findings: findings)
    }

    @Test func headNamesCacheAndCoresPerCluster() throws {
        let clock = try Self.clock()
        #expect(clock.title == "Takt und Thermik")
        #expect(clock.detail == "Leistungskerne: 12 Kerne, 2 Cluster à 6 Kerne, je 16 MB L2 · "
            + "Effizienzkerne: 4 Kerne, 1 Cluster, 4 MB L2")
        // Mittlerer Takt der Leistungscluster, gewichtet mit ihrer aktiven Zeit: (4104 · 0,9 + 1260 · 0,1) / 1.
        #expect(clock.value == "3,82 GHz")
        #expect(abs((clock.fraction ?? 0) - 3819.6 / 4512) < 1e-6)
        #expect(clock.finding == nil)
    }

    @Test func bandPerClusterWithHeatRelativeToTheMostFrequentStep() throws {
        let clock = try Self.clock()
        #expect(clock.bands.map(\.title) == ["Cluster P0", "Cluster P1", "Cluster E"])
        #expect(clock.bands.map(\.kind) == [.performance, .performance, .efficiency])
        let p0 = try #require(clock.bands.first)
        #expect(p0.steps.map(\.frequency) == ["1,26", "3,00", "4,10", "4,51"])
        #expect(p0.steps.map(\.share) == ["–", "20 %", "40 %", "40 %"])
        #expect(Self.close(p0.steps.map(\.heat), [0.01, 0.49, 1, 1]))
        // Bei Gleichstand die höhere Stufe.
        #expect(p0.value == "meist 4,51 GHz")
        #expect(p0.detail == "Höchsttakt 40 %")
        #expect(p0.accessibilityValue == "häufigste Stufe 4,51 GHz, Höchsttakt 40 %")
        #expect(p0.placeholder.isEmpty)
    }

    @Test func clusterWithoutDistributionWasNotActive() throws {
        let reading = SensorReading(clusters: Self.sensors.clusters.map { cluster in
            cluster.name == "P1-Cluster" ? Self.cluster("P1-Cluster", 10...15, megahertz: 1260, active: 0, steps: [])
                : cluster
        })
        let clock = try Self.clock(sensors: reading, distribution: Self.distribution(reading))
        let p1 = try #require(clock.bands.first { $0.title == "Cluster P1" })
        #expect(p1.steps.isEmpty)
        #expect(p1.value == "–")
        #expect(p1.placeholder == "Im Messzeitraum nicht aktiv")
        #expect(p1.accessibilityValue == "im Messzeitraum nicht aktiv")
    }

    /// Ohne Helper eine Zeile für alle Cluster; das Thermikband bleibt.
    @Test func withoutHelper() throws {
        let clock = try Self.clock(sensors: nil, distribution: ClockDistributionHistory())
        #expect(clock.value == "–")
        #expect(clock.fraction == nil)
        #expect(clock.bands.count == 1)
        let band = try #require(clock.bands.first)
        #expect(band.title == "Taktstufen")
        #expect(band.detail == "3 Cluster")
        #expect(band.steps.isEmpty)
        #expect(band.placeholder == "Ohne Helper nicht messbar")
        #expect(band.accessibilityValue == "ohne Helper nicht messbar")
        #expect(clock.thermalDetail.isEmpty)
        #expect(clock.thermalSegments.count == 1)
    }

    /// Vor dem ersten bekannten Stand liest VoiceOver „nicht gemessen“ statt des Strichs (TM-14.6, #399).
    @Test func thermalBandWithoutKnownStateReadsNotMeasured() throws {
        let clock = try Self.clock(thermal: ThermalStateHistory(span: 900))
        #expect(clock.thermalSegments.isEmpty)
        #expect(clock.thermalCurrent == "–")
        #expect(clock.thermalAccessibilityValue == "letzte 15 Minuten: nicht gemessen")
    }

    @Test func thermalBandMergesEqualStatesAndLeavesTheUnknownStartEmpty() throws {
        var history = ThermalStateHistory(span: 900)
        history.record(ThermalCondition(state: .nominal, isLowPowerModeEnabled: false), at: Self.now.addingTimeInterval(-450))
        history.record(ThermalCondition(state: .nominal, isLowPowerModeEnabled: true), at: Self.now.addingTimeInterval(-300))
        history.record(ThermalCondition(state: .fair, isLowPowerModeEnabled: true), at: Self.now.addingTimeInterval(-180))
        let clock = try Self.clock(thermal: history)
        #expect(clock.thermalSegments.map(\.state) == [.nominal, .fair])
        #expect(Self.close(clock.thermalSegments.map(\.start), [0.5, 0.8]))
        #expect(Self.close(clock.thermalSegments.map(\.end), [0.8, 1]))
        #expect(clock.thermalSegments.map(\.title) == ["Normal", "Erhöht"])
        #expect(clock.thermalState == .fair)
        #expect(clock.thermalCurrent == "Erhöht")
        #expect(clock.thermalDetail == "Druck: leicht")
        #expect(clock.thermalAccessibilityValue == "letzte 15 Minuten: Normal, dann Erhöht")
        #expect(clock.window == 900)
    }

    @Test func throttlingFindingSetsTheDotAndReason() throws {
        let finding = SystemFinding(kind: .throttling, tone: .finding, reason: "Der Mac senkt unter Last den Takt.",
                                    start: Self.now.addingTimeInterval(-120), end: nil,
                                    evidence: .init(limit: 0.7, peak: 0.6, mean: 0.65), subject: nil)
        let ended = SystemFinding(kind: .throttling, tone: .finding, reason: "vorbei", start: Self.now.addingTimeInterval(-800),
                                  end: Self.now.addingTimeInterval(-700),
                                  evidence: .init(limit: 0.7, peak: 0.6, mean: 0.65), subject: nil)
        #expect(try Self.clock(findings: [ended]).finding == nil)
        #expect(try Self.clock(findings: [ended, finding]).finding == "Der Mac senkt unter Last den Takt.")
    }

    /// Das Taktband zeichnet nur je Messpunkt: Ein neuer Takt ohne neue Sensor-Messung ändert die Bänder nicht.
    @Test func bandsOnlyChangeWithANewMeasurement() throws {
        let profile = try ChipPresentationTests.profile("m4-max")
        let history = Self.distribution()
        let first = ChipPresentation.clock(profile: profile, sensors: Self.sensors, distribution: history,
                                           thermal: Self.thermal([(-900, .nominal)]), now: Self.now, findings: [])
        let later = ChipPresentation.clock(profile: profile, sensors: Self.sensors, distribution: history,
                                           thermal: Self.thermal([(-900, .nominal)]), now: Self.now.addingTimeInterval(1),
                                           findings: [])
        #expect(first.bands == later.bands)
    }
}
