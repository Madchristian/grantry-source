import Foundation

/// Karte der Übersicht der Menüleiste aus #495, einzeln ausblendbar. Seit dem Baukasten (#499) nur noch für die
/// Übernahme ausgeblendeter Karten (`OverviewBoardLayout(migratingHiddenCards:configured:)`) und für ältere Versionen.
public enum MenuBarOverviewCard: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case cpu, cores, processes, gpu, memory, disk, network, thermal, battery, summary

    public var id: Self { self }
}

/// Was die Übersicht außer dem Takt braucht – alles aus vorhandenen Quellen: Sensoren nur, wenn der Helper ohnehin misst
/// (`SensorModel`), das Startvolume einmal beim Öffnen (`VolumeUsage`), die laufenden Apps wie der Prozess-Tab. `tiles`
/// sind die Kacheln auf der Tafel; nur ihre Werte rechnet `MenuBarOverviewPresentation`.
public struct MenuBarOverviewContext: Sendable {
    public var sensors: SensorReading?
    public var startupVolume: VolumeUsage?
    public var apps: [RunningApp]
    public var currentUID: UInt32
    public var loadAverage: LoadAverage?
    /// Sekunden seit dem Start des Macs.
    public var uptime: TimeInterval?
    public var tiles: Set<OverviewTileKind>

    public init(sensors: SensorReading? = nil, startupVolume: VolumeUsage? = nil, apps: [RunningApp] = [],
                currentUID: UInt32 = getuid(), loadAverage: LoadAverage? = nil, uptime: TimeInterval? = nil,
                tiles: Set<OverviewTileKind> = Set(OverviewTileKind.allCases)) {
        self.sensors = sensors
        self.startupVolume = startupVolume
        self.apps = apps
        self.currentUID = currentUID
        self.loadAverage = loadAverage
        self.uptime = uptime
        self.tiles = tiles
    }

    /// Kontext der Tafel `board`: liest nur, was ihre Kacheln verlangen (`OverviewTileRequirements.context`, Spec
    /// 2026-11-09-uebersicht-baukasten § 7) – ohne Prozess-Kachel keine Apps, ohne Laufzeit-Kachel keine Systemabfrage.
    @MainActor
    public init(board: OverviewBoardLayout, sensors: SensorReading?, startupVolume: VolumeUsage?,
                apps: @MainActor () -> [RunningApp] = WorkspaceRunningApplications.regularApps,
                loadAverage: () -> LoadAverage? = LoadAverage.current,
                uptime: () -> TimeInterval? = { SystemUptime.sinceBoot() }) {
        let needs = board.requirements.context
        self.init(sensors: needs.contains(.sensors) ? sensors : nil,
                  startupVolume: needs.contains(.startupVolume) ? startupVolume : nil,
                  apps: needs.contains(.runningApps) ? apps() : [],
                  loadAverage: needs.contains(.loadAverage) ? loadAverage() : nil,
                  uptime: needs.contains(.uptime) ? uptime() : nil,
                  tiles: Set(board.tiles.map(\.kind)))
    }
}

/// Inhalt der Übersicht, fertig formatiert. Ein Wert fehlt (`nil`), wenn seine Quelle nichts liefert oder seine Kachel
/// nicht auf der Tafel steht; ein fehlender Wert in einer Kachel ist „–“ bzw. `nil`, nie 0.
public struct MenuBarOverview: Equatable, Sendable {
    /// Ring mit Wert und Beschriftung; nur für gemessene Werte.
    public struct Ring: Equatable, Sendable, Identifiable {
        public let caption: String
        public let value: String
        public let fraction: Double

        public var id: String { caption }
    }

    public var cpu: CPU?
    public var cores: Cores?
    public var processes: Processes?
    public var gpu: GPU?
    public var memory: Memory?
    public var disk: Disk?
    public var network: Network?
    public var thermal: Thermal?
    public var battery: Battery?
    public var summary: Summary?

    /// Leer: alle Karten fehlen (Vorschau, Tests der Kacheln).
    public init() {}

    /// Kachel in „Leistung“, auf die ein Klick auf die Kachel der Tafel springt; `nil` für Kacheln mit eigenem Tab.
    public func metric(for kind: OverviewTileKind) -> PerformanceMetric? {
        switch kind {
        case .cpu, .loadAverage, .uptime: .cpu
        case .gpu: .gpu
        case .memory: .memory
        case .disk: disk?.driveID.map(PerformanceMetric.drive)
        case .network: network.map { .interface($0.interfaceName) }
        case .cores, .processes, .thermal, .battery: nil
        }
    }
}

/// Übersicht der Menüleiste (#495): rechnet nur aus dem fertigen Stand des Task-Managers (`TaskManagerSnapshot`) und dem
/// Kontext, mit denselben Texten wie die Tabs (`PerformancePresentation`, `EnergyPresentation`, `ProcessListPresentation`).
public enum MenuBarOverviewPresentation {
    static let missing = PerformancePresentation.missing

    public static func overview(for snapshot: TaskManagerSnapshot, profile: ChipProfile,
                                context: MenuBarOverviewContext) -> MenuBarOverview {
        let shown = { (kind: OverviewTileKind) in context.tiles.contains(kind) }
        var overview = MenuBarOverview()
        if shown(.cpu) { overview.cpu = snapshot.cpu.map { cpu($0, sensors: context.sensors) } }
        if shown(.cores) { overview.cores = snapshot.cpu.flatMap { cores($0.cores, profile: profile) } }
        if shown(.processes) { overview.processes = processes(snapshot.processes, context: context) }
        if shown(.gpu) { overview.gpu = gpu(snapshot, profile: profile, sensors: context.sensors) }
        if shown(.memory) { overview.memory = snapshot.memory.map(memory) }
        if shown(.disk) { overview.disk = disk(snapshot.drives.first, volume: context.startupVolume) }
        if shown(.network) {
            overview.network = PerformancePresentation.primaryInterface(in: snapshot.interfaces).map(network)
        }
        if shown(.thermal) { overview.thermal = snapshot.thermal.map(thermal) }
        if shown(.battery) { overview.battery = snapshot.battery.map(battery) }
        if shown(.loadAverage) || shown(.uptime) { overview.summary = summary(context) }
        return overview
    }

    static func percent(_ share: Double?) -> String { PerformancePresentation.percent(share) }

    static func rate(_ bytesPerSecond: Double?) -> String { bytesPerSecond.map(TrafficFormat.rate) ?? missing }

    static func bytes(_ count: UInt64?) -> String {
        count.map(ProcessCleanupPresentation.memoryText) ?? missing
    }
}
