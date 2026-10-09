import Foundation

/// Filter der Netzwerkaktivität (Spec §4): standardmäßig nur aktive Prozesse und ohne Apple-Systemdienste.
public struct NetworkActivityFilter: Hashable, Sendable {
    /// Nur Prozesse mit Rate > 0, ihre Verbindungen nur mit Rate > 0 oder als neu markiert; eben beendete Prozesse und
    /// geschlossene Verbindungen bleiben für ihre 10 s ausgegraut sichtbar.
    public var onlyActive = true
    /// Dienste von macOS ausblenden (`NetworkProgram.isAppleService`, ohne Pfad nur `kernel_task`).
    public var hidesAppleServices = true
    /// Nur Interpreter (node, python …).
    public var onlyInterpreters = false

    public init() {}

    public var isActive: Bool { self != NetworkActivityFilter() }
}

/// Eine Zeile der Aktivitätstabelle: ein Prozess mit seinen Verbindungen (`children`) oder eine Verbindung.
public struct NetworkActivityRow: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case process(pid: Int32, program: NetworkProgram?)
        case connection(ConnectionTraffic, hostName: String?)
    }

    public let id: String
    public let kind: Kind
    /// App- bzw. Prozessname; bei Verbindungen das Ziel (Hostname mit IP, sonst IP).
    public let title: String
    /// „3 Verbindungen“ bzw. „Port 443 · TCP · Established“.
    public let detail: String
    public let downloadRate: Double
    public let uploadRate: Double
    /// Übertragen seit Öffnen der Ansicht.
    public let totalBytes: UInt64
    /// Offene Verbindungen des Prozesses (ohne lauschende Sockets); bei Verbindungen 0.
    public let connectionCount: Int
    public let isNew: Bool
    public let isGone: Bool
    /// Signatur des Programms; `nil` bei Verbindungen, ohne Programm und solange die Prüfung noch läuft.
    public let signing: SigningInfo?
    /// Verbindungen eines Prozesses; `nil` bei Verbindungen und bei Prozessen ohne sichtbare Verbindung.
    public let children: [NetworkActivityRow]?
    let searchTerms: [String]

    public var totalRate: Double { downloadRate + uploadRate }

    /// Kurzform von `detail` für schmale Spalten: Anzahl der Verbindungen bzw. „443 · TCP“.
    public var compactDetail: String {
        switch kind {
        case .process:
            "\(connectionCount)"
        case .connection(let connection, _):
            [connection.remote.port.map(String.init), connection.transport.displayName].compactMap(\.self)
                .joined(separator: " · ")
        }
    }

    public var program: NetworkProgram? {
        if case .process(_, let program) = kind { program } else { nil }
    }

    public var executablePath: String? { program?.executablePath }

    /// Ziel zum Kopieren: „api.example.com:443“ bzw. „[2001:db8::1]:443“; nur bei Verbindungen mit Gegenstelle.
    public var target: String? {
        guard case .connection(let connection, let hostName) = kind else { return nil }
        return connection.target(hostName: hostName)
    }

    /// „Safari, empfängt 1,2 KB/s, sendet 300 B/s, 3 Verbindungen“, ggf. „neu“/„beendet“.
    public var accessibilityLabel: String {
        var parts = [title]
        if case .connection = kind { parts.append(detail) }
        parts += ["empfängt \(TrafficFormat.rate(downloadRate))", "sendet \(TrafficFormat.rate(uploadRate))"]
        if case .process = kind { parts.append(detail) }
        if isNew { parts.append("neu") }
        if isGone { parts.append(kind.isProcess ? "beendet" : "geschlossen") }
        return parts.joined(separator: ", ")
    }

    func replacingChildren(_ children: [NetworkActivityRow]?) -> NetworkActivityRow {
        NetworkActivityRow(id: id, kind: kind, title: title, detail: detail, downloadRate: downloadRate,
                           uploadRate: uploadRate, totalBytes: totalBytes, connectionCount: connectionCount, isNew: isNew,
                           isGone: isGone, signing: signing, children: children, searchTerms: searchTerms)
    }

    func matches(_ query: String) -> Bool {
        searchTerms.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

extension ConnectionTraffic {
    /// Gegenstelle mit stets sichtbarer Adresse; ein DNS-Name ergänzt die IP, ersetzt sie aber nie.
    func remoteTitle(hostName: String?) -> String {
        guard let address = remote.address else { return "Ohne Gegenstelle" }
        return hostName.map { "\($0) (\(address))" } ?? address
    }

    /// Ziel zum Kopieren: „api.example.com:443“ bzw. „[2001:db8::1]:443“; `nil` ohne Gegenstelle.
    public func target(hostName: String?) -> String? {
        guard remote.address != nil else { return nil }
        guard let hostName else { return remote.description }
        return remote.port.map { "\(hostName):\($0)" } ?? hostName
    }
}

extension NetworkActivityRow.Kind {
    var isProcess: Bool {
        if case .process = self { true } else { false }
    }
}

/// Zeilen der Netzwerkaktivität: Filter, Suche (Name, Pfad, Ziel, Port) und Sortierung.
public enum NetworkActivityPresenter {
    /// Standard: nach Gesamtrate (↓ + ↑), höchste zuerst.
    public static var defaultSortOrder: [KeyPathComparator<NetworkActivityRow>] {
        [KeyPathComparator(\NetworkActivityRow.totalRate, order: .reverse)]
    }

    public static func rows(
        frame: ActivityFrame, hostNames: [String: String], filter: NetworkActivityFilter, query: String,
        sortOrder: [KeyPathComparator<NetworkActivityRow>]
    ) -> [NetworkActivityRow] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let processRows = frame.report.processes.compactMap { process -> NetworkActivityRow? in
            let program = frame.programs[process.key]
            guard !filter.onlyActive || process.rate.total > 0 || process.isGone,
                  matches(process, program: program, filter: filter) else { return nil }
            let connections = process.connections
                .filter { !filter.onlyActive || $0.rate.total > 0 || $0.isNew || $0.isGone }
                .map { connectionRow($0, of: process, hostNames: hostNames) }
                .sorted(by: busiestFirst)
            let signing = frame.pendingSignatures.contains(process.key) ? nil : program?.signing
            return searched(processRow(process, program: program, signing: signing, connections: connections),
                            query: query)
        }
        return processRows.sorted(by: ordered(sortOrder))
    }

    /// Zeile mit `id`, auch unter den Verbindungen.
    public static func row(withID id: NetworkActivityRow.ID, in rows: [NetworkActivityRow]) -> NetworkActivityRow? {
        for row in rows {
            if row.id == id { return row }
            if let child = row.children?.first(where: { $0.id == id }) { return child }
        }
        return nil
    }

    /// Lauscher desselben Programms („Zum Netzwerkdienst“); nur für Prozesszeilen.
    public static func listener(for row: NetworkActivityRow, in listeners: [NetworkListener]) -> NetworkListener? {
        guard let path = row.executablePath else { return nil }
        return listeners.filter { $0.executablePath == path }.min { $0.id < $1.id }
    }

    private static func matches(_ process: ProcessActivity, program: NetworkProgram?, filter: NetworkActivityFilter) -> Bool {
        let isApple = program?.isAppleService ?? (process.key.pid == 0)
        return (!filter.hidesAppleServices || !isApple) && (!filter.onlyInterpreters || program?.isInterpreter == true)
    }

    /// Ohne Suchtext alles; sonst der Prozess, wenn er passt, oder nur seine passenden Verbindungen.
    private static func searched(_ row: NetworkActivityRow, query: String) -> NetworkActivityRow? {
        guard !query.isEmpty, !row.matches(query) else { return row }
        let children = row.children?.filter { $0.matches(query) } ?? []
        return children.isEmpty ? nil : row.replacingChildren(children)
    }

    private static func processRow(_ process: ProcessActivity, program: NetworkProgram?, signing: SigningInfo?,
                                   connections: [NetworkActivityRow]) -> NetworkActivityRow {
        let count = process.connections.count { !$0.isGone }
        let detail = switch count {
        case 0: "Keine Verbindung"
        case 1: "1 Verbindung"
        default: "\(count) Verbindungen"
        }
        return NetworkActivityRow(
            id: "p:\(process.key.id)", kind: .process(pid: process.key.pid, program: program),
            title: program?.title ?? process.shortName, detail: detail, downloadRate: process.rate.download,
            uploadRate: process.rate.upload, totalBytes: process.transferred.total, connectionCount: count,
            isNew: false, isGone: process.isGone, signing: signing, children: connections.isEmpty ? nil : connections,
            searchTerms: [program?.title, process.shortName, program?.executablePath]
                .compactMap(\.self)
        )
    }

    private static func connectionRow(_ activity: ConnectionActivity, of process: ProcessActivity,
                                      hostNames: [String: String]) -> NetworkActivityRow {
        let connection = activity.connection
        let hostName = connection.remote.address.flatMap { hostNames[$0] }
        let port = connection.remote.port.map { "Port \($0)" }
        let state = connection.state.isEmpty ? nil : connection.state
        return NetworkActivityRow(
            id: "p:\(process.key.id)|\(activity.key.id)", kind: .connection(connection, hostName: hostName),
            title: connection.remoteTitle(hostName: hostName),
            detail: [port, connection.transport.displayName, state].compactMap(\.self).joined(separator: " · "),
            downloadRate: activity.rate.download, uploadRate: activity.rate.upload,
            totalBytes: activity.transferred.total, connectionCount: 0, isNew: activity.isNew, isGone: activity.isGone,
            signing: nil, children: nil,
            searchTerms: [hostName, connection.remote.address, connection.remote.port.map(String.init)].compactMap(\.self)
        )
    }

    /// Verbindungen: höchste Gesamtrate zuerst, sonst nach `id`.
    private static func busiestFirst(_ lhs: NetworkActivityRow, _ rhs: NetworkActivityRow) -> Bool {
        lhs.totalRate != rhs.totalRate ? lhs.totalRate > rhs.totalRate : lhs.id < rhs.id
    }

    /// Reihenfolge nach `sortOrder`, bei Gleichstand stabil nach `id`.
    private static func ordered(_ sortOrder: [KeyPathComparator<NetworkActivityRow>])
        -> (NetworkActivityRow, NetworkActivityRow) -> Bool {
        { lhs, rhs in
            for comparator in sortOrder {
                switch comparator.compare(lhs, rhs) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: continue
                }
            }
            return lhs.id < rhs.id
        }
    }
}
