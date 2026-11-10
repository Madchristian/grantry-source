import Foundation

/// Karte der Übersicht der Menüleiste (#495) in fester Reihenfolge; in den Einstellungen einzeln ausblendbar.
public enum MenuBarOverviewCard: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case cpu, cores, processes, gpu, memory, disk, network, thermal, battery, summary

    public var id: Self { self }

    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .cores: "Kerne"
        case .processes: "Prozesse"
        case .gpu: "GPU"
        case .memory: "Arbeitsspeicher"
        case .disk: "Datenträger"
        case .network: "Netz"
        case .thermal: "Thermik"
        case .battery: "Akku"
        case .summary: "Last und Laufzeit"
        }
    }
}

/// Was die Übersicht außer dem Takt braucht – alles aus vorhandenen Quellen: Sensoren nur, wenn der Helper ohnehin misst
/// (`SensorModel`), das Startvolume einmal beim Öffnen (`VolumeUsage`), die laufenden Apps wie der Prozess-Tab.
public struct MenuBarOverviewContext: Sendable {
    public var sensors: SensorReading?
    public var startupVolume: VolumeUsage?
    public var apps: [RunningApp]
    public var currentUID: UInt32
    public var loadAverage: LoadAverage?
    /// Sekunden seit dem Start des Macs.
    public var uptime: TimeInterval?
    public var hidden: Set<MenuBarOverviewCard>

    public init(sensors: SensorReading? = nil, startupVolume: VolumeUsage? = nil, apps: [RunningApp] = [],
                currentUID: UInt32 = getuid(), loadAverage: LoadAverage? = nil, uptime: TimeInterval? = nil,
                hidden: Set<MenuBarOverviewCard> = []) {
        self.sensors = sensors
        self.startupVolume = startupVolume
        self.apps = apps
        self.currentUID = currentUID
        self.loadAverage = loadAverage
        self.uptime = uptime
        self.hidden = hidden
    }
}

/// Inhalt der Übersicht, fertig formatiert. Eine Karte fehlt (`nil`), wenn ihre Quelle nichts liefert oder sie
/// ausgeblendet ist; ein fehlender Wert in einer Karte ist „–“ bzw. `nil`, nie 0.
public struct MenuBarOverview: Equatable, Sendable {
    public struct CPU: Equatable, Sendable {
        public let total: Double?
        public let value: String
        /// Benutzer = Gesamtlast ohne Systemanteil.
        public let user: Double?
        public let system: Double?
        public let userText: String
        public let systemText: String
        /// Mittlerer Takt der Leistungscluster, nur mit Helper-Messung.
        public let clock: String?
    }

    /// Ring eines Kerns; `id` ist die Kernnummer von macOS.
    public struct CoreRing: Equatable, Sendable, Identifiable {
        public let id: Int
        public let kind: CoreKind
        public let load: Double?
        public let accessibilityLabel: String
        public let accessibilityValue: String
    }

    /// Kerne eines physischen Clusters („P0“, „E“) bzw. ohne Gerätebaum einer Kernart.
    public struct CoreGroup: Equatable, Sendable, Identifiable {
        public let kind: CoreKind
        public let label: String?
        public let rings: [CoreRing]

        public var id: Int { rings.first?.id ?? -1 }
    }

    /// Mittlere Last einer Kernart.
    public struct CoreAverage: Equatable, Sendable, Identifiable {
        public let kind: CoreKind
        public let title: String
        /// „P“, „E“; ohne Kerntypen `nil`.
        public let tag: String?
        public let coreCount: Int
        public let load: Double?
        public let value: String

        public var id: CoreKind { kind }
    }

    public struct Cores: Equatable, Sendable {
        public let groups: [CoreGroup]
        public let averages: [CoreAverage]
    }

    /// Prozess oder App mit allen ihren Prozessen, wie im Prozess-Tab gruppiert.
    public struct ProcessEntry: Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let app: RunningApp?
        /// Prozess eines anderen Benutzers (Gruppe „System“).
        public let isSystem: Bool
        public let share: Double
        public let value: String
    }

    public struct Processes: Equatable, Sendable {
        /// Leer bis zur zweiten Messung der Prozessquelle.
        public let entries: [ProcessEntry]
    }

    /// Ring mit Wert und Beschriftung; nur für gemessene Werte.
    public struct Ring: Equatable, Sendable, Identifiable {
        public let caption: String
        public let value: String
        public let fraction: Double

        public var id: String { caption }
    }

    public struct GPU: Equatable, Sendable {
        public let value: String
        public let rings: [Ring]
        public let clock: String?
    }

    /// Bestandteil des belegten Speichers als Anteil am physischen Speicher.
    public struct MemoryPart: Equatable, Sendable, Identifiable {
        public let kind: MemoryComponents.Kind
        public let share: Double

        public var id: MemoryComponents.Kind { kind }
    }

    public struct Memory: Equatable, Sendable {
        public let usedShare: Double?
        public let value: String
        public let detail: String
        public let parts: [MemoryPart]
        public let pressure: MemoryStatus.Pressure?
        public let pressureText: String
        public let swap: String
    }

    public struct Disk: Equatable, Sendable {
        /// Erstes Laufwerk wie im Popover „Auslastung“; `nil` ohne gemessenes Laufwerk.
        public let driveID: String?
        public let usedShare: Double?
        public let free: String?
        public let read: String
        public let write: String
    }

    public struct Network: Equatable, Sendable {
        public let interfaceName: String
        public let title: String
        public let received: String
        public let sent: String

        /// Titel für VoiceOver wie `PerformanceTile.spokenTitle`: Anzeigename samt BSD-Namen („USB LAN en8“), den die
        /// Karte nicht zeigt; die Gegenprobe der Default-Route (`interface.popover`, plausibility.py) liest ihn.
        public var spokenTitle: String { title == interfaceName ? title : "\(title) \(interfaceName)" }
    }

    public struct Thermal: Equatable, Sendable {
        public let state: ProcessInfo.ThermalState
        public let value: String
        public let tone: PresentationTone
        /// Füllstand je Stufe wie im Chip-Tab.
        public let level: Double?
        public let lowPowerMode: String
    }

    public struct Battery: Equatable, Sendable {
        public let charge: Double?
        public let value: String
        public let state: String
        public let isCharging: Bool
    }

    public struct Summary: Equatable, Sendable {
        public let loadAverage: String?
        public let uptime: String?
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

    /// Kachel in „Leistung“, auf die ein Klick auf die Karte springt; `nil` für Karten mit eigenem Tab oder ohne Kachel.
    public func metric(for card: MenuBarOverviewCard) -> PerformanceMetric? {
        switch card {
        case .cpu, .summary: .cpu
        case .gpu: .gpu
        case .memory: .memory
        case .disk: disk?.driveID.map(PerformanceMetric.drive)
        case .network: network.map { .interface($0.interfaceName) }
        case .cores, .processes, .thermal, .battery: nil
        }
    }

    /// Vorhandene Karten in fester Reihenfolge.
    public var cards: [MenuBarOverviewCard] {
        let present: [MenuBarOverviewCard: Bool] = [
            .cpu: cpu != nil, .cores: cores != nil, .processes: processes != nil, .gpu: gpu != nil,
            .memory: memory != nil, .disk: disk != nil, .network: network != nil, .thermal: thermal != nil,
            .battery: battery != nil, .summary: summary != nil,
        ]
        return MenuBarOverviewCard.allCases.filter { present[$0] == true }
    }
}

/// Übersicht der Menüleiste (#495): rechnet nur aus dem fertigen Stand des Task-Managers (`TaskManagerSnapshot`) und dem
/// Kontext, mit denselben Texten wie die Tabs (`PerformancePresentation`, `EnergyPresentation`, `ProcessListPresentation`).
public enum MenuBarOverviewPresentation {
    static let missing = PerformancePresentation.missing
    static let topProcessCount = 3

    /// Quellen des offenen Popovers (Abnehmer `menuBarPopover`): alle außer Prozessen, GPU und Akku ausgeblendeter
    /// Karten – die Prozessquelle ist der teuerste Teil des Takts. CPU, Speicher, Datenträger und Netz liest das Element
    /// ohnehin (`MenuBarMeterKind.overview.sources`).
    public static func sources(hiding hidden: Set<MenuBarOverviewCard>) -> Set<TaskManagerSource> {
        let optional: [MenuBarOverviewCard: TaskManagerSource] = [.processes: .processes, .gpu: .gpu, .battery: .battery]
        return Set(TaskManagerSource.allCases).subtracting(hidden.compactMap { optional[$0] })
    }

    public static func overview(for snapshot: TaskManagerSnapshot, profile: ChipProfile,
                                context: MenuBarOverviewContext) -> MenuBarOverview {
        let shown = { (card: MenuBarOverviewCard) in !context.hidden.contains(card) }
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
        if shown(.summary) { overview.summary = summary(context) }
        return overview
    }

    // MARK: - CPU und Kerne

    private static func cpu(_ load: CPULoad, sensors: SensorReading?) -> MenuBarOverview.CPU {
        let user = load.total.flatMap { total in load.system.map { max(total - $0, 0) } }
        return MenuBarOverview.CPU(
            total: load.total, value: percent(load.total), user: user, system: load.system,
            userText: percent(user), systemText: percent(load.system),
            clock: ChipPresentation.clockHead(sensors).map { PerformancePresentation.frequency($0.megahertz) }
        )
    }

    /// Gruppen wie im Chip-Tab: Stufen (Leistungskerne zuerst), darin die physischen Cluster. Passt das Profil nicht zu
    /// den gemessenen Kernen, je Kernart eine Gruppe wie in „Pro Kern“.
    static func cores(_ cores: [CoreLoad], profile: ChipProfile) -> MenuBarOverview.Cores? {
        guard !cores.isEmpty else { return nil }
        let ring = { (core: Int) in coreRing(core, of: cores[core]) }
        let clustered = profile.levels.flatMap { level in
            level.clusters.map { cluster in (cluster.label, cluster.cores) }
        }
        let fitsProfile = clustered.flatMap(\.1).sorted() == Array(cores.indices)
            && !cores.contains { $0.kind == .unknown }
        let groups = fitsProfile
            ? clustered.map { label, members in
                MenuBarOverview.CoreGroup(kind: cores[members[0]].kind, label: label, rings: members.map(ring))
            }
            : PerformancePresentation.coreClusters(cores).map { cluster in
                MenuBarOverview.CoreGroup(kind: cluster.kind, label: nil, rings: cluster.cores.map(ring))
            }
        let averages = PerformancePresentation.coreClusters(cores).map { cluster in
            MenuBarOverview.CoreAverage(kind: cluster.kind, title: cluster.title, tag: tag(of: cluster.kind),
                                        coreCount: cluster.cores.count, load: cluster.load,
                                        value: percent(cluster.load))
        }
        return MenuBarOverview.Cores(groups: groups, averages: averages)
    }

    private static func coreRing(_ index: Int, of core: CoreLoad) -> MenuBarOverview.CoreRing {
        let name = switch core.kind {
        case .performance: "Leistungskern"
        case .efficiency: "Effizienzkern"
        case .unknown: "Kern"
        }
        return MenuBarOverview.CoreRing(id: index, kind: core.kind, load: core.load,
                                        accessibilityLabel: "\(name) \(index)",
                                        accessibilityValue: core.load.map { percent($0) } ?? "keine Messung")
    }

    private static func tag(of kind: CoreKind) -> String? {
        switch kind {
        case .performance: "P"
        case .efficiency: "E"
        case .unknown: nil
        }
    }

    // MARK: - Prozesse

    /// Die drei Einträge mit der höchsten CPU-Last, gruppiert wie im Prozess-Tab (App mit Helfern als ein Eintrag).
    private static func processes(_ processes: [ProcessMeasurement], context: MenuBarOverviewContext)
        -> MenuBarOverview.Processes? {
        guard !processes.isEmpty else { return nil }
        let groups = ProcessGrouper.group(processes, apps: context.apps, currentUID: context.currentUID)
        // Erst auswählen, dann formatieren: Bei Hunderten Prozessen kostete das Formatieren aller Einträge je Takt mehr als
        // die Gruppierung (Time Profiler, #495).
        var top: [(entry: ProcessGroupEntry, isSystem: Bool, share: Double)] = []
        for group in groups {
            for entry in group.entries {
                guard let share = entry.totals.cpuLoad else { continue }
                let rank = top.firstIndex { share > $0.share || (share == $0.share && entry.name < $0.entry.name) }
                    ?? top.count
                guard rank < topProcessCount else { continue }
                top.insert((entry, group.kind == .system, share), at: rank)
                if top.count > topProcessCount { top.removeLast() }
            }
        }
        return MenuBarOverview.Processes(entries: top.map { entry, isSystem, share in
            MenuBarOverview.ProcessEntry(id: entry.id, name: entry.name, app: entry.app, isSystem: isSystem,
                                         share: share, value: ProcessColumn.percent(share))
        })
    }

    // MARK: - GPU und Speicher

    private static func gpu(_ snapshot: TaskManagerSnapshot, profile: ChipProfile, sensors: SensorReading?)
        -> MenuBarOverview.GPU? {
        guard let gpu = snapshot.gpu, let utilization = gpu.utilization else { return nil }
        var rings = [MenuBarOverview.Ring(caption: "Auslastung", value: percent(utilization), fraction: utilization)]
        if let used = gpu.usedMemoryBytes, let physical = snapshot.memory?.physicalBytes ?? profile.memoryBytes,
           physical > 0 {
            let share = min(Double(used) / Double(physical), 1)
            rings.append(MenuBarOverview.Ring(caption: "Speicher", value: percent(share), fraction: share))
        }
        return MenuBarOverview.GPU(value: percent(utilization), rings: rings,
                                   clock: sensors?.gpuFrequencyMHz.map(PerformancePresentation.frequency))
    }

    private static func memory(_ memory: MemoryStatus) -> MenuBarOverview.Memory {
        let used = PerformancePresentation.usedShare(of: memory)
        let physical = Double(memory.physicalBytes)
        let parts: [MenuBarOverview.MemoryPart] = memory.components.map { components in
            [(MemoryComponents.Kind.app, components.appBytes), (.wired, components.wiredBytes),
             (.compressed, components.compressedBytes)].map { kind, bytes in
                MenuBarOverview.MemoryPart(kind: kind, share: physical > 0 ? Double(bytes) / physical : 0)
            }
        } ?? []
        return MenuBarOverview.Memory(
            usedShare: used, value: percent(used), detail: PerformancePresentation.memoryUsage(memory), parts: parts,
            pressure: memory.pressure,
            pressureText: memory.pressure.map(ProcessCleanupPresentation.pressureText) ?? missing,
            swap: PerformancePresentation.swapText(memory)
        )
    }

    // MARK: - Datenträger und Netz

    private static func disk(_ drive: DriveThroughput?, volume: VolumeUsage?) -> MenuBarOverview.Disk? {
        guard drive != nil || volume != nil else { return nil }
        let usedShare = volume.map { Double($0.usedBytes) / Double($0.totalBytes) }
        return MenuBarOverview.Disk(
            driveID: drive?.id, usedShare: usedShare,
            free: volume.map { "\(AppTexts.formattedSize($0.availableBytes)) frei von \(AppTexts.formattedSize($0.totalBytes))" },
            read: rate(drive?.readPerSecond), write: rate(drive?.writePerSecond)
        )
    }

    private static func network(_ interface: InterfaceThroughput) -> MenuBarOverview.Network {
        MenuBarOverview.Network(interfaceName: interface.name, title: interface.displayName ?? interface.name,
                                received: rate(interface.receivedPerSecond), sent: rate(interface.sentPerSecond))
    }

    // MARK: - Thermik, Akku, Zusammenfassung

    private static func thermal(_ condition: ThermalCondition) -> MenuBarOverview.Thermal {
        let detail = TaskManagerMenuBarPresentation.thermalDetail(condition)
        return MenuBarOverview.Thermal(
            state: condition.state, value: PerformancePresentation.thermalText(condition.state),
            tone: detail.items.first?.tone ?? .neutral, level: ChipPresentation.thermalLevel(condition.state),
            lowPowerMode: condition.isLowPowerModeEnabled ? "Energiesparmodus an" : "Energiesparmodus aus"
        )
    }

    private static func battery(_ battery: BatteryReading) -> MenuBarOverview.Battery {
        MenuBarOverview.Battery(charge: battery.charge, value: EnergyPresentation.chargeText(battery),
                                state: EnergyPresentation.stateText(battery), isCharging: battery.isCharging)
    }

    private static func summary(_ context: MenuBarOverviewContext) -> MenuBarOverview.Summary? {
        guard context.loadAverage != nil || context.uptime != nil else { return nil }
        let number = { (value: Double) in
            value.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "de_DE")))
        }
        return MenuBarOverview.Summary(
            loadAverage: context.loadAverage.map { [$0.one, $0.five, $0.fifteen].map(number).joined(separator: " · ") },
            uptime: context.uptime.map(PerformancePresentation.uptimeText)
        )
    }

    private static func percent(_ share: Double?) -> String { PerformancePresentation.percent(share) }

    private static func rate(_ bytesPerSecond: Double?) -> String { bytesPerSecond.map(TrafficFormat.rate) ?? missing }
}
