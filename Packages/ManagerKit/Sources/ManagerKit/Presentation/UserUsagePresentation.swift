import Foundation

/// Eine Zeile des Tabs „Benutzer“ (Spec 2026-11-06 §6, Stufe 4): ein angemeldeter Benutzer bzw. alle übrigen Konten
/// (root, Dienstkonten) mit der Summe ihrer Prozesse.
public struct UserUsageRow: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case user
        /// Alle Konten ohne Anmeldung zusammengefasst (root, `_windowserver` …).
        case otherAccounts
    }

    public let kind: Kind
    public let name: String
    public let sessions: [LoginSession]
    public let processCount: Int
    public let figures: ProcessFigures
    /// Der Benutzer, unter dem Grantry läuft.
    public let isCurrentUser: Bool
    /// Bei `otherAccounts` die Konten nach CPU, sonst leer.
    public let accounts: [String]

    public var id: String { kind == .user ? "user:\(name)" : "other" }

    /// Aufklappbar sind Benutzer mit Anmeldungen.
    public var isExpandable: Bool { kind == .user && !sessions.isEmpty }

    /// „Bildschirm · 2 Terminals · SSH von 10.0.0.7“ bzw. bei der Sammelzeile die Konten.
    public var summary: String {
        guard kind == .user else { return UserUsagePresenter.accountList(accounts) }
        let terminals = sessions.filter { $0.kind == .terminal }.count
        let hosts = Set(sessions.compactMap(\.host)).sorted()
        var parts: [String] = []
        if sessions.contains(where: { $0.kind == .graphical }) { parts.append(LoginSessionKind.graphical.title) }
        if terminals > 0 { parts.append(terminals == 1 ? "1 Terminal" : "\(terminals) Terminals") }
        if !hosts.isEmpty { parts.append("SSH von " + hosts.joined(separator: ", ")) }
        return parts.isEmpty ? "Keine Anmeldung erfasst" : parts.joined(separator: " · ")
    }
}

public struct UserUsagePresentation: Hashable, Sendable {
    private static let locale = Locale(identifier: "de_DE")

    public let rows: [UserUsageRow]
    /// Werte der Spaltenköpfe wie im Tab „Prozesse“.
    public let totals: ProcessFigures
    /// Bezug der Speicher-Heatmap.
    public let physicalMemory: UInt64

    public static let empty = UserUsagePresentation(rows: [], totals: .sum([]), physicalMemory: 1)

    public var userCount: Int { rows.filter { $0.kind == .user }.count }

    public var processCount: Int { rows.map(\.processCount).reduce(0, +) }

    /// Gesamtwert im Spaltenkopf; bei `.name` die Zahl der angemeldeten Benutzer.
    public func headerValue(_ column: ProcessColumn) -> String {
        column == .name ? (userCount == 1 ? "1 Benutzer" : "\(userCount) Benutzer") : column.text(totals)
    }

    public func heat(_ column: ProcessColumn, _ figures: ProcessFigures) -> Double? {
        column.heat(figures, physicalMemory: physicalMemory)
    }

    /// Anteil der Zeile an der CPU-Last aller Zeilen (0…1); `nil`, solange keine CPU gemessen ist.
    public func cpuShare(of row: UserUsageRow) -> Double? {
        let total = rows.compactMap(\.figures.cpuLoad).reduce(0, +)
        guard let load = row.figures.cpuLoad, total > 0 else { return nil }
        return load / total
    }

    /// „25 % der CPU-Last“; „–“ ohne Messung.
    public func cpuShareText(of row: UserUsageRow) -> String {
        cpuShare(of: row).map {
            $0.formatted(.percent.precision(.fractionLength(0)).locale(Self.locale)) + " der CPU-Last"
        } ?? "–"
    }
}

/// Baut die Zeilen des Tabs „Benutzer“: angemeldete Benutzer aus utmpx (`LoginSessions`) plus der Benutzer von Grantry,
/// jeweils mit der Summe ihrer Prozesse aus dem Task-Manager-Snapshot; alle übrigen Konten als eine Zeile. Rein; die
/// Oberfläche ruft es je Takt mit dem neuen Stand auf.
public enum UserUsagePresenter {
    public static func present(
        _ snapshot: TaskManagerSnapshot, sessions: [LoginSession], currentUID: UInt32, network: [ProcessKey: Double]?,
        userName: (UInt32) -> String, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> UserUsagePresentation {
        let names = Dictionary(uniqueKeysWithValues: Set(snapshot.processes.map(\.uid)).map { ($0, userName($0)) })
        let byName = Dictionary(grouping: snapshot.processes) { names[$0.uid] ?? String($0.uid) }
        let sessionsByUser = Dictionary(grouping: sessions, by: \.user)
        let currentName = userName(currentUID)
        let others = Set(sessions.map(\.user)).subtracting([currentName])
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        func figures(_ processes: [ProcessMeasurement]) -> ProcessFigures {
            .sum(processes.map { ProcessFigures($0, networkPerSecond: network?[$0.key]) })
        }
        var rows = ([currentName] + others).map { user in
            let processes = byName[user] ?? []
            return UserUsageRow(kind: .user, name: user, sessions: sessionsByUser[user] ?? [],
                                processCount: processes.count, figures: figures(processes),
                                isCurrentUser: user == currentName, accounts: [])
        }
        let loggedIn = Set(rows.map(\.name))
        // Nach CPU absteigend, bei Gleichstand nach Name; Summe in dieser Reihenfolge (stabil je Takt).
        let accounts = byName.filter { !loggedIn.contains($0.key) }
            .map { (name: $0.key, processes: $0.value, figures: figures($0.value)) }
            .sorted { ($0.figures.cpuLoad ?? 0, $1.name) > ($1.figures.cpuLoad ?? 0, $0.name) }
        if !accounts.isEmpty {
            rows.append(UserUsageRow(kind: .otherAccounts, name: "Andere Konten", sessions: [],
                                     processCount: accounts.map(\.processes.count).reduce(0, +),
                                     figures: .sum(accounts.map(\.figures)), isCurrentUser: false,
                                     accounts: accounts.map(\.name)))
        }
        return UserUsagePresentation(
            rows: rows, totals: ProcessListPresenter.totals(snapshot, measured: .sum(rows.map(\.figures))),
            physicalMemory: snapshot.memory?.physicalBytes ?? physicalMemory
        )
    }

    /// „root, _windowserver, _spotlight und 4 weitere“.
    static func accountList(_ accounts: [String]) -> String {
        let shown = accounts.prefix(3).joined(separator: ", ")
        return accounts.count > 3 ? "\(shown) und \(accounts.count - 3) weitere" : shown
    }
}
