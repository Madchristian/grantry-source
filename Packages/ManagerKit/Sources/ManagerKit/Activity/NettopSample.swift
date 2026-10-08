import Foundation

/// Transportprotokoll einer von nettop gemeldeten Verbindung.
public enum ConnectionTransport: String, Hashable, Sendable {
    case tcp, udp, quic

    /// „TCP“, „UDP“, „QUIC“.
    public var displayName: String { rawValue.uppercased() }
}

/// IP-Version einer Verbindung (Ziffer am Protokoll: `tcp4`, `udp6`).
public enum IPVersion: Int, Hashable, Sendable {
    case v4 = 4, v6 = 6

    init?(digit: Character?) {
        switch digit {
        case "4": self = .v4
        case "6": self = .v6
        default: return nil
        }
    }
}

/// Lokale oder entfernte Seite einer Verbindung; `nil` steht für nettops `*` (unbestimmt).
public struct ConnectionEndpoint: Hashable, Sendable, CustomStringConvertible {
    /// Numerische Adresse, bei IPv6 ggf. mit Zone (`fe80::1%en0`).
    public let address: String?
    public let port: UInt16?

    public init(address: String?, port: UInt16?) {
        self.address = address
        self.port = port
    }

    /// Liest nettops Schreibweise: IPv4 `adresse:port`, IPv6 `adresse.port`, `*` für unbestimmt; `nil` bei
    /// unlesbarem Text.
    init?(nettop text: Substring, version: IPVersion) {
        let separator: Character = version == .v4 ? ":" : "."
        guard let index = text.lastIndex(of: separator) else { return nil }
        let address = text[..<index]
        let port = text[text.index(after: index)...]
        guard !address.isEmpty, !port.isEmpty else { return nil }
        if port == "*" {
            self.port = nil
        } else {
            guard let value = UInt16(port) else { return nil }
            self.port = value
        }
        self.address = address == "*" ? nil : String(address)
    }

    /// „192.0.2.1:443“, „[2001:db8::1]:443“, „*“ für unbestimmt.
    public var description: String {
        let host = address.map { $0.contains(":") ? "[\($0)]" : $0 } ?? "*"
        return port.map { "\(host):\($0)" } ?? host
    }
}

/// Eine Verbindung (Socket) eines Prozesses laut nettop. Bytes sind kumulativ seit Öffnen des Sockets; nettop lässt
/// die Felder bei manchen Sockets leer (`nil`).
public struct ConnectionTraffic: Hashable, Sendable {
    public let transport: ConnectionTransport
    public let ipVersion: IPVersion
    public let local: ConnectionEndpoint
    public let remote: ConnectionEndpoint
    /// TCP-Zustand wie von nettop geschrieben (`Established`, `Listen`, `SynSent` …), bei UDP/QUIC leer.
    public let state: String
    public let bytesIn: UInt64?
    public let bytesOut: UInt64?

    public init(transport: ConnectionTransport, ipVersion: IPVersion, local: ConnectionEndpoint,
                remote: ConnectionEndpoint, state: String, bytesIn: UInt64?, bytesOut: UInt64?) {
        self.transport = transport
        self.ipVersion = ipVersion
        self.local = local
        self.remote = remote
        self.state = state
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }

    /// Lauschender Socket – gehört zur Ansicht „Dienste“, nicht zur Aktivität.
    public var isListening: Bool { state == "Listen" }
}

/// Ein Prozess laut nettop mit seinen Verbindungen; Bytes kumulativ seit Prozessbeginn, `nil`, wenn nettop die Felder
/// leer lässt.
public struct ProcessTraffic: Hashable, Sendable {
    public let pid: Int32
    /// Von nettop auf 15 Zeichen gekürzter Name, ohne Leerzeichen am Ende.
    public let shortName: String
    public let bytesIn: UInt64?
    public let bytesOut: UInt64?
    public var connections: [ConnectionTraffic]
    /// Startzeit des Prozesses in µs seit 1970, gelesen beim Eingang seiner Zeile (`NettopSampleAssembler`) – sie
    /// unterscheidet ihn von einem späteren Prozess mit derselben PID. `nil`: nicht lesbar (Prozess schon beendet)
    /// oder nicht erfasst (Parser).
    public var startTime: UInt64?

    public init(pid: Int32, shortName: String, bytesIn: UInt64?, bytesOut: UInt64?,
                connections: [ConnectionTraffic] = [], startTime: UInt64? = nil) {
        self.pid = pid
        self.shortName = shortName
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.connections = connections
        self.startTime = startTime
    }
}

/// Ein Block der nettop-Ausgabe (eine Messung).
public struct NettopSample: Hashable, Sendable {
    public let processes: [ProcessTraffic]
    /// Verbindungszeilen, die nicht lesbar waren (unbekanntes Protokoll, unlesbare Adresse) – Hinweis, kein Abbruch.
    public let skippedLineCount: Int

    public init(processes: [ProcessTraffic], skippedLineCount: Int = 0) {
        self.processes = processes
        self.skippedLineCount = skippedLineCount
    }

    /// Dieselbe Messung mit den Startzeiten aus `startTimes` (nach PID); fehlende bleiben `nil`.
    func identifying(with startTimes: [Int32: UInt64]) -> NettopSample {
        NettopSample(processes: processes.map { process in
            var process = process
            process.startTime = startTimes[process.pid]
            return process
        }, skippedLineCount: skippedLineCount)
    }
}

/// Eine Messung mit dem Zeitpunkt, an dem nettop ihren Block begann.
public struct TimedNettopSample: Hashable, Sendable {
    public let sample: NettopSample
    public let capturedAt: ContinuousClock.Instant

    public init(sample: NettopSample, capturedAt: ContinuousClock.Instant) {
        self.sample = sample
        self.capturedAt = capturedAt
    }
}
