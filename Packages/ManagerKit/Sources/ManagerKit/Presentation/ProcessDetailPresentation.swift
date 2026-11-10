import Foundation

/// Spalten des Tabs „Details“ (Spec 2026-11-06 §2): alle Prozesse flach. Den Pfad gibt es nur bei eigenen Prozessen,
/// Befehlszeilen nie.
public enum ProcessDetailColumn: String, Hashable, Sendable, CaseIterable, Identifiable {
    case name, pid, parentPID, user, cpu, cpuHistory, cpuTime, memory, threads, startTime, path

    private static let locale = Locale(identifier: "de_DE")

    public var id: Self { self }

    public var title: String {
        switch self {
        case .name: "Name"
        case .pid: "PID"
        case .parentPID: "Eltern-PID"
        case .user: "Benutzer"
        case .cpu: "CPU"
        case .cpuHistory: "CPU-Verlauf"
        case .cpuTime: "CPU-Zeit"
        case .memory: "Speicher"
        case .threads: "Threads"
        case .startTime: "Startzeit"
        case .path: "Pfad"
        }
    }

    /// „Name“ bleibt immer sichtbar.
    public var isHideable: Bool { self != .name }

    /// Der Verlauf hat keinen Sortierwert.
    public var isSortable: Bool { self != .cpuHistory }

    /// Zahlen stehen rechtsbündig.
    public var isNumeric: Bool {
        switch self {
        case .pid, .parentPID, .cpu, .cpuTime, .memory, .threads: true
        case .name, .user, .cpuHistory, .startTime, .path: false
        }
    }

    /// Erster Klick sortiert Texte, Kennungen und Startzeit aufsteigend, Messwerte absteigend.
    var startsAscending: Bool {
        switch self {
        case .name, .pid, .parentPID, .user, .startTime, .path: true
        case .cpu, .cpuHistory, .cpuTime, .memory, .threads: false
        }
    }

    /// Wert als Text; „–“, wenn nicht gemessen oder nicht lesbar (Spec §5). Für den Verlauf leer.
    public func text(_ row: ProcessDetailRow, timeZone: TimeZone = .current) -> String {
        let process = row.process
        return switch self {
        case .name: row.title
        case .pid: String(process.key.pid)
        case .parentPID: String(process.parentPID)
        case .user: row.userName
        case .cpu: process.cpuLoad.map(ProcessColumn.percent) ?? "–"
        case .cpuHistory: ""
        case .cpuTime: process.cpuTimeNanoseconds.map(Self.cpuTimeText) ?? "–"
        case .memory: process.memoryBytes.map(ProcessCleanupPresentation.memoryText) ?? "–"
        case .threads: process.threadCount.map { String($0) } ?? "–"
        case .startTime: Self.startText(row.startDate, timeZone: timeZone)
        case .path: row.path ?? "–"
        }
    }

    /// Sortierwert der Zahlenspalten; `nil` sortiert ans Ende.
    func number(_ row: ProcessDetailRow) -> Double? {
        let process = row.process
        return switch self {
        case .pid: Double(process.key.pid)
        case .parentPID: Double(process.parentPID)
        case .cpu: process.cpuLoad
        case .cpuTime: process.cpuTimeNanoseconds.map { Double($0) }
        case .memory: process.memoryBytes.map { Double($0) }
        case .threads: process.threadCount.map { Double($0) }
        case .startTime: Double(process.key.startTime)
        case .name, .user, .cpuHistory, .path: nil
        }
    }

    /// Text zum Sortieren; bei Zahlenspalten der Name für Gleichstände.
    func sortText(_ row: ProcessDetailRow) -> String? {
        switch self {
        case .user: row.userName
        case .path: row.path
        default: row.title
        }
    }

    var sortsByText: Bool { self == .name || self == .user || self == .path }

    /// CPU-Zeit wie im Windows-Task-Manager: „0:01:23“ (Stunden:Minuten:Sekunden).
    static func cpuTimeText(_ nanoseconds: UInt64) -> String {
        let seconds = nanoseconds / 1_000_000_000
        return String(format: "%llu:%02llu:%02llu", seconds / 3_600, seconds / 60 % 60, seconds % 60)
    }

    /// „06.11.2026, 14:03:12“.
    static func startText(_ date: Date, timeZone: TimeZone) -> String {
        date.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).day(.twoDigits).month(.twoDigits).year()
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }
}

/// Sichtbare Spalten des Tabs „Details“. Gespeichert werden die **ausgeblendeten** (`@AppStorage`, Text), damit Spalten
/// späterer Versionen von selbst erscheinen; unbekannte Namen im gespeicherten Text entfallen.
public struct ProcessDetailColumns: Hashable, Sendable, RawRepresentable {
    public static let `default` = ProcessDetailColumns(hidden: [.parentPID, .startTime])

    public private(set) var hidden: Set<ProcessDetailColumn>

    public init(hidden: Set<ProcessDetailColumn>) {
        self.hidden = hidden.filter(\.isHideable)
    }

    public init(rawValue: String) {
        self.init(hidden: Set(rawValue.split(separator: ",").compactMap { ProcessDetailColumn(rawValue: String($0)) }))
    }

    public var rawValue: String {
        ProcessDetailColumn.allCases.filter(hidden.contains).map(\.rawValue).joined(separator: ",")
    }

    /// In fester Reihenfolge.
    public var visible: [ProcessDetailColumn] { ProcessDetailColumn.allCases.filter { !hidden.contains($0) } }

    public func contains(_ column: ProcessDetailColumn) -> Bool { !hidden.contains(column) }

    /// Blendet ein bzw. aus; „Name“ bleibt.
    public mutating func toggle(_ column: ProcessDetailColumn) {
        guard column.isHideable else { return }
        if hidden.remove(column) == nil { hidden.insert(column) }
    }
}

/// Sortierung des Tabs „Details“; Standard nach CPU absteigend wie im Tab „Prozesse“.
public struct ProcessDetailSort: Hashable, Sendable {
    public var column: ProcessDetailColumn
    public var ascending: Bool

    public static let `default` = ProcessDetailSort(column: .cpu, ascending: false)

    public init(column: ProcessDetailColumn, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }

    /// Klick auf einen Spaltenkopf: dieselbe Spalte kehrt die Richtung um, eine neue beginnt mit ihrer Grundrichtung.
    public func selecting(_ column: ProcessDetailColumn) -> ProcessDetailSort {
        guard column.isSortable else { return self }
        return column == self.column ? ProcessDetailSort(column: column, ascending: !ascending)
            : ProcessDetailSort(column: column, ascending: column.startsAscending)
    }
}

/// Bedienzustand des Tabs „Details“: Suche und Sortierung (die Spaltenwahl liegt in `ProcessDetailColumns`).
public struct ProcessDetailOptions: Hashable, Sendable {
    public var query = ""
    public var sort = ProcessDetailSort.default

    public init() {}
}

/// Eine Zeile des Tabs „Details“: ein Prozess mit Benutzername.
public struct ProcessDetailRow: Hashable, Sendable, Identifiable {
    public let process: ProcessMeasurement
    public let userName: String
    /// Prozess des angemeldeten Benutzers – nur dann Pfad, „Im Finder zeigen“ und Beenden.
    public let isOwn: Bool

    public init(process: ProcessMeasurement, userName: String, isOwn: Bool) {
        self.process = process
        self.userName = userName
        self.isOwn = isOwn
    }

    public var id: String { process.key.id }

    public var title: String { ProcessListPresenter.title(process.name, pid: process.key.pid) }

    /// Programmpfad nur bei eigenen Prozessen (Spec §2, §5).
    public var path: String? {
        guard isOwn, let path = process.executablePath, !path.isEmpty else { return nil }
        return path
    }

    public var startDate: Date { Date(timeIntervalSince1970: TimeInterval(process.key.startTime) / 1_000_000) }

    /// Werte für die Heatmap (wie im Tab „Prozesse“).
    public var figures: ProcessFigures { ProcessFigures(process, networkPerSecond: nil) }

    /// „Beenden“ für diese Zeile; `nil` bei Prozessen anderer Benutzer: Die beendet der Tab „Prozesse“ über den Helper
    /// (TM9), jeweils einzeln mit Admin-Bestätigung.
    public var terminationCandidate: TaskTerminationCandidate? {
        isOwn ? TaskTerminationCandidate(name: title, keys: [process.key]) : nil
    }

    /// Warum „Beenden“ für diese Zeile gesperrt ist; `nil` bei eigenen Prozessen. Eine Zeile ist hier immer ein einzelner
    /// Prozess, der Hinweis „Zeile aufklappen“ (`TaskTerminationCandidate.foreignProcessNote`) passt nicht.
    public var terminationNote: String? {
        isOwn ? nil : TaskTerminationCandidate.foreignProcessInDetailsNote
    }
}

public struct ProcessDetailPresentation: Hashable, Sendable {
    public let rows: [ProcessDetailRow]
    /// Alle Prozesse des Takts, auch bei aktiver Suche.
    public let processCount: Int
    public let userCount: Int
    public let threads: ThreadTotal?
    /// CPU und Speicher systemweit wie die Spaltenköpfe im Tab „Prozesse“.
    public let totals: ProcessFigures
    /// Bezug der Speicher-Heatmap.
    public let physicalMemory: UInt64

    public static let empty = ProcessDetailPresentation(rows: [], processCount: 0, userCount: 0, threads: nil,
                                                        totals: .sum([]), physicalMemory: 1)

    /// Gesamtwert im Spaltenkopf; leer, wo eine Summe nichts aussagt.
    public func headerValue(_ column: ProcessDetailColumn) -> String {
        switch column {
        case .name: processCount == 1 ? "1 Prozess" : "\(processCount) Prozesse"
        case .user: "\(userCount) Benutzer"
        case .cpu: ProcessColumn.cpu.text(totals)
        case .cpuHistory: "60 s"
        case .memory: ProcessColumn.memory.text(totals)
        case .threads: threads?.text ?? "–"
        case .pid, .parentPID, .cpuTime, .startTime, .path: ""
        }
    }

    /// Heatmap-Intensität für CPU und Speicher (dieselbe Skala wie im Tab „Prozesse“), sonst `nil`.
    public func heat(_ column: ProcessDetailColumn, _ figures: ProcessFigures) -> Double? {
        Self.heat(column, figures, physicalMemory: physicalMemory)
    }

    /// Wie `heat(_:_:)` mit eigenem Bezug: für Zeilen, die nur ihn statt der ganzen Darstellung bekommen.
    public static func heat(_ column: ProcessDetailColumn, _ figures: ProcessFigures,
                            physicalMemory: UInt64) -> Double? {
        switch column {
        case .cpu, .cpuHistory: ProcessColumn.cpu.heat(figures, physicalMemory: physicalMemory)
        case .memory: ProcessColumn.memory.heat(figures, physicalMemory: physicalMemory)
        default: nil
        }
    }
}

/// Baut die Zeilen des Tabs „Details“ (Spec §2): Suche nach Name, PID oder Benutzer, Sortierung je Spalte – ungemessene
/// Werte stehen in beiden Richtungen am Ende. Rein; die Oberfläche ruft es je Takt mit dem neuen Stand auf.
public enum ProcessDetailPresenter {
    public static func present(
        _ snapshot: TaskManagerSnapshot, currentUID: UInt32, options: ProcessDetailOptions,
        userName: (UInt32) -> String, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> ProcessDetailPresentation {
        let names = Dictionary(uniqueKeysWithValues: Set(snapshot.processes.map(\.uid)).map { ($0, userName($0)) })
        let all = snapshot.processes.map {
            ProcessDetailRow(process: $0, userName: names[$0.uid] ?? String($0.uid), isOwn: $0.uid == currentUID)
        }
        let query = options.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty ? all : all.filter {
            ProcessListPresenter.matches($0.process, query) || $0.userName.localizedCaseInsensitiveContains(query)
        }
        let column = options.sort.column
        let rows = TableOrdering.sorted(matching, ascending: options.sort.ascending, byText: column.sortsByText,
                                        number: column.number, text: column.sortText, id: \.id)
        return ProcessDetailPresentation(
            rows: rows, processCount: snapshot.processes.count, userCount: names.count,
            threads: ThreadTotal(snapshot.processes),
            totals: ProcessListPresenter.totals(snapshot, measured: .sum(all.map(\.figures))),
            physicalMemory: snapshot.memory?.physicalBytes ?? physicalMemory
        )
    }
}
