import Foundation

/// Datenrate in Byte pro Sekunde.
public struct TrafficRate: Hashable, Sendable {
    public var download: Double
    public var upload: Double

    public init(download: Double, upload: Double) {
        self.download = download
        self.upload = upload
    }

    public static let zero = TrafficRate(download: 0, upload: 0)

    public var total: Double { download + upload }

    public static func + (lhs: TrafficRate, rhs: TrafficRate) -> TrafficRate {
        TrafficRate(download: lhs.download + rhs.download, upload: lhs.upload + rhs.upload)
    }

    /// Mittelwert; leer ergibt `.zero`.
    static func average(_ rates: [TrafficRate]) -> TrafficRate {
        guard !rates.isEmpty else { return .zero }
        let sum = rates.reduce(.zero, +)
        return TrafficRate(download: sum.download / Double(rates.count), upload: sum.upload / Double(rates.count))
    }
}

/// Übertragene Bytes seit Öffnen der Ansicht.
public struct ByteTotals: Hashable, Sendable {
    public var received: UInt64
    public var sent: UInt64

    public init(received: UInt64, sent: UInt64) {
        self.received = received
        self.sent = sent
    }

    public static let zero = ByteTotals(received: 0, sent: 0)

    public var total: UInt64 { received + sent }
}

/// Identität eines Prozesses über Messungen hinweg: PID **und** Startzeit, damit eine neu vergebene PID nicht die
/// Zahlen ihres Vorgängers erbt. Startzeit `0`, wenn sie nicht lesbar war (etwa `kernel_task`).
public struct ProcessKey: Hashable, Sendable, Comparable {
    public let pid: Int32
    public let startTime: UInt64

    public init(pid: Int32, startTime: UInt64) {
        self.pid = pid
        self.startTime = startTime
    }

    public var id: String { "\(pid)-\(startTime)" }

    public static func < (lhs: ProcessKey, rhs: ProcessKey) -> Bool {
        (lhs.pid, lhs.startTime) < (rhs.pid, rhs.startTime)
    }
}

/// Identität einer Verbindung innerhalb ihres Prozesses: Protokoll, beide Seiten und – für gleich aussehende Sockets
/// (mehrere `udp4 *:*<->*:*`) – ihre Reihenfolge.
public struct ConnectionKey: Hashable, Sendable, Comparable {
    public let transport: ConnectionTransport
    public let ipVersion: IPVersion
    public let local: ConnectionEndpoint
    public let remote: ConnectionEndpoint
    public let ordinal: Int

    public init(_ connection: ConnectionTraffic, ordinal: Int) {
        transport = connection.transport
        ipVersion = connection.ipVersion
        local = connection.local
        remote = connection.remote
        self.ordinal = ordinal
    }

    public var id: String { "\(transport.rawValue)\(ipVersion.rawValue) \(local)<->\(remote)#\(ordinal)" }

    public static func < (lhs: ConnectionKey, rhs: ConnectionKey) -> Bool { lhs.id < rhs.id }
}

/// Eine Verbindung mit geglätteter Rate.
public struct ConnectionActivity: Hashable, Sendable, Identifiable {
    public let key: ConnectionKey
    public let connection: ConnectionTraffic
    public let rate: TrafficRate
    public let transferred: ByteTotals
    /// In den letzten 10 s neu aufgetaucht (nicht in der ersten Messung).
    public let isNew: Bool
    /// Nicht mehr gemeldet; bleibt 10 s ausgegraut stehen.
    public let isGone: Bool

    public init(key: ConnectionKey, connection: ConnectionTraffic, rate: TrafficRate, transferred: ByteTotals,
                isNew: Bool, isGone: Bool) {
        self.key = key
        self.connection = connection
        self.rate = rate
        self.transferred = transferred
        self.isNew = isNew
        self.isGone = isGone
    }

    public var id: ConnectionKey { key }
}

/// Ein Prozess mit geglätteter Rate, übertragenen Bytes seit Öffnen der Ansicht und seinen Verbindungen (ohne
/// lauschende Sockets).
public struct ProcessActivity: Hashable, Sendable, Identifiable {
    public let key: ProcessKey
    public let shortName: String
    public let rate: TrafficRate
    public let transferred: ByteTotals
    public let connections: [ConnectionActivity]
    /// Nicht mehr gemeldet; bleibt 10 s ausgegraut stehen.
    public let isGone: Bool
    /// `rate` der Messungen seit seinem Auftauchen (ohne die Basis), älteste zuerst, höchstens
    /// `TrafficTracker.historyLength` – Verlauf im Detail eines Netzwerkdienstes.
    public let history: [TrafficRate]
    /// Lokale Ports seiner lauschenden TCP-Sockets – Verbindungen auf diesen Ports sind eingehend.
    public let listeningTCPPorts: Set<UInt16>

    public init(key: ProcessKey, shortName: String, rate: TrafficRate, transferred: ByteTotals,
                connections: [ConnectionActivity], isGone: Bool, history: [TrafficRate] = [],
                listeningTCPPorts: Set<UInt16> = []) {
        self.key = key
        self.shortName = shortName
        self.rate = rate
        self.transferred = transferred
        self.connections = connections
        self.isGone = isGone
        self.history = history
        self.listeningTCPPorts = listeningTCPPorts
    }

    public var id: ProcessKey { key }
}

/// Stand nach einer Messung (`TrafficTracker.update(with:at:)`).
public struct TrafficReport: Hashable, Sendable {
    /// Nach `ProcessKey` sortiert.
    public let processes: [ProcessActivity]
    /// Summe der Raten aller Prozesse.
    public let total: TrafficRate
    /// `total` der letzten Messungen, älteste zuerst (höchstens `TrafficTracker.historyLength`); leer bis zur zweiten
    /// Messung – erst dann gibt es eine Rate.
    public let history: [TrafficRate]
    /// Unlesbare Verbindungszeilen der letzten Messung.
    public let skippedLineCount: Int

    public init(processes: [ProcessActivity], total: TrafficRate, history: [TrafficRate], skippedLineCount: Int) {
        self.processes = processes
        self.total = total
        self.history = history
        self.skippedLineCount = skippedLineCount
    }

    public static let empty = TrafficReport(processes: [], total: .zero, history: [], skippedLineCount: 0)
}
