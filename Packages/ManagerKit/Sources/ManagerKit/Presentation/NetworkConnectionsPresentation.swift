import Foundation

/// Art eines Sockets in der Ansicht „Verbindungen“.
public enum SocketKind: Int, Hashable, Sendable, Comparable {
    /// TCP im Zustand `Listen`.
    case listening
    /// UDP bzw. QUIC mit lokalem Port, ohne Gegenstelle.
    case bound
    /// Mit Gegenstelle (TCP in jedem anderen Zustand, verbundenes UDP/QUIC).
    case connected

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Wohin ein Socket reicht: die Gegenstelle einer Verbindung bzw. die Schnittstellen eines lauschenden oder gebundenen
/// Sockets. Nur aus den numerischen Adressen abgeleitet, ohne DNS.
public enum SocketExposure: Hashable, Sendable {
    /// Nur Loopback.
    case thisMac
    /// Private, Link-lokale oder ULA-Adresse der Gegenstelle bzw. eine einzelne lokale Adresse.
    case localNetwork
    /// Öffentliche Adresse der Gegenstelle.
    case internet
    /// Lauschend oder gebunden auf allen Schnittstellen (`*`, `0.0.0.0`, `::`).
    case allInterfaces

    public var title: String {
        switch self {
        case .thisMac: String(localized: "Nur dieser Mac")
        case .localNetwork: String(localized: "Lokales Netz")
        case .internet: String(localized: "Internet")
        case .allInterfaces: String(localized: "Alle Schnittstellen")
        }
    }
}

/// Segment der Filterleiste.
public enum NetworkConnectionFilter: String, Hashable, Sendable, CaseIterable, Identifiable {
    case all, connected, listening, exposed, udp, loopback

    public var id: Self { self }

    public var title: String {
        switch self {
        case .all: String(localized: "Alle")
        case .connected: String(localized: "Verbunden")
        case .listening: String(localized: "Lauscht")
        case .exposed: String(localized: "Erreichbar")
        case .udp: String(localized: "UDP")
        case .loopback: String(localized: "Nur dieser Mac")
        }
    }

    func includes(_ row: NetworkSocketRow) -> Bool {
        switch self {
        case .all: true
        case .connected: row.kind == .connected
        case .listening: row.kind == .listening
        case .exposed: row.isExposed
        case .udp: row.socket.transport != .tcp
        case .loopback: row.isLoopback
        }
    }
}

/// Gruppe der Ansicht „Verbindungen“ nach Erreichbarkeit (Gestaltung „Lagebild“): wer einen lauschenden oder gebundenen
/// Socket erreichen kann, dazu die Verbindungen.
public enum SocketReach: Int, CaseIterable, Hashable, Sendable {
    case network, localNetwork, thisMac, connected

    public var title: String {
        switch self {
        case .network: String(localized: "Aus dem Netz erreichbar")
        case .localNetwork: String(localized: "Im lokalen Netz erreichbar")
        case .thisMac: String(localized: "Nur von diesem Mac erreichbar")
        case .connected: String(localized: "Verbindungen")
        }
    }

    public var tone: PresentationTone {
        switch self {
        case .network: .warning
        case .localNetwork, .connected: .neutral
        case .thisMac: .positive
        }
    }
}

/// Ein offener Socket eines Prozesses laut nettop.
public struct NetworkSocketRow: Identifiable, Hashable, Sendable {
    public let id: String
    public let process: ProcessKey
    /// App- bzw. Prozessname (`NetworkProgram.title`, sonst nettops Kurzname).
    public let title: String
    public let program: NetworkProgram?
    /// Benutzer laut Prozesstabelle und sein Kurzname; `nil`, wenn unbekannt.
    public let uid: UInt32?
    public let user: String?
    public let socket: ConnectionTraffic
    public let kind: SocketKind
    public let rate: TrafficRate
    /// Übertragen seit Beginn der Messung; bei lauschenden Sockets 0.
    public let transferred: ByteTotals
    public let isNew: Bool
    /// Geschlossen; bleibt 10 s ausgegraut stehen und zählt nicht mit.
    public let isGone: Bool

    public var pid: Int32 { process.pid }

    /// „LISTEN“, „ESTABLISHED“, „TIME_WAIT“ (TCP-Zustand nach RFC 793), „BOUND“ bzw. „CONNECTED“ (UDP/QUIC).
    public var stateText: String {
        guard socket.transport == .tcp, !socket.state.isEmpty else { return kind == .bound ? "BOUND" : "CONNECTED" }
        return Self.tcpStateNames[socket.state] ?? socket.state.uppercased()
    }

    /// „TCP“, „UDP“, „QUIC“.
    public var protocolText: String { socket.transport.displayName }
    /// „IPv4“, „IPv6“.
    public var ipVersionText: String { "IPv\(socket.ipVersion.rawValue)" }
    /// „*:7000“, „[::1]:8021“, „192.168.1.24:52206“.
    public var localText: String { socket.local.description }
    /// Gegenstelle; „–“ ohne.
    public var remoteText: String { socket.remote.address == nil ? "–" : socket.remote.description }

    /// Bekannter Dienst des Ports der Gegenstelle bzw. des eigenen Ports bei lauschenden und gebundenen Sockets.
    public var service: String? {
        let port = kind == .connected ? socket.remote.port : socket.local.port
        return port.flatMap { WellKnownPort.name(of: $0, transport: socket.transport) }
    }

    public var exposure: SocketExposure {
        if kind == .connected {
            return socket.remote.address.map(AddressScope.init(address:))?.exposure ?? .thisMac
        }
        guard let address = socket.local.address else { return .allInterfaces }
        switch ListenerReachability(addresses: [address]) {
        case .thisMac: return .thisMac
        case .network(let all): return all ? .allInterfaces : .localNetwork
        }
    }

    /// Lauschend oder gebunden auf allen Schnittstellen oder einer Nicht-Loopback-Adresse.
    public var isExposed: Bool { kind != .connected && exposure != .thisMac }

    /// Gruppe nach Erreichbarkeit: lauschende und gebundene Sockets nach ihrer Adresse, Verbindungen für sich.
    public var reach: SocketReach {
        guard kind != .connected else { return .connected }
        switch exposure {
        case .allInterfaces, .internet: return .network
        case .localNetwork: return .localNetwork
        case .thisMac: return .thisMac
        }
    }

    /// Nur über Loopback (beide Seiten bzw. die lokale Adresse).
    public var isLoopback: Bool {
        guard let local = socket.local.address, AddressScope(address: local) == .loopback else { return false }
        return socket.remote.address.map { AddressScope(address: $0) == .loopback } ?? true
    }

    /// „Safari, PID 4820, TCP IPv6, ESTABLISHED, lokal …, entfernt …“.
    public var accessibilityLabel: String {
        var parts = [title, "PID \(pid)", "\(protocolText) \(ipVersionText)", stateText, "lokal \(localText)"]
        if socket.remote.address != nil { parts.append("entfernt \(remoteText)") }
        if isGone { parts.append("geschlossen") }
        return parts.joined(separator: ", ")
    }

    private static let tcpStateNames = [
        "Listen": "LISTEN", "Established": "ESTABLISHED", "SynSent": "SYN_SENT", "SynReceived": "SYN_RECEIVED",
        "FinWait1": "FIN_WAIT_1", "FinWait2": "FIN_WAIT_2", "CloseWait": "CLOSE_WAIT", "Closing": "CLOSING",
        "LastAck": "LAST_ACK", "TimeWait": "TIME_WAIT", "Closed": "CLOSED",
    ]
}

/// Kennzahlen der Kachelreihe; ohne geschlossene Sockets.
public struct NetworkConnectionCounts: Hashable, Sendable {
    /// Offene Sockets.
    public let sockets: Int
    /// Verschiedene lauschende TCP-Ports.
    public let listeningPorts: Int
    /// Lauschende oder gebundene Sockets auf allen Schnittstellen oder einer Nicht-Loopback-Adresse.
    public let exposed: Int
    /// Prozesse mit mindestens einem offenen Socket.
    public let processes: Int

    public static let zero = NetworkConnectionCounts(sockets: 0, listeningPorts: 0, exposed: 0, processes: 0)
}

/// Stand der Ansicht „Verbindungen“: alle offenen Sockets der letzten nettop-Messung, gefiltert und durchsucht.
public struct NetworkConnectionsPresentation: Hashable, Sendable {
    /// Alle Sockets, auch die eben geschlossenen.
    public let all: [NetworkSocketRow]
    /// Sichtbare Zeilen nach Filter und Suche.
    public let rows: [NetworkSocketRow]
    public let counts: NetworkConnectionCounts

    public static let empty = NetworkConnectionsPresentation(frame: .empty, filter: .all, query: "")

    /// Offene Sockets unter `rows` – für „x von `counts.sockets` angezeigt“. Geschlossene Zeilen bleiben sichtbar,
    /// zählen aber wie in Kachel und Statusleiste nicht (Bewertung 2026.11.7-1188, Mangel 15).
    public var shownCount: Int { rows.count { !$0.isGone } }

    /// Urteil für die Zustandszeile: wie weit der Mac über offene Sockets erreichbar ist; aus dem Netz erreichbare Sockets
    /// sind ein Befund.
    public func verdict(firewallOn: Bool?) -> SystemVerdict {
        let open = all.filter { !$0.isGone }
        let network = open.count { $0.reach == .network }
        let local = open.count { $0.reach == .localNetwork }
        let title = switch (network, local) {
        case (1, _): String(localized: "1 Socket aus dem Netz erreichbar")
        case (0, 0): String(localized: "Nur von diesem Mac erreichbar")
        case (0, _): String(localized: "Im lokalen Netz erreichbar")
        default: String(localized: "\(network) Sockets aus dem Netz erreichbar")
        }
        var items: [SystemVerdict.Item] = []
        switch firewallOn {
        case true?: items.append(SystemVerdict.Item(text: String(localized: "Firewall an"), tone: .positive))
        case false?: items.append(SystemVerdict.Item(text: String(localized: "Firewall aus"), tone: .warning))
        case nil: break
        }
        let facts = String(localized: "\(counts.sockets) Sockets · \(counts.processes) Programme · live über nettop")
        return SystemVerdict(level: network > 0 || firewallOn == false ? .finding : .calm, title: title, reason: "",
                             items: items, processFindings: [], facts: facts)
    }

    /// Anzahl der offenen Sockets je Segment (für Barrierefreiheit und Tooltips).
    public func count(for filter: NetworkConnectionFilter) -> Int {
        all.count { !$0.isGone && filter.includes($0) }
    }

    /// - Parameters:
    ///   - query: Teil des Prozessnamens oder eine Portnummer.
    ///   - userName: Kurzname zur UID des Prozesses.
    public init(frame: ActivityFrame, filter: NetworkConnectionFilter, query: String,
                userName: (UInt32) -> String = UserNameCache.shared.name(for:)) {
        all = Self.rows(frame: frame, userName: userName)
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        rows = all.filter { filter.includes($0) && (query.isEmpty || $0.matches(query)) }
        let open = all.filter { !$0.isGone }
        counts = NetworkConnectionCounts(
            sockets: open.count,
            listeningPorts: Set(open.filter { $0.kind == .listening }.compactMap(\.socket.local.port)).count,
            exposed: open.count(where: \.isExposed),
            processes: Set(open.map(\.process)).count
        )
    }

    /// Zeile mit `id` unter allen Sockets, unabhängig von Filter und Suche.
    public func row(withID id: NetworkSocketRow.ID?) -> NetworkSocketRow? {
        id.flatMap { id in all.first { $0.id == id } }
    }

    /// Lauschende zuerst, dann gebundene, dann Verbindungen; darin nach Name, PID und lokalem Endpunkt.
    static func rows(frame: ActivityFrame, userName: (UInt32) -> String) -> [NetworkSocketRow] {
        frame.report.processes.flatMap { process -> [NetworkSocketRow] in
            let program = frame.programs[process.key]
            let title = program?.title ?? process.shortName
            let uid = process.uid
            let user = uid.map(userName)
            func row(_ id: String, _ socket: ConnectionTraffic, kind: SocketKind, activity: ConnectionActivity?)
                -> NetworkSocketRow {
                NetworkSocketRow(
                    id: "\(process.key.id)|\(id)", process: process.key, title: title, program: program,
                    uid: uid, user: user, socket: socket, kind: kind, rate: activity?.rate ?? .zero,
                    transferred: activity?.transferred ?? .zero, isNew: activity?.isNew ?? false,
                    isGone: process.isGone || (activity?.isGone ?? false)
                )
            }
            let listening = process.listeningSockets.enumerated().map { index, socket in
                row("L\(index) \(socket.local)", socket, kind: .listening, activity: nil)
            }
            let others = process.connections.compactMap { activity -> NetworkSocketRow? in
                let socket = activity.connection
                // Unbelegte UDP-Sockets (`*:*<->*:*`) haben weder Port noch Gegenstelle.
                guard socket.local.port != nil || socket.remote.address != nil else { return nil }
                return row(activity.key.id, socket, kind: socket.remote.address == nil ? .bound : .connected,
                           activity: activity)
            }
            return listening + others
        }
        .sorted { lhs, rhs in
            (lhs.kind, lhs.title.localizedLowercase, lhs.pid, lhs.id)
                < (rhs.kind, rhs.title.localizedLowercase, rhs.pid, rhs.id)
        }
    }
}

extension NetworkSocketRow {
    /// Netzwerkdienst des letzten Scans zu diesem lauschenden oder gebundenen Socket: gleiches Programm, gleicher
    /// Benutzer (soweit bekannt), Transport und Port; ein Dienst mit wechselndem Port passt zu jedem Port seines
    /// Programms. Verbindungen und QUIC haben keinen.
    public func listener(in listeners: [NetworkListener]) -> NetworkListener? {
        guard kind != .connected, let path = program?.executablePath, let port = socket.local.port,
              let transport = SocketTransport(rawValue: socket.transport.rawValue) else { return nil }
        let candidates = listeners.filter {
            $0.executablePath == path && $0.transport == transport && (uid == nil || $0.uid == uid)
        }
        return candidates.first { $0.port == port } ?? candidates.first { $0.port == nil }
    }

    /// Teil des Programmnamens oder genau der lokale bzw. entfernte Port (TM-11.5, #374).
    func matches(_ query: String) -> Bool {
        [title, program?.processName].compactMap(\.self).contains { $0.localizedCaseInsensitiveContains(query) }
            || [socket.local.port, socket.remote.port].contains { $0.map(String.init) == query }
    }
}

/// Bereich einer numerischen IP-Adresse; ohne DNS.
enum AddressScope: Hashable {
    case loopback, local, global, unspecified

    init(address: String) {
        let plain = address.hasPrefix("::ffff:") ? String(address.dropFirst(7)) : address
        let lower = plain.lowercased().split(separator: "%").first.map(String.init) ?? plain
        if ["*", "0.0.0.0", "::"].contains(lower) {
            self = .unspecified
        } else if lower == "::1" || lower.hasPrefix("127.") {
            self = .loopback
        } else if lower.contains(":") {
            // ULA fc00::/7, Link-lokal fe80::/10.
            self = ["fc", "fd", "fe8", "fe9", "fea", "feb"].contains { lower.hasPrefix($0) } ? .local : .global
        } else {
            let octets = lower.split(separator: ".").compactMap { UInt8($0) }
            guard octets.count == 4 else { self = .global; return }
            switch (octets[0], octets[1]) {
            case (10, _), (192, 168), (169, 254): self = .local
            case (172, 16...31), (100, 64...127): self = .local
            default: self = .global
            }
        }
    }

    var exposure: SocketExposure {
        switch self {
        case .loopback: .thisMac
        case .local: .localNetwork
        case .global: .internet
        case .unspecified: .allInterfaces
        }
    }
}

/// Bekannte Ports mit Dienstnamen – nur eine feste Tabelle, keine Abfrage.
enum WellKnownPort {
    static func name(of port: UInt16, transport: ConnectionTransport) -> String? {
        if transport == .quic, port == 443 { return "HTTPS (QUIC)" }
        return names[port]
    }

    private static let names: [UInt16: String] = [
        20: "FTP-Daten", 21: "FTP", 22: "SSH", 25: "SMTP", 53: "DNS", 67: "DHCP", 68: "DHCP", 80: "HTTP", 88: "Kerberos",
        110: "POP3", 123: "NTP", 137: "NetBIOS", 138: "NetBIOS", 139: "SMB", 143: "IMAP", 161: "SNMP", 389: "LDAP",
        443: "HTTPS", 445: "SMB", 465: "SMTPS", 500: "IKE", 548: "AFP", 554: "RTSP", 587: "Submission", 631: "IPP",
        636: "LDAPS", 853: "DNS über TLS", 993: "IMAPS", 995: "POP3S", 1900: "SSDP", 3283: "Apple Remote Desktop",
        3306: "MySQL", 3389: "RDP", 4500: "IPsec NAT-T", 5000: "AirPlay", 5223: "Apple Push", 5353: "mDNS",
        5432: "PostgreSQL", 5900: "VNC", 6379: "Redis", 7000: "AirPlay", 8080: "HTTP (alternativ)",
        8443: "HTTPS (alternativ)", 27017: "MongoDB", 51820: "WireGuard",
    ]
}
