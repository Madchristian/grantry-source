import Foundation
import Testing
@testable import ManagerKit

/// Chip-Tab (Apple Silicon): Texte und Kennzahlen aus `ChipProfile`, Messstand und Helper-Sensoren.
@Suite struct ChipPresentationTests {
    static func profile(_ name: String) throws -> ChipProfile { ChipProfile(facts: try ChipProfileTests.facts(name)) }

    /// Kernlast je logischer Nummer; Effizienzkerne halb, Leistungskerne voll belegt, wo nicht anders angegeben.
    static func snapshot(loads: [Double?], gpu: GPULoadReading? = nil) -> TaskManagerSnapshot {
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = CPULoad(total: nil, cores: loads.map { CoreLoad(kind: .unknown, load: $0) })
        snapshot.gpu = gpu
        return snapshot
    }

    static func cluster(_ name: String, _ cores: ClosedRange<Int>, megahertz: Double, idle: Double,
                        maximum: Double? = nil) -> SensorReading.Cluster {
        SensorReading.Cluster(name: name, frequencyMHz: megahertz, activeShare: 1 - idle, maximumFrequencyMHz: maximum,
                              cores: cores.map { SensorReading.Core(id: $0, frequencyMHz: megahertz, activeShare: nil) })
    }

    static let m4MaxSensors = SensorReading(
        cpuMilliwatts: 12_900, gpuMilliwatts: 4710, aneMilliwatts: 820, combinedMilliwatts: 18_430,
        clusters: [cluster("E-Cluster", 0...3, megahertz: 2112, idle: 0.53, maximum: 2592),
                   cluster("P0-Cluster", 4...9, megahertz: 4056, idle: 0.28, maximum: 4512),
                   cluster("P1-Cluster", 10...15, megahertz: 1260, idle: 0.92, maximum: 4512)],
        gpuFrequencyMHz: 1146)

    static let gpu = GPULoadReading(utilization: 0.27, usedMemoryBytes: 3 << 30)

    /// E 0–3 zu 25 %, P 4–15 zu 50 %.
    static let m4MaxLoads: [Double?] = Array(repeating: 0.25, count: 4) + Array(repeating: 0.5, count: 12)

    @Test func headSummarizesTheChip() throws {
        let page = ChipPresentation.page(profile: try Self.profile("m4-max"), snapshot: Self.snapshot(loads: []),
                                         sensors: nil, thermalState: .nominal)
        #expect(page.title == "Apple M4 Max")
        #expect(page.summary == "12 Leistungskerne · 4 Effizienzkerne · 40 GPU-Kerne · "
            + "\(ProcessCleanupPresentation.memoryText(64 << 30)) gemeinsamer Arbeitsspeicher")
        #expect(page.engines == "Media Engine: 2 Videoencoder · 1 Videodecoder · 2 ProRes-Engines · Neural Engine")
    }

    /// Bewertung 2026.11.7-1188, Mangel 5: Die Cluster zeigen nur den Takt. „aktiv“ aus `idle_ratio` widersprach der
    /// Kernauslastung und ist nicht an echter `powermetrics`-Ausgabe belegt.
    @Test func levelPanelsWithHelper() throws {
        let page = ChipPresentation.page(profile: try Self.profile("m4-max"),
                                         snapshot: Self.snapshot(loads: Self.m4MaxLoads, gpu: Self.gpu),
                                         sensors: Self.m4MaxSensors, thermalState: .nominal)
        let performance = try #require(page.levels.first)
        #expect(performance.kind == .performance)
        #expect(performance.title == "Leistungskerne")
        #expect(performance.detail == "12 Kerne · 2 Cluster à 6 Kerne · je 16 MB L2")
        #expect(performance.value == "50 %")
        #expect(performance.weight == 12)
        let l1 = "\(ProcessCleanupPresentation.memoryText(192 << 10))/\(ProcessCleanupPresentation.memoryText(128 << 10))"
        #expect(performance.facts == [ChipPage.Fact("Takt max.", "4,5 GHz"), ChipPage.Fact("L1 Befehle/Daten", l1)])
        #expect(performance.clusters == [
            ChipPage.ClusterRow(title: "Cluster P0", detail: "4,1 GHz", cores: Array(4...9)),
            ChipPage.ClusterRow(title: "Cluster P1", detail: "1,3 GHz", cores: Array(10...15)),
        ])
        let efficiency = try #require(page.levels.last)
        #expect(efficiency.kind == .efficiency)
        #expect(efficiency.title == "Effizienzkerne")
        #expect(efficiency.detail == "4 Kerne · 1 Cluster · 4 MB L2")
        #expect(efficiency.value == "25 %")
        #expect(efficiency.clusters == [ChipPage.ClusterRow(title: "Cluster E", detail: "2,1 GHz",
                                                            cores: Array(0...3))])
    }

    @Test func energyGPUAndNeuralEngineWithHelper() throws {
        let page = ChipPresentation.page(profile: try Self.profile("m4-max"),
                                         snapshot: Self.snapshot(loads: Self.m4MaxLoads, gpu: Self.gpu),
                                         sensors: Self.m4MaxSensors, thermalState: .fair)
        #expect(!page.showsHelperHint)
        #expect(page.energy.map(\.title) == ["Gesamt", "CPU", "GPU", "Neural Engine", "Thermischer Zustand"])
        #expect(page.energy.map(\.value) == ["18,4 W", "12,9 W", "4,71 W", "0,82 W", "Erhöht"])
        #expect(page.energy.map(\.milliwatts) == [18_430, 12_900, 4710, 820, nil])
        #expect(page.energy.map(\.kind) == [.total, .cpu, .gpu, .neuralEngine, .thermal(.fair)])
        #expect(page.gpu == ChipPage.Unit(title: "GPU", detail: "40 Kerne", value: "27 %", facts: [
            ChipPage.Fact("Takt", "1,1 GHz"), ChipPage.Fact("Leistung", "4,71 W"),
            ChipPage.Fact("Gemeinsamer Speicher", ProcessCleanupPresentation.memoryText(3 << 30)),
        ]))
        #expect(page.neuralEngine == ChipPage.Unit(title: "Neural Engine", detail: "1 Block", value: "0,82 W",
                                                   facts: [ChipPage.Fact("Zustand", "aktiv")]))
    }

    /// Ohne Helper: alles aus sysctl, IORegistry und Kernlast bleibt, Takt, Aktivität und Watt zeigen „–“.
    @Test func withoutHelperOnlyRootFreeValues() throws {
        let page = ChipPresentation.page(profile: try Self.profile("m4-max"),
                                         snapshot: Self.snapshot(loads: Self.m4MaxLoads, gpu: Self.gpu),
                                         sensors: nil, thermalState: .nominal)
        #expect(page.showsHelperHint)
        #expect(page.energy.map(\.value) == ["–", "–", "–", "–", "Normal"])
        #expect(page.levels[0].value == "50 %")
        #expect(page.levels[0].facts.first == ChipPage.Fact("Takt max.", "–"))
        #expect(page.levels[0].clusters.map(\.detail) == ["", ""])
        #expect(page.gpu.value == "27 %")
        #expect(page.gpu.facts.prefix(2) == [ChipPage.Fact("Takt", "–"), ChipPage.Fact("Leistung", "–")])
        #expect(page.neuralEngine.value == "–")
        #expect(page.neuralEngine.facts == [ChipPage.Fact("Zustand", "–")])
    }

    /// Ultra: vier Leistungscluster über beide Chips; Sensor-Cluster werden über die Kernnummern zugeordnet, ohne Kerne
    /// (älterer Helper) über den Namen.
    @Test func ultraMatchesSensorClustersByCoresThenName() throws {
        let sensors = SensorReading(clusters: [
            Self.cluster("P2-Cluster", 16...19, megahertz: 3204, idle: 0.62),
            SensorReading.Cluster(name: "P3-Cluster", frequencyMHz: 702, activeShare: 0.02),
        ])
        let page = ChipPresentation.page(profile: try Self.profile("m2-ultra"), snapshot: Self.snapshot(loads: []),
                                         sensors: sensors, thermalState: .nominal)
        #expect(page.levels[0].detail == "16 Kerne · 4 Cluster à 4 Kerne · je 16 MB L2")
        #expect(page.levels[0].clusters.map(\.title) == ["Cluster P0", "Cluster P1", "Cluster P2", "Cluster P3"])
        #expect(page.levels[0].clusters.map(\.detail) == ["", "", "3,2 GHz", "702 MHz"])
        #expect(page.levels[1].clusters.map(\.cores) == [Array(0...3), Array(12...15)])
        #expect(page.levels[0].value == "–")
        #expect(page.neuralEngine.detail == "2 Blöcke")
        #expect(page.engines == "Media Engine: 4 Videoencoder · 2 Videodecoder · 4 ProRes-Engines · Neural Engine: 2 Blöcke")
    }

    /// Künftige Stufennamen erscheinen mit Rückfall; die mittlere Stufe ohne Namen ist eine neutrale Klasse. Ohne
    /// Gerätebaum kennt die Stufe ihre Cluster nicht – dann zählt `cpusperl2`.
    @Test func unknownLevelNamesAndClustersFallBack() {
        let facts = ChipFacts(brand: "Apple M9", levels: [
            ChipFacts.Level(name: "Super", logicalCPUs: 2, l2CacheBytes: 8 << 20, cpusPerL2: 2),
            ChipFacts.Level(name: nil, logicalCPUs: 4, l2CacheBytes: 8 << 20, cpusPerL2: 2),
            ChipFacts.Level(name: "Efficiency", logicalCPUs: 2),
        ])
        let page = ChipPresentation.page(profile: ChipProfile(facts: facts), snapshot: Self.snapshot(loads: []),
                                         sensors: nil, thermalState: .nominal)
        #expect(page.levels.map(\.title) == ["Super-Kerne", "Kerne der Stufe 2", "Effizienzkerne"])
        #expect(page.levels.map(\.kind) == [.super, .other(level: 1, name: nil), .efficiency])
        #expect(page.levels.map(\.detail) == ["2 Kerne · 1 Cluster · 8 MB L2", "4 Kerne · 2 Cluster à 2 Kerne · je 8 MB L2",
                                              "2 Kerne"])
        #expect(page.levels.allSatisfy { $0.clusters.isEmpty })
        #expect(page.summary == "2 Super-Kerne · 4 Kerne der Stufe 2 · 2 Effizienzkerne")
        #expect(page.engines == nil)
    }

    /// Pegel des thermischen Zustands in vier Stufen.
    @Test func thermalLevels() throws {
        let profile = try Self.profile("m1")
        let levels = [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical].map { state in
            ChipPresentation.page(profile: profile, snapshot: Self.snapshot(loads: []), sensors: nil,
                                  thermalState: state).energy.last?.level
        }
        #expect(levels == [0.25, 0.5, 0.75, 1])
    }

    @Test func idleNeuralEngineIsAtRest() throws {
        var sensors = Self.m4MaxSensors
        sensors.aneMilliwatts = 0
        let page = ChipPresentation.page(profile: try Self.profile("m4-max"), snapshot: Self.snapshot(loads: []),
                                         sensors: sensors, thermalState: .nominal)
        #expect(page.neuralEngine.value == "0,00 W")
        #expect(page.neuralEngine.facts == [ChipPage.Fact("Zustand", "in Ruhe")])
    }
}
