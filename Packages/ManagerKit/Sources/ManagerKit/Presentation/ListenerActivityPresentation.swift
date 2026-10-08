import Foundation

/// Richtung einer Verbindung aus Sicht des Programms.
public enum ConnectionDirection: Hashable, Sendable {
    /// Ein Client hat sich mit einem lauschenden TCP-Port des Programms verbunden.
    case inbound
    /// Das Programm hat die TCP-Verbindung selbst aufgebaut.
    case outbound

    /// „Eingehend“, „Ausgehend“.
    public var displayName: String {
        switch self {
        case .inbound: "Eingehend"
        case .outbound: "Ausgehend"
        }
    }
}

/// Netzwerkaktivität eines Lauschers im Detail des Bereichs „Dienste“: alle gemessenen Prozesse seines Programms
/// (gleicher Pfad, `NetworkActivityPresenter.listener(for:in:)` ordnet umgekehrt genauso zu) mit Summen, Verlauf und
/// sämtlichen Verbindungen – ohne die Filter der Ansicht „Aktivität“.
///
/// Grenze: nettop nennt keinen Benutzer; laufen mehrere Benutzer dasselbe Programm, zählen ihre Prozesse zusammen.
public struct ListenerActivity: Hashable, Sendable {
    /// Ein Prozess des Programms.
    public struct Process: Hashable, Sendable, Identifiable {
        public let key: ProcessKey
        /// nettops Kurzname.
        public let shortName: String
        public let rate: TrafficRate
        public let transferred: ByteTotals
        /// Offene Verbindungen (ohne lauschende Sockets).
        public let connectionCount: Int
        public let isGone: Bool

        public var id: ProcessKey { key }
        public var pid: Int32 { key.pid }
    }

    /// Eine Verbindung eines Prozesses des Programms.
    public struct Connection: Hashable, Sendable, Identifiable {
        public let id: String
        public let pid: Int32
        public let connection: ConnectionTraffic
        public let hostName: String?
        /// `nil` bei UDP und QUIC: ohne Verbindungsaufbau lässt sich die Richtung nicht ablesen.
        public let direction: ConnectionDirection?
        /// `nil` ohne bekannte Gegenstelle.
        public let location: IPAddressScope.Location?
        public let rate: TrafficRate
        public let transferred: ByteTotals
        public let isNew: Bool
        public let isGone: Bool

        /// Hostname, sonst IP, sonst „Ohne Gegenstelle“.
        public var title: String { hostName ?? connection.remote.address ?? "Ohne Gegenstelle" }

        /// „192.0.2.10:443“ bzw. „[2001:db8::1]:443“.
        public var remoteEndpoint: String { connection.remote.description }

        /// „192.0.2.1:50000“.
        public var localEndpoint: String { connection.local.description }

        /// „TCP · IPv4“.
        public var protocolText: String { "\(connection.transport.displayName) · IPv\(connection.ipVersion.rawValue)" }

        /// TCP-Zustand (`Established`, `SynSent` …), `nil` bei UDP/QUIC.
        public var state: String? { connection.state.isEmpty ? nil : connection.state }

        /// Ziel zum Kopieren wie in der Aktivitätstabelle; nur mit Gegenstelle.
        public var target: String? { connection.target(hostName: hostName) }

        /// „api.example.com, ausgehend, Port 443, TCP, empfängt 1,2 KB/s, sendet 300 B/s“, ggf. „neu“/„geschlossen“.
        public var accessibilityLabel: String {
            var parts = [title]
            if let direction { parts.append(direction.displayName.lowercased()) }
            if let port = connection.remote.port { parts.append("Port \(port)") }
            parts.append(connection.transport.displayName)
            if let state { parts.append(state) }
            parts += ["empfängt \(TrafficFormat.rate(rate.download))", "sendet \(TrafficFormat.rate(rate.upload))"]
            if isNew { parts.append("neu") }
            if isGone { parts.append("geschlossen") }
            return parts.joined(separator: ", ")
        }
    }

    /// Nach PID sortiert.
    public let processes: [Process]
    /// Offene zuerst nach Gesamtrate, geschlossene am Ende.
    public let connections: [Connection]
    /// Summe der Raten aller Prozesse des Programms.
    public let rate: TrafficRate
    /// Übertragen seit Beginn der Messung.
    public let transferred: ByteTotals
    /// Summe der Prozessverläufe, rechtsbündig (jüngste Messung zuletzt), höchstens `TrafficTracker.historyLength`.
    public let history: [TrafficRate]

    public static let empty = ListenerActivity(processes: [], connections: [], rate: .zero, transferred: .zero,
                                               history: [])

    /// nettop meldet gerade keinen (auch keinen eben beendeten) Prozess des Programms.
    public var isEmpty: Bool { processes.isEmpty }

    /// Offene Verbindungen.
    public var openConnections: [Connection] { connections.filter { !$0.isGone } }

    public func openConnectionCount(_ direction: ConnectionDirection) -> Int {
        openConnections.count { $0.direction == direction }
    }

    /// Verschiedene Gegenstellen offener Verbindungen (nach Adresse).
    public var remoteHostCount: Int { Set(openConnections.compactMap(\.connection.remote.address)).count }
}

public enum ListenerActivityPresenter {
    /// Aktivität aller Prozesse, deren Programm `executablePath` hat.
    public static func activity(forProgramAt executablePath: String, frame: ActivityFrame,
                                hostNames: [String: String]) -> ListenerActivity {
        let processes = frame.report.processes.filter { frame.programs[$0.key]?.executablePath == executablePath }
        guard !processes.isEmpty else { return .empty }
        let listeningPorts = processes.reduce(into: Set<UInt16>()) { $0.formUnion($1.listeningTCPPorts) }
        let connections = processes.flatMap { process in
            process.connections.map { connection(of: process, $0, listeningPorts: listeningPorts, hostNames: hostNames) }
        }
        return ListenerActivity(
            processes: processes.map(summary).sorted { $0.key < $1.key },
            connections: connections.sorted(by: openAndBusiestFirst),
            rate: processes.reduce(.zero) { $0 + $1.rate },
            transferred: processes.reduce(.zero) {
                ByteTotals(received: $0.received + $1.transferred.received, sent: $0.sent + $1.transferred.sent)
            },
            history: summedRightAligned(processes.map(\.history))
        )
    }

    private static func summary(_ process: ProcessActivity) -> ListenerActivity.Process {
        ListenerActivity.Process(key: process.key, shortName: process.shortName, rate: process.rate,
                                 transferred: process.transferred,
                                 connectionCount: process.connections.count { !$0.isGone }, isGone: process.isGone)
    }

    /// TCP auf einem lauschenden Port des Programms ist eingehend, sonst ausgehend; UDP/QUIC ohne Richtung.
    private static func connection(of process: ProcessActivity, _ activity: ConnectionActivity,
                                   listeningPorts: Set<UInt16>, hostNames: [String: String])
        -> ListenerActivity.Connection {
        let connection = activity.connection
        let direction: ConnectionDirection? = if connection.transport == .tcp {
            connection.local.port.map(listeningPorts.contains) == true ? .inbound : .outbound
        } else {
            nil
        }
        return ListenerActivity.Connection(
            id: "\(process.key.id)|\(activity.key.id)", pid: process.key.pid, connection: connection,
            hostName: connection.remote.address.flatMap { hostNames[$0] }, direction: direction,
            location: connection.remote.address.map(IPAddressScope.location(of:)), rate: activity.rate,
            transferred: activity.transferred, isNew: activity.isNew, isGone: activity.isGone
        )
    }

    private static func openAndBusiestFirst(_ lhs: ListenerActivity.Connection,
                                            _ rhs: ListenerActivity.Connection) -> Bool {
        if lhs.isGone != rhs.isGone { return !lhs.isGone }
        if lhs.rate.total != rhs.rate.total { return lhs.rate.total > rhs.rate.total }
        return lhs.id < rhs.id
    }

    /// Verläufe gleicher Taktung addiert, an der jüngsten Messung ausgerichtet.
    static func summedRightAligned(_ histories: [[TrafficRate]]) -> [TrafficRate] {
        let length = histories.map(\.count).max() ?? 0
        return (0..<length).map { index in
            histories.reduce(.zero) { sum, history in
                let offset = index - (length - history.count)
                return offset >= 0 ? sum + history[offset] : sum
            }
        }
    }
}
