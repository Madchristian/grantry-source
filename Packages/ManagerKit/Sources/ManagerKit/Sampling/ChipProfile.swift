import Foundation

/// Statische Daten des Apple-Chips für den Chip-Tab und die Kerntypen (`CPULoadSampler`), generisch für M1 bis M6:
/// beliebig viele Leistungsstufen (`hw.nperflevels`), Cluster je Stufe aus dem Gerätebaum (Ultra: verschränkte
/// Kernnummern beider Chips). Keine Chiptabelle; was sich nicht eindeutig zuordnen lässt, bleibt leer statt falsch.
public struct ChipProfile: Hashable, Sendable {
    /// Ein physischer Cluster (gemeinsamer L2-Cache) mit seinen logischen Kernnummern.
    public struct Cluster: Hashable, Sendable {
        /// Typ und Nummer wie bei `powermetrics` („E“, „P0“, „P1“ …); `nil` ohne Gerätebaum.
        public let label: String?
        public let cores: [Int]

        public init(label: String?, cores: [Int]) {
            self.label = label
            self.cores = cores
        }
    }

    /// Eine Leistungsstufe (`hw.perflevelN`, 0 = schnellste).
    public struct Level: Hashable, Sendable {
        /// Name laut System („Performance“, „Efficiency“).
        public let name: String?
        public let coreCount: Int
        /// L2-Cache eines Clusters; `coresPerL2` Kerne teilen ihn.
        public let l2CacheBytes: UInt64?
        public let coresPerL2: Int?
        public let l1InstructionBytes: UInt64?
        public let l1DataBytes: UInt64?
        /// Leer, wenn die Kerne der Stufe unbekannt sind.
        public let clusters: [Cluster]

        public var cores: [Int] { clusters.flatMap(\.cores) }
    }

    public struct MediaEngine: Hashable, Sendable {
        public let videoEncoders: Int
        public let videoDecoders: Int
        public let proResEngines: Int

        public init(videoEncoders: Int, videoDecoders: Int, proResEngines: Int) {
            self.videoEncoders = videoEncoders
            self.videoDecoders = videoDecoders
            self.proResEngines = proResEngines
        }

        public var isEmpty: Bool { videoEncoders + videoDecoders + proResEngines == 0 }
    }

    public let name: String?
    public let memoryBytes: UInt64?
    public let levels: [Level]
    public let gpuCoreCount: Int?
    /// Blöcke der Neural Engine (Ultra: zwei).
    public let neuralEngineCount: Int
    public let mediaEngine: MediaEngine

    /// Die Werte dieses Macs, beim ersten Zugriff gelesen und danach unverändert.
    public static let current = ChipProfile(facts: .system())

    public init(facts: ChipFacts) {
        name = facts.brand
        memoryBytes = facts.memoryBytes
        gpuCoreCount = facts.gpuCoreCount
        let clusters = Self.clusters(levels: facts.levels, cpus: facts.cpus)
            ?? Self.efficiencyFirst(levels: facts.levels)
        levels = facts.levels.indices.map { index in
            let level = facts.levels[index]
            return Level(name: level.name, coreCount: level.logicalCPUs, l2CacheBytes: level.l2CacheBytes,
                         coresPerL2: level.cpusPerL2, l1InstructionBytes: level.l1InstructionBytes,
                         l1DataBytes: level.l1DataBytes, clusters: clusters[index])
        }
        let count = { (prefix: String) in facts.deviceNodes.count { Self.isNode($0, prefix: prefix) } }
        neuralEngineCount = count("ane")
        mediaEngine = MediaEngine(videoEncoders: count("ave"), videoDecoders: count("avd"), proResEngines: count("apr"))
    }

    /// Apple-Chip mit Leistungsstufen; Intel und virtuelle Maschinen haben keine.
    public var isAppleSilicon: Bool { !levels.isEmpty }

    /// Kernklasse einer Stufe nach ihrem Namen laut System (`CoreKind(levelName:level:levelCount:)`, #589).
    public func kind(ofLevel index: Int) -> CoreKind {
        CoreKind(levelName: levels[index].name, level: index, levelCount: levels.count)
    }

    /// Kernart je logischer Nummer (`kind(ofLevel:)`); unbekannte Kerne `unknown`.
    public func coreKinds(coreCount: Int) -> [CoreKind] {
        var kinds = Array(repeating: CoreKind.unknown, count: coreCount)
        for (index, level) in levels.enumerated() {
            for core in level.cores where kinds.indices.contains(core) { kinds[core] = kind(ofLevel: index) }
        }
        return kinds
    }

    // MARK: - Zuordnung

    /// Cluster je Stufe aus dem Gerätebaum; `nil`, wenn Typen und Stufen nicht eindeutig zusammenpassen.
    static func clusters(levels: [ChipFacts.Level], cpus: [ChipFacts.CPU]) -> [[Cluster]]? {
        guard !cpus.isEmpty, cpus.count == levels.reduce(0, { $0 + $1.logicalCPUs }),
              Set(cpus.map(\.logicalID)).count == cpus.count,
              let assignment = assign(types: Dictionary(grouping: cpus, by: \.clusterType), to: levels)
        else { return nil }
        return levels.indices.map { index in
            let type = assignment.first { $0.value == index }?.key
            let members = cpus.filter { $0.clusterType == type }
            let groups = Dictionary(grouping: members, by: \.clusterID).values
                .map { $0.map(\.logicalID).sorted() }
                .sorted { $0[0] < $1[0] }
            return groups.enumerated().map { number, cores in
                Cluster(label: groups.count == 1 ? type : "\(type ?? "")\(number)", cores: cores)
            }
        }
    }

    /// Typ → Stufe: zuerst gleicher Anfangsbuchstabe und gleiche Kernzahl, dann eine eindeutige Kernzahl.
    private static func assign(types: [String: [ChipFacts.CPU]], to levels: [ChipFacts.Level]) -> [String: Int]? {
        guard types.count == levels.count else { return nil }
        var assignment: [String: Int] = [:]
        var free = Set(levels.indices)
        for (type, members) in types.sorted(by: { $0.key < $1.key }) {
            if let index = free.sorted().first(where: {
                levels[$0].logicalCPUs == members.count && levels[$0].name?.first?.uppercased() == type.first?.uppercased()
            }) {
                assignment[type] = index
                free.remove(index)
            }
        }
        for (type, members) in types.sorted(by: { $0.key < $1.key }) where assignment[type] == nil {
            let candidates = free.filter { levels[$0].logicalCPUs == members.count }
            guard candidates.count == 1, let index = candidates.first else { return nil }
            assignment[type] = index
            free.remove(index)
        }
        return assignment
    }

    /// Ohne Gerätebaum wie bisher: genau zwei Stufen, erst die Effizienz-, dann die Leistungskerne, ohne Cluster.
    private static func efficiencyFirst(levels: [ChipFacts.Level]) -> [[Cluster]] {
        guard levels.count == 2 else { return levels.map { _ in [] } }
        let efficiency = Array(0..<levels[1].logicalCPUs)
        let performance = Array(levels[1].logicalCPUs..<(levels[1].logicalCPUs + levels[0].logicalCPUs))
        return [[Cluster(label: nil, cores: performance)], [Cluster(label: nil, cores: efficiency)]]
    }

    /// „ave0“, „ave“: Präfix, danach höchstens Ziffern.
    private static func isNode(_ name: String, prefix: String) -> Bool {
        name.hasPrefix(prefix) && name.dropFirst(prefix.count).allSatisfy(\.isASCIIDigit)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
