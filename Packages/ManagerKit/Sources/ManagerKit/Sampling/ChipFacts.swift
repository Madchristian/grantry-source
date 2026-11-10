import Foundation
import IOKit

/// Rohwerte des Chips für `ChipProfile` (Chip-Tab), ohne Root: `sysctl` (Name, Speicher, Leistungsstufen) und die
/// IORegistry (Gerätebaum: Kern → Cluster; GPU-Kerne; Knoten der Media und Neural Engine). Die Gerätebaum-Schlüssel
/// sind von Apple nicht zugesichert: Was fehlt, bleibt leer statt geraten.
public struct ChipFacts: Codable, Hashable, Sendable {
    /// Eine Leistungsstufe `hw.perflevelN` (0 = schnellste).
    public struct Level: Codable, Hashable, Sendable {
        public var name: String?
        public var logicalCPUs: Int
        public var l2CacheBytes: UInt64?
        public var cpusPerL2: Int?
        public var l1InstructionBytes: UInt64?
        public var l1DataBytes: UInt64?

        public init(name: String?, logicalCPUs: Int, l2CacheBytes: UInt64? = nil, cpusPerL2: Int? = nil,
                    l1InstructionBytes: UInt64? = nil, l1DataBytes: UInt64? = nil) {
            self.name = name
            self.logicalCPUs = logicalCPUs
            self.l2CacheBytes = l2CacheBytes
            self.cpusPerL2 = cpusPerL2
            self.l1InstructionBytes = l1InstructionBytes
            self.l1DataBytes = l1DataBytes
        }
    }

    /// Ein Kern laut Gerätebaum (`IODeviceTree:/cpus/cpuN`).
    public struct CPU: Codable, Hashable, Sendable {
        public var logicalID: Int
        public var clusterID: Int
        /// Kerntyp als Buchstabe („E“, „P“ …).
        public var clusterType: String

        public init(logicalID: Int, clusterID: Int, clusterType: String) {
            self.logicalID = logicalID
            self.clusterID = clusterID
            self.clusterType = clusterType
        }
    }

    public var brand: String?
    public var memoryBytes: UInt64?
    public var levels: [Level]
    public var cpus: [CPU]
    public var gpuCoreCount: Int?
    /// Namen der Knoten unter `IODeviceTree:/arm-io` („ave0“, „ane0“ …).
    public var deviceNodes: [String]

    public init(brand: String? = nil, memoryBytes: UInt64? = nil, levels: [Level] = [], cpus: [CPU] = [],
                gpuCoreCount: Int? = nil, deviceNodes: [String] = []) {
        self.brand = brand
        self.memoryBytes = memoryBytes
        self.levels = levels
        self.cpus = cpus
        self.gpuCoreCount = gpuCoreCount
        self.deviceNodes = deviceNodes
    }
}

extension ChipFacts {
    /// Obergrenzen gegen unplausible Werte: Stufen, Kerne und Knoten des Gerätebaums.
    static let maximumLevels = 8
    static let maximumCPUs = 4096
    static let maximumNodes = 4096

    /// Liest die Werte dieses Macs. Kostet ein paar Hundert IORegistry-Zugriffe – nur einmal (`ChipProfile.current`)
    /// und nie auf dem Main Actor beim App-Start.
    static func system() -> ChipFacts {
        ChipFacts(
            brand: Sysctl.string("machdep.cpu.brand_string"),
            memoryBytes: Sysctl.uint64("hw.memsize"),
            levels: (0..<min(Sysctl.int("hw.nperflevels") ?? 0, maximumLevels)).compactMap(level),
            cpus: IORegistryReader.deviceTreeChildren(of: "IODeviceTree:/cpus", limit: maximumCPUs) {
                cpu(from: IORegistryReader.properties(cpuKeys, of: $0))
            }.compactMap(\.self),
            gpuCoreCount: gpuCoreCount(),
            deviceNodes: IORegistryReader.deviceTreeChildren(of: "IODeviceTree:/arm-io", limit: maximumNodes) {
                IORegistryReader.name(of: $0)
            }.compactMap(\.self)
        )
    }

    private static func level(_ index: Int) -> Level? {
        let prefix = "hw.perflevel\(index)."
        guard let logical = Sysctl.int(prefix + "logicalcpu"), logical > 0 else { return nil }
        return Level(name: Sysctl.string(prefix + "name"), logicalCPUs: logical,
                     l2CacheBytes: Sysctl.uint64(prefix + "l2cachesize"), cpusPerL2: Sysctl.int(prefix + "cpusperl2"),
                     l1InstructionBytes: Sysctl.uint64(prefix + "l1icachesize"),
                     l1DataBytes: Sysctl.uint64(prefix + "l1dcachesize"))
    }

    private static let cpuKeys = ["logical-cpu-id", "cluster-id", "cluster-type"]

    /// Ein Kern aus den Eigenschaften seines Gerätebaum-Knotens; ohne gültige Nummer, Cluster oder Typ `nil`.
    static func cpu(from properties: [String: Any]) -> CPU? {
        guard let logical = IORegistryReader.uint64(properties["logical-cpu-id"]), logical < maximumCPUs,
              let cluster = (properties["cluster-id"] as? Data).flatMap(littleEndian),
              let type = (properties["cluster-type"] as? Data).flatMap(text) else { return nil }
        return CPU(logicalID: Int(logical), clusterID: Int(cluster), clusterType: type)
    }

    /// GPU-Kerne laut Treiber (`gpu-core-count` am `IOAccelerator`); die größte Angabe bei mehreren GPUs.
    private static func gpuCoreCount() -> Int? {
        var counts: [Int] = []
        try? IORegistryReader.forEachService(matching: "IOAccelerator") { accelerator in
            if let count = IORegistryReader.uint64(IORegistryReader.property("gpu-core-count", of: accelerator)),
               count > 0, count < 10_000 {
                counts.append(Int(count))
            }
        }
        return counts.max()
    }

    private static func littleEndian(_ data: Data) -> UInt32? {
        guard data.count >= 4 else { return nil }
        return data.prefix(4).reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// Zeichenkette bis zum ersten Nullbyte, nur druckbares ASCII.
    private static func text(_ data: Data) -> String? {
        let bytes = data.prefix { $0 != 0 }
        guard !bytes.isEmpty, bytes.count <= 16, bytes.allSatisfy({ (0x21...0x7E).contains($0) }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}
