import Foundation

// Kacheln CPU, Kerne, Prozesse und GPU der Übersicht (#495, Baukasten Spec 2026-11-09-uebersicht-baukasten § 9: Teil B).
// Eigene Datei, damit die Kacheln der Rechenwerke und der Ressourcen (MenuBarOverview+Resources) getrennt wachsen.

extension MenuBarOverview {
    public struct CPU: Equatable, Sendable {
        public let total: Double?
        public let value: String
        /// Benutzer = Gesamtlast ohne Systemanteil.
        public let user: Double?
        public let system: Double?
        public let userText: String
        public let systemText: String
        /// Leerlauf = Rest bis 100 %; ohne Gesamtlast `nil`, nicht „voll im Leerlauf“.
        public let idle: Double?
        public let idleText: String
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
        /// „S“, „P“, „E“ (`CoreKind.tag`); ohne Kerntypen `nil`.
        public let tag: String?
        public let coreCount: Int
        public let load: Double?
        public let value: String

        public var id: CoreKind { kind }

        /// „12 P-Kerne“, „1 E-Kern“; ohne Kerntypen „8 Kerne“.
        public var countText: String {
            let noun = coreCount == 1 ? "Kern" : "Kerne"
            return tag.map { "\(coreCount) \($0)-\(noun)" } ?? "\(coreCount) \(noun)"
        }
    }

    public struct Cores: Equatable, Sendable {
        public let groups: [CoreGroup]
        public let averages: [CoreAverage]

        /// Für VoiceOver ausgeschrieben: „Leistungskerne 41 %, Effizienzkerne 18 %“.
        public var spokenSummary: String {
            averages.map { "\($0.title) \($0.value)" }.joined(separator: ", ")
        }
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
        /// Länge des Lastbalkens (0…1) im Vergleich der gezeigten Einträge, siehe `loadFraction(of:top:)`.
        public let loadFraction: Double
        /// Arbeitsspeicher aller Prozesse des Eintrags; ohne Messung „–“.
        public let memory: String
    }

    public struct Processes: Equatable, Sendable {
        /// Absteigend nach CPU-Last, so viele, wie die größte Kachel zeigt; leer bis zur zweiten Messung der Prozessquelle.
        public let entries: [ProcessEntry]

        /// Längster Text je Spalte der gezeigten Einträge: Die Kachel reserviert damit in jeder Zeile dieselbe Breite,
        /// ohne feste Maße, damit die Lastbalken bündig stehen.
        public static func widestValue(of entries: some Collection<ProcessEntry>) -> String {
            widest(entries.map(\.value))
        }

        public static func widestMemory(of entries: some Collection<ProcessEntry>) -> String {
            widest(entries.map(\.memory))
        }

        private static func widest(_ texts: [String]) -> String {
            texts.max { $0.count < $1.count } ?? ""
        }

        /// Einträge einer Kachel der Größe (Spec § 2): je Zeile Höhe zwei, 4 × 1 in zwei Spalten, 2 × 2 fünf, 4 × 2 fünf
        /// mit Lastbalken und Arbeitsspeicher wie die Karte aus PR 623.
        public static func capacity(of span: OverviewTileSpan) -> Int {
            switch span {
            case .wide: 2
            case .banner: 4
            case .large, .panel: 5
            default: 0
            }
        }

        static let maximumCount = OverviewTileSpan.all.map(capacity(of:)).max() ?? 0

        public func entries(for span: OverviewTileSpan) -> ArraySlice<ProcessEntry> {
            entries.prefix(Self.capacity(of: span))
        }
    }

    public struct GPU: Equatable, Sendable {
        public let utilization: Double
        public let value: String
        public let rings: [Ring]
        /// Belegter Grafikspeicher („2,1 GB“) und sein Anteil am Arbeitsspeicher; ohne Messung `nil`.
        public let memory: String?
        public let memoryShare: Double?
        public let clock: String?
    }

    /// Spitze eines Verlaufs („72 %“); Lücken zählen nicht, ohne Werte „–“.
    public static func peakText(of values: [Double?]) -> String {
        MenuBarOverviewPresentation.percent(values.compactMap { $0 }.filter(\.isFinite).max())
    }
}

extension MenuBarOverviewPresentation {
    // MARK: - CPU und Kerne

    static func cpu(_ load: CPULoad, sensors: SensorReading?) -> MenuBarOverview.CPU {
        let user = load.total.flatMap { total in load.system.map { max(total - $0, 0) } }
        let idle = load.total.map { max(1 - $0, 0) }
        return MenuBarOverview.CPU(
            total: load.total, value: percent(load.total), user: user, system: load.system,
            userText: percent(user), systemText: percent(load.system), idle: idle, idleText: percent(idle),
            clock: ChipPresentation.clockHead(sensors).map { PerformancePresentation.frequency($0.megahertz) }
        )
    }

    /// Gruppen wie im Chip-Tab: Stufen (schnellste Klasse zuerst), darin die physischen Cluster. Passt das Profil nicht zu
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
            MenuBarOverview.CoreAverage(kind: cluster.kind, title: cluster.title, tag: cluster.kind.tag,
                                        coreCount: cluster.cores.count, load: cluster.load,
                                        value: percent(cluster.load))
        }
        return MenuBarOverview.Cores(groups: groups, averages: averages)
    }

    static func coreRing(_ index: Int, of core: CoreLoad) -> MenuBarOverview.CoreRing {
        MenuBarOverview.CoreRing(id: index, kind: core.kind, load: core.load,
                                 accessibilityLabel: "\(core.kind.coreName) \(index)",
                                 accessibilityValue: core.load.map { percent($0) } ?? "keine Messung")
    }

    // MARK: - Prozesse

    /// Last, ab der der Balken des obersten Prozesses die volle Länge hat (10 % aller Kerne).
    static let fullLoadBar = 0.1

    /// Die Einträge mit der höchsten CPU-Last, gruppiert wie im Prozess-Tab (App mit Helfern als ein Eintrag), so viele,
    /// wie die größte Kachel zeigt.
    static func processes(_ processes: [ProcessMeasurement], context: MenuBarOverviewContext)
        -> MenuBarOverview.Processes? {
        guard !processes.isEmpty else { return nil }
        // Erst auswählen, dann formatieren: Bei Hunderten Prozessen kostete das Formatieren aller Einträge je Takt mehr als
        // die Gruppierung (Time Profiler, #495); seit #626 entstehen auch nur die gezeigten Einträge.
        let top = ProcessGrouper.entriesWithHighestCPULoad(processes, apps: context.apps, currentUID: context.currentUID,
                                                           count: MenuBarOverview.Processes.maximumCount)
        let highest = top.first?.cpuLoad ?? 0
        return MenuBarOverview.Processes(entries: top.map { ranked in
            MenuBarOverview.ProcessEntry(id: ranked.entry.id, name: ranked.entry.name, app: ranked.entry.app,
                                         isSystem: ranked.kind == .system, share: ranked.cpuLoad,
                                         value: ProcessColumn.percent(ranked.cpuLoad),
                                         loadFraction: loadFraction(of: ranked.cpuLoad, top: highest),
                                         memory: bytes(ranked.entry.totals.memoryBytes))
        })
    }

    /// Balkenlänge eines Eintrags: im Verhältnis zum obersten, damit die Reihenfolge auf einen Blick lesbar ist. Liegt
    /// auch der unter `fullLoadBar`, gilt diese Schwelle als volle Länge – ein ruhiger Mac zeigt keine vollen Balken.
    static func loadFraction(of share: Double, top: Double) -> Double {
        guard share.isFinite, share > 0 else { return 0 }
        return min(share / max(top, fullLoadBar), 1)
    }

    // MARK: - GPU

    static func gpu(_ snapshot: TaskManagerSnapshot, profile: ChipProfile, sensors: SensorReading?)
        -> MenuBarOverview.GPU? {
        guard let gpu = snapshot.gpu, let utilization = gpu.utilization else { return nil }
        var rings = [MenuBarOverview.Ring(caption: "Auslastung", value: percent(utilization), fraction: utilization)]
        var memoryShare: Double?
        if let used = gpu.usedMemoryBytes, let physical = snapshot.memory?.physicalBytes ?? profile.memoryBytes,
           physical > 0 {
            let share = min(Double(used) / Double(physical), 1)
            memoryShare = share
            rings.append(MenuBarOverview.Ring(caption: "Speicher", value: percent(share), fraction: share))
        }
        return MenuBarOverview.GPU(utilization: utilization, value: percent(utilization), rings: rings,
                                   memory: gpu.usedMemoryBytes.map(bytes),
                                   memoryShare: memoryShare,
                                   clock: sensors?.gpuFrequencyMHz.map(PerformancePresentation.frequency))
    }
}
