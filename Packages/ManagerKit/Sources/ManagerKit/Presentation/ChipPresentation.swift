import Foundation

/// Inhalt des Chip-Tabs (Apple Silicon), fertig formatiert: Kopf, Energie und Thermik, je Leistungsstufe ein Panel
/// mit Clustern, GPU und Neural Engine. Ohne Helper bleiben Takt, Aktivität und Watt „–“.
public struct ChipPage: Hashable, Sendable {
    /// Kennzahl „Titel Wert“.
    public struct Fact: Hashable, Sendable {
        public let title: String
        public let value: String

        public init(_ title: String, _ value: String) {
            self.title = title
            self.value = value
        }
    }

    /// Anzeige der Energiezeile. Den Pegel der Watt-Werte setzt die Oberfläche aus `milliwatts` und der Skala des
    /// Leistungsverlaufs; der thermische Zustand bringt ihn als `level` mit.
    public struct Readout: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case total, cpu, gpu, neuralEngine
            case thermal(ProcessInfo.ThermalState)
        }

        public let kind: Kind
        public let title: String
        public let value: String
        public let milliwatts: Double?
        /// Füllstand 0…1, nur beim thermischen Zustand.
        public let level: Double?
    }

    /// Ein physischer Cluster: Titel („Cluster P0“), mit Helper Takt und Aktivität, die Kerne.
    public struct ClusterRow: Hashable, Sendable {
        public let title: String?
        public let detail: String
        public let cores: [Int]

        public init(title: String?, detail: String, cores: [Int]) {
            self.title = title
            self.detail = detail
            self.cores = cores
        }
    }

    public struct Level: Hashable, Sendable, Identifiable {
        public let id: Int
        public let kind: CoreKind
        public let title: String
        public let detail: String
        /// Mittlere Auslastung der Kerne.
        public let value: String
        public let facts: [Fact]
        public let clusters: [ClusterRow]
        /// Kernzahl – Breite des Panels.
        public let weight: Int
    }

    /// GPU oder Neural Engine.
    public struct Unit: Hashable, Sendable {
        public let title: String
        public let detail: String
        public let value: String
        public let facts: [Fact]

        public init(title: String, detail: String, value: String, facts: [Fact]) {
            self.title = title
            self.detail = detail
            self.value = value
            self.facts = facts
        }
    }

    public let title: String
    public let summary: String
    /// Media Engine und Neural Engine; `nil`, wenn der Gerätebaum keine nennt.
    public let engines: String?
    public let energy: [Readout]
    /// Ohne Helper-Messung: Hinweis, dass Takt, Aktivität und Watt fehlen.
    public let showsHelperHint: Bool
    public let levels: [Level]
    public let gpu: Unit
    public let neuralEngine: Unit
}

public enum ChipPresentation {
    static let missing = PerformancePresentation.missing

    public static func page(profile: ChipProfile, snapshot: TaskManagerSnapshot, sensors: SensorReading?,
                            thermalState: ProcessInfo.ThermalState) -> ChipPage {
        let levels = profile.levels.indices.map { level($0, of: profile, snapshot: snapshot, sensors: sensors) }
        return ChipPage(
            title: profile.name ?? "Apple Silicon",
            summary: summary(profile, levelTitles: levels.map(\.title)),
            engines: engines(profile),
            energy: energy(sensors, thermalState: thermalState),
            showsHelperHint: sensors == nil,
            levels: levels,
            gpu: gpu(profile, snapshot: snapshot, sensors: sensors),
            neuralEngine: neuralEngine(profile, sensors: sensors)
        )
    }

    // MARK: - Kopf und Energie

    private static func summary(_ profile: ChipProfile, levelTitles: [String]) -> String {
        var parts = zip(profile.levels, levelTitles).map { "\($0.coreCount) \($1)" }
        if let cores = profile.gpuCoreCount { parts.append("\(cores) GPU-Kerne") }
        if let memory = profile.memoryBytes {
            parts.append("\(ProcessCleanupPresentation.memoryText(memory)) gemeinsamer Arbeitsspeicher")
        }
        return parts.joined(separator: " · ")
    }

    private static func engines(_ profile: ChipProfile) -> String? {
        let media = profile.mediaEngine
        let blocks = [(media.videoEncoders, "Videoencoder"), (media.videoDecoders, "Videodecoder"),
                      (media.proResEngines, "ProRes-Engines")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        var parts = blocks.isEmpty ? [] : ["Media Engine: " + blocks.joined(separator: " · ")]
        switch profile.neuralEngineCount {
        case 0: break
        case 1: parts.append("Neural Engine")
        case let count: parts.append("Neural Engine: \(count) Blöcke")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func energy(_ sensors: SensorReading?, thermalState: ProcessInfo.ThermalState) -> [ChipPage.Readout] {
        let parts: [(ChipPage.Readout.Kind, String, Double?)] = [
            (.total, "Gesamt", sensors?.combinedMilliwatts), (.cpu, "CPU", sensors?.cpuMilliwatts),
            (.gpu, "GPU", sensors?.gpuMilliwatts), (.neuralEngine, "Neural Engine", sensors?.aneMilliwatts),
        ]
        return parts.map { ChipPage.Readout(kind: $0, title: $1, value: watts($2), milliwatts: $2, level: nil) }
            + [ChipPage.Readout(kind: .thermal(thermalState), title: "Thermischer Zustand",
                                value: PerformancePresentation.thermalText(thermalState), milliwatts: nil,
                                level: thermalLevel(thermalState))]
    }

    /// Normal ein Viertel, kritisch voll.
    static func thermalLevel(_ state: ProcessInfo.ThermalState) -> Double? {
        switch state {
        case .nominal: 0.25
        case .fair: 0.5
        case .serious: 0.75
        case .critical: 1
        @unknown default: nil
        }
    }

    // MARK: - Leistungsstufen

    private static func level(_ index: Int, of profile: ChipProfile, snapshot: TaskManagerSnapshot,
                              sensors: SensorReading?) -> ChipPage.Level {
        let level = profile.levels[index]
        let matched = level.clusters.map { cluster in (cluster, sensors.flatMap { sensorCluster(for: cluster, in: $0) }) }
        let loads = level.cores.compactMap { core in
            snapshot.cpu?.cores.indices.contains(core) == true ? snapshot.cpu?.cores[core].load : nil
        }
        let maximum = matched.compactMap { $0.1?.maximumFrequencyMHz }.max()
        return ChipPage.Level(
            id: index,
            kind: profile.kind(ofLevel: index),
            title: title(of: level, index: index),
            detail: detail(of: level),
            value: PerformancePresentation.percent(loads.isEmpty ? nil : loads.reduce(0, +) / Double(loads.count)),
            facts: [ChipPage.Fact("Takt max.", maximum.map(PerformancePresentation.frequency) ?? missing),
                    ChipPage.Fact("L1 Befehle/Daten", l1Text(level))],
            clusters: matched.map { cluster, sensor in
                ChipPage.ClusterRow(title: cluster.label.map { "Cluster \($0)" }, detail: sensor.map(clusterDetail) ?? "",
                                    cores: cluster.cores)
            },
            weight: level.coreCount
        )
    }

    /// „Performance“ → „Leistungskerne“; unbekannte Namen künftiger Chips mit Rückfall.
    static func title(of level: ChipProfile.Level, index: Int) -> String {
        switch level.name {
        case "Performance": "Leistungskerne"
        case "Efficiency": "Effizienzkerne"
        case let name?: "\(name)-Kerne"
        case nil: "Kerne der Stufe \(index + 1)"
        }
    }

    /// „12 Kerne · 2 Cluster à 6 Kerne · je 16 MB L2“.
    private static func detail(of level: ChipProfile.Level) -> String {
        detailParts(of: level).joined(separator: " · ")
    }

    /// Kerne, Cluster und L2-Cache einer Stufe; Teile ohne Angabe entfallen.
    static func detailParts(of level: ChipProfile.Level) -> [String] {
        var parts = [level.coreCount == 1 ? "1 Kern" : "\(level.coreCount) Kerne"]
        let clusterSizes = level.clusters.allSatisfy { $0.label != nil } && !level.clusters.isEmpty
            ? level.clusters.map(\.cores.count)
            : level.coresPerL2.flatMap { per in
                per > 0 && level.coreCount % per == 0 ? Array(repeating: per, count: level.coreCount / per) : nil
            } ?? []
        switch clusterSizes.count {
        case 0: break
        case 1: parts.append("1 Cluster")
        case let count where Set(clusterSizes).count == 1: parts.append("\(count) Cluster à \(clusterSizes[0]) Kerne")
        case let count: parts.append("\(count) Cluster")
        }
        if let l2 = level.l2CacheBytes {
            let size = ProcessCleanupPresentation.memoryText(l2)
            parts.append(clusterSizes.count > 1 ? "je \(size) L2" : "\(size) L2")
        }
        return parts
    }

    private static func l1Text(_ level: ChipProfile.Level) -> String {
        guard let instruction = level.l1InstructionBytes, let data = level.l1DataBytes else { return missing }
        return "\(ProcessCleanupPresentation.memoryText(instruction))/\(ProcessCleanupPresentation.memoryText(data))"
    }

    /// Über die Kernnummern; ohne Kerne (älterer Helper) über den Namen wie „P0-Cluster“.
    static func sensorCluster(for cluster: ChipProfile.Cluster, in sensors: SensorReading)
        -> SensorReading.Cluster? {
        sensors.clusters.first { !$0.cores.isEmpty && Set($0.cores.map(\.id)) == Set(cluster.cores) }
            ?? cluster.label.flatMap { label in sensors.clusters.first { $0.cores.isEmpty && $0.name == "\(label)-Cluster" } }
    }

    /// „4,1 GHz“. Ohne Aktivität: `activeShare` (1 − `idle_ratio`) zeigte 79–100 % bei Kernen mit 0–1 % Last und ist
    /// nicht an echter `powermetrics`-Ausgabe belegt (Fixture nachgebaut). Erst mit einem echten Mitschnitt unter Last
    /// und im Leerlauf wieder anzeigen (Bewertung 2026.11.7-1188, Mangel 5).
    private static func clusterDetail(_ cluster: SensorReading.Cluster) -> String {
        cluster.frequencyMHz.map(PerformancePresentation.frequency) ?? ""
    }

    // MARK: - GPU und Neural Engine

    private static func gpu(_ profile: ChipProfile, snapshot: TaskManagerSnapshot, sensors: SensorReading?) -> ChipPage.Unit {
        ChipPage.Unit(
            title: "GPU",
            detail: profile.gpuCoreCount.map { "\($0) Kerne" } ?? "",
            value: PerformancePresentation.percent(snapshot.gpu?.utilization),
            facts: [ChipPage.Fact("Takt", sensors?.gpuFrequencyMHz.map(PerformancePresentation.frequency) ?? missing),
                    ChipPage.Fact("Leistung", watts(sensors?.gpuMilliwatts)),
                    ChipPage.Fact("Gemeinsamer Speicher",
                                  snapshot.gpu?.usedMemoryBytes.map(ProcessCleanupPresentation.memoryText) ?? missing)]
        )
    }

    private static func neuralEngine(_ profile: ChipProfile, sensors: SensorReading?) -> ChipPage.Unit {
        let blocks = switch profile.neuralEngineCount {
        case 0: ""
        case 1: "1 Block"
        case let count: "\(count) Blöcke"
        }
        let state = sensors?.aneMilliwatts.map { $0 > 0 ? "aktiv" : "in Ruhe" } ?? missing
        return ChipPage.Unit(title: "Neural Engine", detail: blocks, value: watts(sensors?.aneMilliwatts),
                             facts: [ChipPage.Fact("Zustand", state)])
    }

    private static func watts(_ milliwatts: Double?) -> String {
        milliwatts.map(PerformancePresentation.watts) ?? missing
    }
}
