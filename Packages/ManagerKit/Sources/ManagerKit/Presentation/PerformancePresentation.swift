import Foundation

/// Kachel des Leistung-Tabs (Spec 2026-11-06 §2): CPU, Arbeitsspeicher, je Laufwerk, je Netzwerkschnittstelle, GPU;
/// mit Helper die Leistungsaufnahme (TM-9.4).
public enum PerformanceMetric: Hashable, Sendable {
    case cpu, memory, drive(String), interface(String), gpu, power
}

public struct PerformanceTile: Hashable, Sendable, Identifiable {
    public let metric: PerformanceMetric
    public let title: String
    public let value: String
    public let detail: String
    /// Wert für VoiceOver: Raten ausgeschrieben („Lesen 1,2 KB/s, Schreiben –“) statt „L … · S …“ und Pfeilen.
    public let spokenValue: String

    public var id: PerformanceMetric { metric }

    /// Titel für VoiceOver: bei Schnittstellen mit Anzeigenamen samt BSD-Namen („Ethernet en8“), den Übersicht und Popover
    /// nicht zeigen. Die Gegenprobe der Default-Route (`scripts/performance/plausibility.py`, #373) liest ihn ebenso.
    public var spokenTitle: String {
        guard case .interface = metric, !detail.isEmpty else { return title }
        return "\(title) \(detail)"
    }

    /// Beschriftung der Kachel für VoiceOver (Design-Standard §4, Bewertung 2026.11.7 Mangel 12, #378): ein Element mit
    /// Titel, Detail und Wert. Kacheln gleicher Art unterscheiden sich über Laufwerk bzw. Schnittstelle.
    public var accessibilityLabel: String {
        [spokenTitle, spokenTitle == title ? detail : "", spokenValue].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    public init(metric: PerformanceMetric, title: String, value: String, detail: String, spokenValue: String? = nil) {
        self.metric = metric
        self.title = title
        self.value = value
        self.detail = detail
        self.spokenValue = spokenValue ?? value
    }
}

/// Kerne einer Stufe (`CoreKind`) mit mittlerer Auslastung, für ein Panel der Ansicht „Pro Kern“.
public struct CoreCluster: Hashable, Sendable, Identifiable {
    public let kind: CoreKind
    /// Kernnummern wie von macOS geliefert, aufsteigend.
    public let cores: [Int]
    /// Mittel der aktuellen Kernauslastungen (0…1); `nil` vor der zweiten Messung.
    public let load: Double?

    public var id: CoreKind { kind }

    public init(kind: CoreKind, cores: [Int], load: Double?) {
        self.kind = kind
        self.cores = cores
        self.load = load
    }

    public var title: String { kind.title }

    /// „12 Kerne · CPU 4–15“; die Spanne nur bei lückenlosen Nummern.
    public var detail: String {
        let count = cores.count == 1 ? "1 Kern" : "\(cores.count) Kerne"
        guard let first = cores.first, let last = cores.last, cores.count > 1, last - first == cores.count - 1 else {
            return count
        }
        return "\(count) · CPU \(first)–\(last)"
    }
}

/// Kennzahl unter dem großen Graphen.
public struct PerformanceStat: Hashable, Sendable, Identifiable {
    public let title: String
    public let value: String

    public var id: String { title }

    public init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }
}

/// Kacheln, Kennzahlen und Auswahl des Leistung-Tabs (Spec 2026-11-06 §2, §5). Nicht Gemessenes erscheint als „–“,
/// nie als 0.
public enum PerformancePresentation {
    public static let missing = "–"

    /// Kacheln in fester Reihenfolge. Nicht eingerichtete Quellen haben keine; die GPU auch dann nicht, wenn gerade
    /// keine Auslastung lesbar ist (Spec §3: „fehlt der Wert, Kachel aus“).
    /// Mit `sensors` (Helper, TM-9.4) zuletzt die Kachel „Leistungsaufnahme“, sofern eine Gesamtleistung vorliegt.
    public static func tiles(for snapshot: TaskManagerSnapshot, configured: Set<TaskManagerSource>,
                             sensors: SensorReading? = nil) -> [PerformanceTile] {
        baseTiles(for: snapshot, configured: configured) + [sensorTile(sensors)].compactMap { $0 }
    }

    private static func baseTiles(for snapshot: TaskManagerSnapshot, configured: Set<TaskManagerSource>)
        -> [PerformanceTile] {
        var tiles: [PerformanceTile] = []
        if configured.contains(.cpu) {
            tiles.append(PerformanceTile(metric: .cpu, title: "CPU", value: percent(snapshot.cpu?.total),
                                         detail: snapshot.cpu.map { "\($0.cores.count) Kerne" } ?? ""))
        }
        if configured.contains(.memory) {
            tiles.append(PerformanceTile(metric: .memory, title: "Arbeitsspeicher", value: memoryUsage(snapshot.memory),
                                         detail: snapshot.memory.map { percent(usedShare(of: $0)) } ?? ""))
        }
        tiles += snapshot.drives.map { drive in
            PerformanceTile(metric: .drive(drive.id), title: drive.name,
                            value: "L \(rate(drive.readPerSecond)) · S \(rate(drive.writePerSecond))", detail: drive.id,
                            spokenValue: "Lesen \(rate(drive.readPerSecond)), Schreiben \(rate(drive.writePerSecond))")
        }
        tiles += visibleInterfaces(snapshot.interfaces).map { interface in
            PerformanceTile(metric: .interface(interface.name), title: interface.displayName ?? interface.name,
                            value: "↓ \(rate(interface.receivedPerSecond)) · ↑ \(rate(interface.sentPerSecond))",
                            detail: interface.displayName == nil ? "" : interface.name,
                            spokenValue: "Empfangen \(rate(interface.receivedPerSecond)), "
                                + "Senden \(rate(interface.sentPerSecond))")
        }
        if configured.contains(.gpu), let gpu = snapshot.gpu, gpu.utilization != nil {
            tiles.append(PerformanceTile(metric: .gpu, title: "GPU", value: percent(gpu.utilization),
                                         detail: gpu.usedMemoryBytes.map(ProcessCleanupPresentation.memoryText) ?? ""))
        }
        return tiles
    }

    /// Kennzahlen der gewählten Kachel; feste Titel, damit das Raster beim Umschalten nicht springt.
    /// `sensors`/`thermalState` nur für die Kachel „Leistungsaufnahme“ (TM-9.4).
    public static func stats(for metric: PerformanceMetric, in snapshot: TaskManagerSnapshot,
                             uptime: TimeInterval, sensors: SensorReading? = nil,
                             thermalState: ProcessInfo.ThermalState = .nominal) -> [PerformanceStat] {
        switch metric {
        case .cpu:
            return [PerformanceStat("Auslastung", percent(snapshot.cpu?.total)),
                    PerformanceStat("Kerne", snapshot.cpu.map { coreKindsText($0.cores) } ?? missing),
                    PerformanceStat("Prozesse", count(processCount(in: snapshot))),
                    PerformanceStat("Threads", ThreadTotal(snapshot.processes)?.text ?? missing),
                    PerformanceStat("Laufzeit", uptimeText(uptime))]
        case .memory:
            let memory = snapshot.memory, components = memory?.components
            return [PerformanceStat("Belegt", memoryUsage(memory)),
                    PerformanceStat("Komprimiert", bytes(components?.compressedBytes)),
                    PerformanceStat("Zugeordnet", bytes(components?.wiredBytes)),
                    PerformanceStat("Cache", bytes(components?.cachedBytes)),
                    PerformanceStat("Swap", memory.map(swapText) ?? missing),
                    PerformanceStat("Speicherdruck",
                                    memory?.pressure.map(ProcessCleanupPresentation.pressureText) ?? missing)]
        case .drive(let id):
            let drive = snapshot.drives.first { $0.id == id }
            return [PerformanceStat("Lesen", rate(drive?.readPerSecond)),
                    PerformanceStat("Schreiben", rate(drive?.writePerSecond)),
                    PerformanceStat("Aktive Zeit", percent(drive?.activeShare)),
                    PerformanceStat("Vorgänge", drive?.operationsPerSecond.map { "\(number(Int($0.rounded())))/s" }
                        ?? missing)]
        case .interface(let name):
            let interface = snapshot.interfaces.first { $0.name == name }
            let addresses = interface?.addresses.filter { !isLinkLocal($0) } ?? []
            return [PerformanceStat("Empfangen", rate(interface?.receivedPerSecond)),
                    PerformanceStat("Senden", rate(interface?.sentPerSecond)),
                    PerformanceStat("Adressen", addresses.isEmpty ? missing : addresses.joined(separator: ", "))]
        case .gpu:
            return [PerformanceStat("Auslastung", percent(snapshot.gpu?.utilization)),
                    PerformanceStat("Gemeinsamer Speicher", bytes(snapshot.gpu?.usedMemoryBytes))]
        case .power:
            return sensorStats(sensors, thermalState: thermalState)
        }
    }

    /// Schnittstellen mit Kachel: kein Loopback und mindestens eine Adresse außerhalb von Link-Local – blendet
    /// ungenutzte Tunnel, AWDL und Thunderbolt-Ports ohne Verbindung aus.
    public static func visibleInterfaces(_ interfaces: [InterfaceThroughput]) -> [InterfaceThroughput] {
        interfaces.filter { interface in
            !interface.name.hasPrefix("lo") && interface.addresses.contains { !isLinkLocal($0) }
        }
    }

    /// Schnittstelle für Übersicht und Popover (Bewertung 2026.11.7-1188, Mangel 4): die der Default-Route, sonst die
    /// mit dem meisten Verkehr, sonst die erste – jeweils unter den sichtbaren (`visibleInterfaces`).
    public static func primaryInterface(in interfaces: [InterfaceThroughput]) -> InterfaceThroughput? {
        let visible = visibleInterfaces(interfaces)
        if let routed = visible.first(where: \.isPrimary) { return routed }
        let traffic = { (interface: InterfaceThroughput) in
            (interface.receivedPerSecond ?? 0) + (interface.sentPerSecond ?? 0)
        }
        // `max(by:)` behält bei Gleichstand das erste Element, ohne Messwerte also die erste sichtbare.
        return visible.max { traffic($0) < traffic($1) }
    }

    /// Kachel der Schnittstelle aus `primaryInterface(in:)`, sofern es sie unter `tiles` gibt.
    public static func primaryInterfaceTile(in tiles: [PerformanceTile], for snapshot: TaskManagerSnapshot)
        -> PerformanceTile? {
        guard let name = primaryInterface(in: snapshot.interfaces)?.name else { return nil }
        return tiles.first { $0.metric == .interface(name) }
    }

    /// Die gewählte Kachel, solange es sie gibt; sonst die erste (z. B. abgezogenes Laufwerk).
    public static func resolvedSelection(_ selection: PerformanceMetric?, in tiles: [PerformanceTile])
        -> PerformanceMetric? {
        tiles.contains { $0.metric == selection } ? selection : tiles.first?.metric
    }

    /// Kerncluster für die Ansicht „Pro Kern“ (Optik 2026-11-07, Runde 2): je Kernklasse ein Panel, schnellste zuerst
    /// (Super-, Leistungs-, Effizienzkerne, #589), ohne Kerntypen (Intel, virtuelle Maschine) ein gemeinsames Panel.
    /// Innerhalb eines Clusters bleiben Reihenfolge und Nummern von macOS (`host_processor_info`).
    public static func coreClusters(_ cores: [CoreLoad]) -> [CoreCluster] {
        Dictionary(grouping: cores.indices, by: { cores[$0].kind }).sorted { $0.key < $1.key }.map { kind, indices in
            let loads = indices.compactMap { cores[$0].load }
            return CoreCluster(kind: kind, cores: indices, load: loads.isEmpty ? nil : loads.reduce(0, +) / Double(loads.count))
        }
    }

    /// Laufzeit wie Windows 11: Tage:Stunden:Minuten:Sekunden.
    public static func uptimeText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d:%02d", total / 86_400, total / 3_600 % 24, total / 60 % 60, total % 60)
    }

    public static func percent(_ share: Double?) -> String {
        share.map { "\(Int(($0 * 100).rounded())) %" } ?? missing
    }

    public static func usedShare(of memory: MemoryStatus) -> Double? {
        guard let used = memory.usedBytes, memory.physicalBytes > 0 else { return nil }
        return Double(used) / Double(memory.physicalBytes)
    }

    static func memoryUsage(_ memory: MemoryStatus?) -> String {
        guard let memory, let used = memory.usedBytes else { return missing }
        return "\(bytes(used)) von \(bytes(memory.physicalBytes))"
    }

    static func swapText(_ memory: MemoryStatus) -> String {
        guard let used = memory.swapUsedBytes, let total = memory.swapTotalBytes else { return missing }
        return total == 0 ? "kein Swap" : "\(bytes(used)) von \(bytes(total))"
    }

    /// „12 P · 4 E“, „6 S · 12 P“: Kerne je Klasse mit Kürzel, schnellste zuerst, kurz wie im Kernraster. Mit nur einer
    /// Klasse oder einer ohne Kürzel nur die Gesamtzahl.
    private static func coreKindsText(_ cores: [CoreLoad]) -> String {
        let clusters = coreClusters(cores)
        let parts = clusters.compactMap { cluster in cluster.kind.tag.map { "\(cluster.cores.count) \($0)" } }
        guard parts.count > 1, parts.count == clusters.count else { return "\(cores.count)" }
        return parts.joined(separator: " · ")
    }

    /// Ohne Prozessquelle (TM3) aus dem Speicherstand, der alle Prozesse zählt.
    private static func processCount(in snapshot: TaskManagerSnapshot) -> Int? {
        snapshot.processes.isEmpty ? snapshot.memory?.processCount : snapshot.processes.count
    }

    static func isLinkLocal(_ address: String) -> Bool {
        address.lowercased().hasPrefix("fe80:") || address.hasPrefix("169.254.")
    }

    private static func rate(_ bytesPerSecond: Double?) -> String { bytesPerSecond.map(TrafficFormat.rate) ?? missing }

    private static func bytes(_ count: UInt64?) -> String {
        count.map(ProcessCleanupPresentation.memoryText) ?? missing
    }

    private static func count(_ value: Int?) -> String { value.map(number) ?? missing }

    private static func number(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "de_DE")))
    }
}

extension MemoryComponents.Kind {
    /// Name der Ebene in der Speicher-Stapelfläche.
    public var title: String {
        switch self {
        case .app: "App"
        case .wired: "Zugeordnet"
        case .compressed: "Komprimiert"
        case .cached: "Cache"
        }
    }
}
