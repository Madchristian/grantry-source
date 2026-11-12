import Foundation

/// Spalten des Prozess-Tabs (Spec §2).
public enum ProcessColumn: String, Hashable, Sendable, CaseIterable, Identifiable {
    case name, cpu, memory, disk, network, energy, energyTrend

    /// Volle Heatmap-Intensität: Datenträger 100 MB/s, Netzwerk 10 MB/s, Energie 5 W.
    static let fullDiskRate = 100e6
    static let fullNetworkRate = 10e6
    static let fullEnergyMilliwatts = 5_000.0
    private static let locale = Locale(identifier: "de_DE")

    public var id: Self { self }

    public var title: String {
        switch self {
        case .name: "Name"
        case .cpu: "CPU"
        case .memory: "Speicher"
        case .disk: "Datenträger"
        case .network: "Netzwerk"
        case .energy: "Energie"
        case .energyTrend: "Trend"
        }
    }

    /// Wert als Text: „2,3 %“, „412 MB“, „1,2 MB/s“; „–“, wenn nicht gemessen (Spec §5). Für `.name` leer.
    public func text(_ figures: ProcessFigures) -> String {
        switch self {
        case .name: ""
        case .cpu: figures.cpuLoad.map(Self.percent) ?? "–"
        case .memory: figures.memoryBytes.map(ProcessCleanupPresentation.memoryText) ?? "–"
        case .disk: figures.diskPerSecond.map(TrafficFormat.rate) ?? "–"
        case .network: figures.networkPerSecond.map(TrafficFormat.rate) ?? "–"
        case .energy: EnergyFormat.power(figures.energyMilliwatts)
        case .energyTrend: figures.energyTrendMilliwatts.map { EnergyLevel(milliwatts: $0).title } ?? "–"
        }
    }

    /// Intensität der Heatmap (0…1), `nil` ohne Wert. Wurzelskala, damit kleine Werte sichtbar bleiben: 1 % CPU ≈ 0,1,
    /// 25 % ≈ 0,5; Speicher als Anteil am physischen Speicher. Der Trend zeigt die Intensität seiner Stufe.
    public func heat(_ figures: ProcessFigures, physicalMemory: UInt64) -> Double? {
        if self == .energyTrend { return figures.energyTrendMilliwatts.map { EnergyLevel(milliwatts: $0).heat } }
        let share: Double? = switch self {
        case .name, .energyTrend: nil
        case .cpu: figures.cpuLoad
        case .memory: figures.memoryBytes.map { Double($0) / Double(max(physicalMemory, 1)) }
        case .disk: figures.diskPerSecond.map { $0 / Self.fullDiskRate }
        case .network: figures.networkPerSecond.map { $0 / Self.fullNetworkRate }
        case .energy: figures.energyMilliwatts.map { $0 / Self.fullEnergyMilliwatts }
        }
        return share.map { min(max($0, 0), 1).squareRoot() }
    }

    /// Sortierwert; `nil` sortiert immer ans Ende.
    func value(_ figures: ProcessFigures) -> Double? {
        switch self {
        case .name: nil
        case .cpu: figures.cpuLoad
        case .memory: figures.memoryBytes.map { Double($0) }
        case .disk: figures.diskPerSecond
        case .network: figures.networkPerSecond
        case .energy: figures.energyMilliwatts
        case .energyTrend: figures.energyTrendMilliwatts
        }
    }

    static func percent(_ load: Double) -> String {
        load.formatted(.percent.precision(.fractionLength(1)).locale(locale))
    }
}

/// Sortierung des Prozess-Tabs; Standard wie Windows 11 nach CPU absteigend.
public struct ProcessSort: Hashable, Sendable {
    public var column: ProcessColumn
    public var ascending: Bool

    public static let `default` = ProcessSort(column: .cpu, ascending: false)

    public init(column: ProcessColumn, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }

    /// Klick auf einen Spaltenkopf: dieselbe Spalte kehrt die Richtung um, eine neue beginnt bei Werten absteigend, beim
    /// Namen aufsteigend.
    public func selecting(_ column: ProcessColumn) -> ProcessSort {
        column == self.column ? ProcessSort(column: column, ascending: !ascending)
            : ProcessSort(column: column, ascending: column == .name)
    }
}

extension ProcessGroupKind {
    public var title: String {
        switch self {
        case .apps: "Apps"
        case .background: "Hintergrundprozesse"
        case .system: "System und andere Benutzer"
        }
    }

    /// Hinweis am Gruppenkopf.
    public var note: String? {
        switch self {
        case .system: "CPU und Speicher anderer Benutzer stammen aus ps (CPU geglättet, Speicher als RSS); Datenträger "
            + "liest macOS nur mit Administratorrechten."
        case .apps, .background: nil
        }
    }
}

/// Bedienzustand des Prozess-Tabs: Suche, Sortierung, zugeklappte Gruppen, aufgeklappte Apps.
public struct ProcessListOptions: Hashable, Sendable {
    public var query = ""
    public var sort = ProcessSort.default
    public var collapsedGroups: Set<ProcessGroupKind> = []
    public var expandedEntries: Set<String> = []

    public init() {}

    /// Gruppenkopf bzw. App auf- oder zuklappen; andere Zeilen bleiben unverändert.
    public mutating func toggle(_ row: ProcessListRow) {
        switch row.kind {
        case .group(let kind, _):
            if collapsedGroups.remove(kind) == nil { collapsedGroups.insert(kind) }
        case .entry(let entry, _):
            if expandedEntries.remove(entry.id) == nil { expandedEntries.insert(entry.id) }
        case .child:
            break
        }
    }
}

/// Eine sichtbare Zeile des Prozess-Tabs; die Tabelle zeigt sie flach in dieser Reihenfolge, Kinder eingerückt.
public struct ProcessListRow: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case group(ProcessGroupKind, isCollapsed: Bool)
        /// App oder einzelner Prozess der obersten Ebene.
        case entry(ProcessGroupEntry, isExpanded: Bool)
        /// Prozess einer aufgeklappten App.
        case child(ProcessMeasurement)
    }

    public let id: String
    public let kind: Kind
    public let group: ProcessGroupKind
    public let title: String
    /// „PID 4242“, „12 Prozesse“.
    public let detail: String
    public let figures: ProcessFigures

    /// Gruppenkopf oder App mit mehreren Prozessen.
    public var isExpandable: Bool {
        switch kind {
        case .group: true
        case .entry(let entry, _): entry.app != nil && entry.processes.count > 1
        case .child: false
        }
    }

    public var isExpanded: Bool {
        switch kind {
        case .group(_, let isCollapsed): !isCollapsed
        case .entry(_, let isExpanded): isExpanded
        case .child: false
        }
    }
}

public struct ProcessListPresentation: Hashable, Sendable {
    public let rows: [ProcessListRow]
    /// Werte der Spaltenköpfe: CPU und Speicher systemweit, sobald gemessen (TM4), sonst Summe der gemessenen Prozesse.
    public let totals: ProcessFigures
    public let processCount: Int
    /// Bezug der Speicher-Heatmap.
    public let physicalMemory: UInt64

    public static let empty = ProcessListPresentation(rows: [], totals: .sum([]), processCount: 0, physicalMemory: 1)

    /// Text eines Spaltenkopfs: Gesamtwert bzw. bei `.name` die Prozesszahl.
    public func headerValue(_ column: ProcessColumn) -> String {
        column == .name ? "\(processCount) Prozesse" : column.text(totals)
    }

    public func heat(_ column: ProcessColumn, _ figures: ProcessFigures) -> Double? {
        column.heat(figures, physicalMemory: physicalMemory)
    }
}

/// Baut die Zeilen des Prozess-Tabs (Spec §2): Gruppen, Suche nach Name oder PID, Sortierung je Spalte – ungemessene
/// Werte stehen in beiden Richtungen am Ende. Rein; die Oberfläche ruft es je Takt mit dem neuen Stand auf.
public enum ProcessListPresenter {
    public static func present(
        _ snapshot: TaskManagerSnapshot, apps: [RunningApp], currentUID: UInt32, network: [ProcessKey: Double]?,
        options: ProcessListOptions,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> ProcessListPresentation {
        let groups = ProcessGrouper.group(snapshot.processes, apps: apps, currentUID: currentUID, network: network)
        let query = options.query.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [ProcessListRow] = []
        for group in groups {
            let entries = ordered(group.entries.filter { query.isEmpty || matches($0, query) }, by: options.sort,
                                  name: \.name, figures: \.totals, id: \.id)
            guard !entries.isEmpty else { continue }
            let isCollapsed = options.collapsedGroups.contains(group.kind)
            // Bei einer Suche zählen und summieren die Gruppen nur ihre Treffer (Bewertung 2026.11.7, Mangel 8:
            // „Apps 111 Prozesse“ bei einem Treffer).
            let processCount = query.isEmpty ? group.processCount : entries.reduce(0) { $0 + $1.processes.count }
            let figures = query.isEmpty ? group.totals : .sum(entries.map(\.totals))
            rows.append(ProcessListRow(id: "group:\(group.kind.rawValue)",
                                       kind: .group(group.kind, isCollapsed: isCollapsed), group: group.kind,
                                       title: group.kind.title, detail: count(processCount), figures: figures))
            guard !isCollapsed else { continue }
            for entry in entries {
                rows += self.rows(for: entry, in: group.kind, query: query, options: options)
            }
        }
        return ProcessListPresentation(rows: rows, totals: totals(snapshot, measured: .sum(groups.map(\.totals))),
                                       processCount: snapshot.processes.count,
                                       physicalMemory: snapshot.memory?.physicalBytes ?? physicalMemory)
    }

    private static func rows(for entry: ProcessGroupEntry, in group: ProcessGroupKind, query: String,
                             options: ProcessListOptions) -> [ProcessListRow] {
        let isApp = entry.app != nil && entry.processes.count > 1
        let isExpanded = isApp && options.expandedEntries.contains(entry.id)
        let detail = isApp ? count(entry.processes.count) : "PID \(entry.processes[0].key.pid)"
        let head = ProcessListRow(id: entry.id, kind: .entry(entry, isExpanded: isExpanded), group: group,
                                  title: title(entry.name, pid: entry.processes[0].key.pid), detail: detail,
                                  figures: entry.totals)
        guard isApp else { return [head] }
        // Bei einer Suche, die nur Kinder trifft, erscheinen die passenden Kinder auch ohne Aufklappen.
        let searchHits = query.isEmpty || entry.name.localizedCaseInsensitiveContains(query)
            ? [] : entry.processes.indices.filter { matches(entry.processes[$0], query) }
        let shown = isExpanded ? Array(entry.processes.indices) : searchHits
        let children = ordered(shown, by: options.sort, name: { entry.processes[$0].name },
                               figures: { entry.figures[$0] }, id: { entry.processes[$0].key.id })
        return [head] + children.map { index in
            let process = entry.processes[index]
            return ProcessListRow(id: "child:\(process.key.id)", kind: .child(process), group: group,
                                  title: title(process.name, pid: process.key.pid), detail: "PID \(process.key.pid)",
                                  figures: entry.figures[index])
        }
    }

    static func matches(_ entry: ProcessGroupEntry, _ query: String) -> Bool {
        entry.name.localizedCaseInsensitiveContains(query) || entry.processes.contains { matches($0, query) }
    }

    static func matches(_ process: ProcessMeasurement, _ query: String) -> Bool {
        process.name.localizedCaseInsensitiveContains(query) || String(process.key.pid).hasPrefix(query)
    }

    /// Nach `sort`; ohne Wert ans Ende, bei Gleichstand nach Name und Kennung (stabile Reihenfolge je Takt).
    static func ordered<Item>(_ items: [Item], by sort: ProcessSort, name: (Item) -> String,
                              figures: (Item) -> ProcessFigures, id: (Item) -> String) -> [Item] {
        TableOrdering.sorted(items, ascending: sort.ascending, byText: sort.column == .name,
                             number: { sort.column.value(figures($0)) }, text: name, id: id)
    }

    /// Spaltenköpfe: CPU und Speicher systemweit, sobald gemessen (TM4), sonst Summe der gemessenen Prozesse.
    static func totals(_ snapshot: TaskManagerSnapshot, measured all: ProcessFigures) -> ProcessFigures {
        ProcessFigures(cpuLoad: snapshot.cpu?.total ?? cappedLoad(all.cpuLoad),
                       memoryBytes: snapshot.memory?.usedBytes ?? all.memoryBytes,
                       diskPerSecond: all.diskPerSecond, networkPerSecond: all.networkPerSecond,
                       energyMilliwatts: all.energyMilliwatts, energyTrendMilliwatts: all.energyTrendMilliwatts)
    }

    /// Summe von CPU-Anteilen, höchstens alle Kerne: Über Kerne hinweg kann sie durch Messabstände knapp über 100 % liegen.
    static func cappedLoad(_ load: Double?) -> Double? { load.map { min($0, 1) } }

    static func title(_ name: String, pid: Int32) -> String { name.isEmpty ? "Prozess \(pid)" : name }

    private static func count(_ processes: Int) -> String { processes == 1 ? "1 Prozess" : "\(processes) Prozesse" }
}
