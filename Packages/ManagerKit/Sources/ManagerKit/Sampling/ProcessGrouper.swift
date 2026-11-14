/// Eine laufende App mit Fenster (`NSRunningApplication`, `activationPolicy == .regular`); Quelle:
/// `WorkspaceRunningApplications.regularApps()`.
public struct RunningApp: Hashable, Sendable {
    public let pid: Int32
    public let bundleID: String?
    /// Pfad des Bundles (`….app`); `nil`, wenn unbekannt.
    public let bundlePath: String?
    public let name: String

    public init(pid: Int32, bundleID: String?, bundlePath: String?, name: String) {
        self.pid = pid
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.name = name
    }
}

/// Gruppen des Prozess-Tabs wie in Windows 11 (Spec §2), in dieser Reihenfolge.
public enum ProcessGroupKind: String, Hashable, Sendable, CaseIterable {
    /// Apps mit Fenster samt ihren Helfern und Kindprozessen.
    case apps
    /// Eigene Prozesse ohne App.
    case background
    /// Prozesse anderer Benutzer (root, `_windowserver` …).
    case system
}

/// Werte einer Zeile oder einer Summe; `nil` = nicht gemessen, die Oberfläche zeigt „–“.
public struct ProcessFigures: Hashable, Sendable {
    /// Anteil an allen Kernen (0…1).
    public var cpuLoad: Double?
    public var memoryBytes: UInt64?
    /// Lesen + Schreiben, Byte/s.
    public var diskPerSecond: Double?
    /// Empfangen + Senden, Byte/s (`NettopSampler`); `nil`, solange nicht gemessen wird.
    public var networkPerSecond: Double?
    /// Leistung in Milliwatt (`ProcessMeasurement.energyMilliwatts`) und ihr Trend.
    public var energyMilliwatts: Double?
    public var energyTrendMilliwatts: Double?

    public init(cpuLoad: Double?, memoryBytes: UInt64?, diskPerSecond: Double?, networkPerSecond: Double?,
                energyMilliwatts: Double? = nil, energyTrendMilliwatts: Double? = nil) {
        self.cpuLoad = cpuLoad
        self.memoryBytes = memoryBytes
        self.diskPerSecond = diskPerSecond
        self.networkPerSecond = networkPerSecond
        self.energyMilliwatts = energyMilliwatts
        self.energyTrendMilliwatts = energyTrendMilliwatts
    }

    init(_ process: ProcessMeasurement, networkPerSecond: Double?) {
        self.init(cpuLoad: process.cpuLoad, memoryBytes: process.memoryBytes,
                  diskPerSecond: Self.sum([process.diskReadPerSecond, process.diskWritePerSecond]),
                  networkPerSecond: networkPerSecond, energyMilliwatts: process.energyMilliwatts,
                  energyTrendMilliwatts: process.energyTrendMilliwatts)
    }

    /// Summe der gemessenen Werte je Spalte; `nil` nur, wenn in der Spalte nichts gemessen ist.
    public static func sum(_ figures: [ProcessFigures]) -> ProcessFigures {
        ProcessFigures(cpuLoad: sum(figures.map(\.cpuLoad)), memoryBytes: sum(figures.map(\.memoryBytes)),
                       diskPerSecond: sum(figures.map(\.diskPerSecond)),
                       networkPerSecond: sum(figures.map(\.networkPerSecond)),
                       energyMilliwatts: sum(figures.map(\.energyMilliwatts)),
                       energyTrendMilliwatts: sum(figures.map(\.energyTrendMilliwatts)))
    }

    /// Summe der gemessenen Werte; `nil`, wenn keiner gemessen ist.
    static func sum<Value: AdditiveArithmetic>(_ values: [Value?]) -> Value? {
        let measured = values.compactMap { $0 }
        return measured.isEmpty ? nil : measured.reduce(.zero, +)
    }
}

/// Eine Zeile der obersten Ebene: eine App mit ihren Prozessen oder ein einzelner Prozess.
public struct ProcessGroupEntry: Hashable, Sendable, Identifiable {
    /// `nil` bei einem einzelnen Prozess (Hintergrund, System).
    public let app: RunningApp?
    /// Nie leer; bei Apps der App-Prozess zuerst, dann nach PID.
    public let processes: [ProcessMeasurement]
    /// Werte je Prozess, gleiche Reihenfolge wie `processes`.
    public let figures: [ProcessFigures]
    public let totals: ProcessFigures

    init(app: RunningApp?, processes: [ProcessMeasurement], figures: [ProcessFigures]) {
        precondition(!processes.isEmpty && processes.count == figures.count, "Eintrag ohne Prozesse")
        self.app = app
        self.processes = processes
        self.figures = figures
        totals = .sum(figures)
    }

    public var id: String { app.map { "app:\($0.pid)" } ?? "process:\(processes[0].key.id)" }

    public var name: String { app?.name ?? processes[0].name }
}

public struct ProcessGroup: Hashable, Sendable, Identifiable {
    public let kind: ProcessGroupKind
    public let entries: [ProcessGroupEntry]
    public let totals: ProcessFigures

    public var id: ProcessGroupKind { kind }

    /// Zahl der Prozesse aller Einträge.
    public var processCount: Int { entries.reduce(0) { $0 + $1.processes.count } }
}

/// Ordnet Prozesse den Gruppen des Prozess-Tabs zu (Spec §2, §3), rein und ohne Systemzugriff:
///
/// - **System:** Prozesse anderer Benutzer – auch wenn eine App sie gestartet hat.
/// - **Apps:** ein eigener Prozess gehört zu einer App, wenn er ihr App-Prozess ist, sein Programm im Bundle der App
///   liegt (Helfer, XPC-Dienste; bei verschachtelten Bundles das innerste) oder ein Vorfahr (Elternkette) dazugehört.
///   Pfade vergleicht der Grouper als Zeichenketten: `proc_pidpath` und `NSRunningApplication.bundleURL` liefern
///   aufgelöste Pfade, ein Dateizugriff je Prozess und Takt wäre zu teuer. System-XPC-Dienste außerhalb des Bundles
///   (etwa WebKit-Inhaltsprozesse) startet launchd – sie landen ohne private API unter „Hintergrund“.
/// - **Hintergrund:** alle übrigen eigenen Prozesse.
///
/// Leere Gruppen und Apps ohne gemessenen Prozess entfallen. Einträge sind nach Namen sortiert; die Oberfläche sortiert
/// selbst (`ProcessListPresenter`).
public enum ProcessGrouper {
    /// - Parameter network: Netzrate je Prozess, solange gemessen wird; ein Prozess ohne Eintrag hat dann 0 Byte/s.
    ///   `nil`: keine Messung – die Spalte bleibt leer.
    public static func group(_ processes: [ProcessMeasurement], apps: [RunningApp], currentUID: UInt32,
                             network: [ProcessKey: Double]? = nil) -> [ProcessGroup] {
        let entries = Entries(processes, apps: apps, currentUID: currentUID, network: network)
        return [
            group(.apps, entries.apps),
            group(.background, entries.background),
            group(.system, entries.system),
        ].compactMap { $0 }
    }

    /// Die Einträge der Gruppen „Apps“ und „Hintergrund“ wie in `group`, aber unsortiert und ohne „System“: für den
    /// App-Verlauf, der je Takt nur eigene Verbraucher summiert (#489) – Sortieren und die Einträge fremder Prozesse
    /// kosteten dort bei rund 1 400 Prozessen den größten Teil. `isIncluded` wählt die eigenen Prozesse, die Einträge
    /// bilden; die Zuordnung zur App folgt weiter der Elternkette über alle `processes`.
    public static func ownEntries(_ processes: [ProcessMeasurement], apps: [RunningApp], currentUID: UInt32,
                                  network: [ProcessKey: Double]? = nil,
                                  where isIncluded: (ProcessMeasurement) -> Bool = { _ in true }) -> [ProcessGroupEntry] {
        let entries = Entries(processes, apps: apps, currentUID: currentUID, network: network, includesSystem: false,
                              isIncluded: isIncluded)
        return entries.apps + entries.background
    }

    /// Die höchstens `count` Einträge mit der höchsten CPU-Last über alle Gruppen, höchste zuerst; bei gleicher Last
    /// nach Namen, dann nach Gruppe und Kennung. Dieselben Einträge wie aus `group`, aber ohne die Gruppen zu bilden:
    /// Einträge, Summen und die Sortierung nach Namen aller Prozesse kosteten in der Übersicht der Menüleiste je Takt
    /// mehr als alles andere an der Karte (#626). Einträge ohne gemessene Last entfallen.
    public static func entriesWithHighestCPULoad(_ processes: [ProcessMeasurement], apps: [RunningApp],
                                                 currentUID: UInt32, count: Int) -> [RankedProcessEntry] {
        guard count > 0 else { return [] }
        var owners = OwnerLookup(processes: processes, apps: apps)
        var members: [Int32: [ProcessMeasurement]] = [:]
        var ranking = LoadRanking(count: count)
        for process in processes {
            if process.uid != currentUID {
                ranking.offer(.process(process, .system), load: process.cpuLoad)
            } else if let app = owners.app(owning: process) {
                members[app.pid, default: []].append(process)
            } else {
                ranking.offer(.process(process, .background), load: process.cpuLoad)
            }
        }
        for app in apps {
            guard let processes = members[app.pid] else { continue }
            let ordered = Entries.ordered(processes, of: app)
            ranking.offer(.app(app, ordered), load: ProcessFigures.sum(ordered.map(\.cpuLoad)))
        }
        return ranking.candidates.map { candidate in
            let figures = { (process: ProcessMeasurement) in ProcessFigures(process, networkPerSecond: nil) }
            let entry = switch candidate.source {
            case .process(let process, _): ProcessGroupEntry(app: nil, processes: [process], figures: [figures(process)])
            case .app(let app, let processes): ProcessGroupEntry(app: app, processes: processes,
                                                                 figures: processes.map(figures))
            }
            return RankedProcessEntry(entry: entry, kind: candidate.source.kind, cpuLoad: candidate.load)
        }
    }

    private static func group(_ kind: ProcessGroupKind, _ entries: [ProcessGroupEntry]) -> ProcessGroup? {
        guard !entries.isEmpty else { return nil }
        let sorted = TableOrdering.sorted(entries, ascending: true, byText: true, number: { _ in nil }, text: \.name,
                                          id: \.id)
        return ProcessGroup(kind: kind, entries: sorted, totals: .sum(sorted.map(\.totals)))
    }
}

/// Eintrag aus `ProcessGrouper.entriesWithHighestCPULoad` samt Gruppe und Last (`entry.totals.cpuLoad`).
public struct RankedProcessEntry: Hashable, Sendable {
    public let entry: ProcessGroupEntry
    public let kind: ProcessGroupKind
    /// Anteil an allen Kernen (0…1).
    public let cpuLoad: Double
}

/// Die Anwärter mit der höchsten Last in Reihenfolge; hält nie mehr als `count` und baut keine Einträge.
private struct LoadRanking {
    enum Source {
        case process(ProcessMeasurement, ProcessGroupKind)
        /// App mit ihren Prozessen in der Reihenfolge des Eintrags.
        case app(RunningApp, [ProcessMeasurement])

        var kind: ProcessGroupKind {
            switch self {
            case .process(_, let kind): kind
            case .app: .apps
            }
        }

        var name: String {
            switch self {
            case .process(let process, _): process.name
            case .app(let app, _): app.name
            }
        }

        /// Wie `ProcessGroupEntry.id`.
        var id: String {
            switch self {
            case .process(let process, _): "process:\(process.key.id)"
            case .app(let app, _): "app:\(app.pid)"
            }
        }
    }

    let count: Int
    private(set) var candidates: [(source: Source, load: Double)] = []

    init(count: Int) {
        self.count = count
    }

    mutating func offer(_ source: @autoclosure () -> Source, load: Double?) {
        guard let load else { return }
        // Die meisten Prozesse liegen unter dem letzten Platz: ohne Namen und Kennung abweisen.
        if candidates.count == count, let last = candidates.last, load < last.load { return }
        let source = source()
        let rank = candidates.firstIndex { Self.precedes((source, load), $0) } ?? candidates.count
        guard rank < count else { return }
        candidates.insert((source, load), at: rank)
        if candidates.count > count { candidates.removeLast() }
    }

    /// Höhere Last zuerst, dann Name, Gruppe (Apps, Hintergrund, System) und Kennung – die Reihenfolge, in der die
    /// sortierten Gruppen aus `ProcessGrouper.group` die Einträge liefern.
    private static func precedes(_ lhs: (source: Source, load: Double), _ rhs: (source: Source, load: Double)) -> Bool {
        if lhs.load != rhs.load { return lhs.load > rhs.load }
        let names = (lhs.source.name, rhs.source.name)
        if names.0 != names.1 { return names.0 < names.1 }
        let kinds = (lhs.source.kind.order, rhs.source.kind.order)
        if kinds.0 != kinds.1 { return kinds.0 < kinds.1 }
        return lhs.source.id < rhs.source.id
    }
}

extension ProcessGroupKind {
    /// Platz der Gruppe im Prozess-Tab.
    fileprivate var order: Int {
        switch self {
        case .apps: 0
        case .background: 1
        case .system: 2
        }
    }
}

/// Einträge je Gruppe in der Reihenfolge der Eingabe; `group` sortiert sie.
private struct Entries {
    var apps: [ProcessGroupEntry] = []
    var background: [ProcessGroupEntry] = []
    var system: [ProcessGroupEntry] = []

    init(_ processes: [ProcessMeasurement], apps runningApps: [RunningApp], currentUID: UInt32,
         network: [ProcessKey: Double]?, includesSystem: Bool = true,
         isIncluded: (ProcessMeasurement) -> Bool = { _ in true }) {
        var owners = OwnerLookup(processes: processes, apps: runningApps)
        var members: [Int32: [ProcessMeasurement]] = [:]
        var background: [ProcessMeasurement] = []
        var system: [ProcessMeasurement] = []
        for process in processes {
            if process.uid != currentUID {
                if includesSystem { system.append(process) }
            } else if !isIncluded(process) {
                continue
            } else if let app = owners.app(owning: process) {
                members[app.pid, default: []].append(process)
            } else {
                background.append(process)
            }
        }
        let figures = { (process: ProcessMeasurement) in
            ProcessFigures(process, networkPerSecond: network.map { $0[process.key] ?? 0 })
        }
        apps = runningApps.compactMap { app -> ProcessGroupEntry? in
            guard let processes = members[app.pid] else { return nil }
            let ordered = Self.ordered(processes, of: app)
            return ProcessGroupEntry(app: app, processes: ordered, figures: ordered.map(figures))
        }
        let single = { (process: ProcessMeasurement) in
            ProcessGroupEntry(app: nil, processes: [process], figures: [figures(process)])
        }
        self.background = background.map(single)
        self.system = system.map(single)
    }

    /// Prozesse eines App-Eintrags: App-Prozess zuerst, dann nach PID.
    static func ordered(_ processes: [ProcessMeasurement], of app: RunningApp) -> [ProcessMeasurement] {
        let rank = { (process: ProcessMeasurement) in (process.key.pid == app.pid ? 0 : 1, process.key.pid) }
        return processes.sorted { rank($0) < rank($1) }
    }
}

/// Findet die App eines eigenen Prozesses und merkt sich das Ergebnis je PID – Geschwister teilen sich Vorfahren.
private struct OwnerLookup {
    private let processes: [ProcessMeasurement]
    /// Platz in `processes` je PID (bei doppelter PID der erste): ohne Kopie der Messung je Prozess und Takt.
    private let indicesByPID: [Int32: Int]
    private let appsByPID: [Int32: RunningApp]
    /// `bundlePath + "/"`, längster zuerst (innerstes Bundle gewinnt).
    private let bundles: [(prefix: String, app: RunningApp)]
    private var owners: [Int32: RunningApp?] = [:]

    init(processes: [ProcessMeasurement], apps: [RunningApp]) {
        self.processes = processes
        indicesByPID = Dictionary(processes.indices.map { (processes[$0].key.pid, $0) },
                                  uniquingKeysWith: { first, _ in first })
        appsByPID = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        bundles = apps.compactMap { app in app.bundlePath.map { (prefix: $0 + "/", app: app) } }
            .sorted { $0.prefix.count > $1.prefix.count }
    }

    mutating func app(owning process: ProcessMeasurement) -> RunningApp? {
        var chain: [Int32] = []
        var current: ProcessMeasurement? = process
        var owner: RunningApp?
        while let candidate = current {
            let pid = candidate.key.pid
            if let known = owners[pid] {
                owner = known
                break
            }
            // Schleife in der Elternkette (PID neu vergeben, während gemessen wurde).
            guard !chain.contains(pid) else { break }
            chain.append(pid)
            if let app = appsByPID[pid] ?? bundleApp(for: candidate.executablePath) {
                owner = app
                break
            }
            current = candidate.parentPID > 1 ? indicesByPID[candidate.parentPID].map { processes[$0] } : nil
        }
        for pid in chain { owners[pid] = owner }
        return owner
    }

    private func bundleApp(for path: String?) -> RunningApp? {
        guard let path else { return nil }
        return bundles.first { path.hasPrefix($0.prefix) }?.app
    }
}
