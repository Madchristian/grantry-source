import Foundation
import Testing
@testable import ManagerKit

@Suite struct ChipProfileTests {
    /// `Fixtures/Chips`: M4 Max echt (sysctl und IORegistry), M1 und M2 Ultra nach Apple-Spezifikation nachgebaut.
    static func facts(_ name: String) throws -> ChipFacts {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/Chips"))
        return try JSONDecoder().decode(ChipFacts.self, from: Data(contentsOf: url))
    }

    static let kibibyte: UInt64 = 1024
    static let mebibyte: UInt64 = 1024 * 1024

    @Test func m4MaxFromRealValues() throws {
        let chip = ChipProfile(facts: try Self.facts("m4-max"))
        #expect(chip.name == "Apple M4 Max")
        #expect(chip.memoryBytes == 64 * 1024 * Self.mebibyte)
        #expect(chip.levels.map(\.name) == ["Performance", "Efficiency"])
        #expect(chip.levels[0].clusters == [ChipProfile.Cluster(label: "P0", cores: Array(4...9)),
                                            ChipProfile.Cluster(label: "P1", cores: Array(10...15))])
        #expect(chip.levels[1].clusters == [ChipProfile.Cluster(label: "E", cores: Array(0...3))])
        #expect(chip.levels[0].l2CacheBytes == 16 * Self.mebibyte)
        #expect(chip.levels[0].coresPerL2 == 6)
        #expect(chip.levels[0].l1InstructionBytes == 192 * Self.kibibyte)
        #expect(chip.levels[0].l1DataBytes == 128 * Self.kibibyte)
        #expect(chip.gpuCoreCount == 40)
        #expect(chip.neuralEngineCount == 1)
        #expect(chip.mediaEngine == ChipProfile.MediaEngine(videoEncoders: 2, videoDecoders: 1, proResEngines: 2))
        #expect(chip.coreKinds(coreCount: 16)
            == Array(repeating: .efficiency, count: 4) + Array(repeating: .performance, count: 12))
    }

    /// Ultra: Die Kernnummern laufen je Chip erst über die Effizienz-, dann über die Leistungskerne.
    @Test func ultraInterleavesClustersOfBothDies() throws {
        let chip = ChipProfile(facts: try Self.facts("m2-ultra"))
        #expect(chip.levels[0].clusters.map(\.label) == ["P0", "P1", "P2", "P3"])
        #expect(chip.levels[0].cores == Array(4...11) + Array(16...23))
        #expect(chip.levels[1].clusters == [ChipProfile.Cluster(label: "E0", cores: Array(0...3)),
                                            ChipProfile.Cluster(label: "E1", cores: Array(12...15))])
        let efficiency = Array(repeating: CoreKind.efficiency, count: 4)
        let performance = Array(repeating: CoreKind.performance, count: 8)
        #expect(chip.coreKinds(coreCount: 24) == efficiency + performance + efficiency + performance)
        #expect(chip.neuralEngineCount == 2)
        #expect(chip.mediaEngine == ChipProfile.MediaEngine(videoEncoders: 4, videoDecoders: 2, proResEngines: 4))
    }

    @Test func m1HasOneClusterPerLevel() throws {
        let chip = ChipProfile(facts: try Self.facts("m1"))
        #expect(chip.levels.map(\.clusters) == [[ChipProfile.Cluster(label: "P", cores: Array(4...7))],
                                                [ChipProfile.Cluster(label: "E", cores: Array(0...3))]])
        #expect(chip.mediaEngine == ChipProfile.MediaEngine(videoEncoders: 1, videoDecoders: 1, proResEngines: 0))
    }

    /// Künftige Chips mit drei Stufen und eigenen Namen: Zuordnung über Kernzahl und Anfangsbuchstaben; die mittlere
    /// Stufe ist weder Leistungs- noch Effizienzkern.
    @Test func threeLevelsAreMappedByCountAndInitial() {
        let facts = ChipFacts(levels: [Self.level("Super", 2), Self.level("Performance", 4), Self.level("Efficiency", 2)],
                              cpus: Self.cpus([("E", 2), ("S", 2), ("P", 4)]))
        let chip = ChipProfile(facts: facts)
        #expect(chip.levels.map(\.cores) == [[2, 3], [4, 5, 6, 7], [0, 1]])
        #expect(chip.levels.map { $0.clusters.map(\.label) } == [["S"], ["P"], ["E"]])
        #expect(chip.coreKinds(coreCount: 8) == [.efficiency, .efficiency, .performance, .performance,
                                                 .unknown, .unknown, .unknown, .unknown])
    }

    /// Typen ohne passenden Namen, aber mit eindeutiger Kernzahl.
    @Test func unknownTypesAreMappedByUniqueCount() {
        let facts = ChipFacts(levels: [Self.level("Performance", 6), Self.level("Efficiency", 4)],
                              cpus: Self.cpus([("X", 4), ("Y", 6)]))
        #expect(ChipProfile(facts: facts).levels.map(\.cores) == [Array(4...9), Array(0...3)])
    }

    /// Nicht eindeutig zuordenbar oder ohne Gerätebaum: wie bisher erst Effizienz-, dann Leistungskerne, ohne Cluster.
    @Test(arguments: [
        [ChipFacts.CPU](),
        deviceTree([("X", 4), ("Y", 4)]),
        deviceTree([("E", 4), ("P", 2)]),
    ])
    func unclearDeviceTreeFallsBackToEfficiencyFirst(_ cpus: [ChipFacts.CPU]) {
        let facts = ChipFacts(levels: [Self.level("Performance", 4), Self.level("Efficiency", 4)], cpus: cpus)
        let chip = ChipProfile(facts: facts)
        #expect(chip.levels.map(\.clusters) == [[ChipProfile.Cluster(label: nil, cores: Array(4...7))],
                                                [ChipProfile.Cluster(label: nil, cores: Array(0...3))]])
        #expect(chip.coreKinds(coreCount: 8)
            == Array(repeating: .efficiency, count: 4) + Array(repeating: .performance, count: 4))
    }

    /// Ohne Gerätebaum lassen sich nur genau zwei Stufen raten; sonst keine Kerne statt falscher.
    @Test func withoutDeviceTreeThreeLevelsStayWithoutCores() {
        let facts = ChipFacts(levels: [Self.level("A", 2), Self.level("B", 2), Self.level("C", 2)])
        let chip = ChipProfile(facts: facts)
        #expect(chip.levels.allSatisfy { $0.cores.isEmpty })
        #expect(chip.coreKinds(coreCount: 6) == Array(repeating: .unknown, count: 6))
    }

    /// Intel und virtuelle Maschinen: keine Stufen, keine Kerntypen, kein Chip-Tab.
    @Test func withoutLevelsThereIsNoAppleSilicon() {
        let chip = ChipProfile(facts: ChipFacts(brand: "Intel(R) Core(TM) i9", memoryBytes: 1 << 34))
        #expect(!chip.isAppleSilicon)
        #expect(chip.coreKinds(coreCount: 4) == Array(repeating: .unknown, count: 4))
        #expect(chip.mediaEngine.isEmpty)
    }

    /// Mehr Kerne als bekannt (Zählung weicht ab): Die übrigen bleiben `unknown`.
    @Test func coresBeyondTheProfileAreUnknown() throws {
        let chip = ChipProfile(facts: try Self.facts("m1"))
        #expect(chip.coreKinds(coreCount: 10).suffix(2) == [.unknown, .unknown])
    }

    /// Werte aus dem Gerätebaum: Zeichenketten mit Nullbyte, Cluster-Nummer als 4 Byte Little Endian.
    @Test func deviceTreeEntriesAreDecoded() {
        let cpu = ChipFacts.cpu(from: ["logical-cpu-id": 5, "cluster-id": Data([2, 0, 0, 0]),
                                       "cluster-type": Data("P\0".utf8)])
        #expect(cpu == ChipFacts.CPU(logicalID: 5, clusterID: 2, clusterType: "P"))
        #expect(ChipFacts.cpu(from: ["logical-cpu-id": 5, "cluster-type": Data("P\0".utf8)]) == nil)
        #expect(ChipFacts.cpu(from: ["logical-cpu-id": -1, "cluster-id": Data([0, 0, 0, 0]),
                                     "cluster-type": Data("E\0".utf8)]) == nil)
    }

    @Test func readsThisMac() {
        let chip = ChipProfile.current
        #if arch(arm64)
        #expect(chip.isAppleSilicon)
        #expect(chip.name?.hasPrefix("Apple") == true)
        #expect(chip.levels.allSatisfy { !$0.clusters.isEmpty && $0.clusters.allSatisfy { $0.label != nil } })
        #expect(chip.gpuCoreCount ?? 0 > 0)
        #endif
        #expect(chip.coreKinds(coreCount: Sysctl.int("hw.ncpu") ?? 0).count == Sysctl.int("hw.ncpu"))
    }

    static func level(_ name: String, _ count: Int) -> ChipFacts.Level {
        ChipFacts.Level(name: name, logicalCPUs: count)
    }

    /// Kerne in Reihenfolge der Nummern, je Eintrag ein Cluster.
    static func cpus(_ clusters: [(type: String, count: Int)]) -> [ChipFacts.CPU] {
        var next = 0
        return clusters.enumerated().flatMap { cluster, entry in
            (0..<entry.count).map { _ in
                defer { next += 1 }
                return ChipFacts.CPU(logicalID: next, clusterID: cluster, clusterType: entry.type)
            }
        }
    }
}

private func deviceTree(_ clusters: [(type: String, count: Int)]) -> [ChipFacts.CPU] { ChipProfileTests.cpus(clusters) }
