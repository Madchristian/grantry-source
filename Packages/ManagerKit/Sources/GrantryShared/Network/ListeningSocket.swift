import Foundation

/// Transportprotokoll eines Sockets.
public enum SocketTransport: String, Hashable, Sendable, Codable, CaseIterable {
    case tcp, udp
}

/// Ein lauschender TCP- bzw. gebundener, nicht verbundener UDP-Socket eines Prozesses – nur Metadaten, die der Helper
/// herausgeben darf (keine Argumente, keine Umgebung, keine Dateien).
///
/// `startTime` benennt die Prozessgeneration, der der Socket beim Lesen gehörte (`RunningProcess.startTime`): Ohne sie
/// könnte ein später unter derselben PID gestarteter Prozess desselben Programms und Benutzers als Besitzer dieses
/// Sockets gelten (#153, Befund 2). Sie fehlt nur in Scans älterer Helper (Protokoll ≤ 4).
public struct ListeningSocket: Hashable, Sendable, Codable {
    public var pid: Int32
    public var uid: UInt32
    /// Programmpfad laut `proc_pidpath`.
    public var executablePath: String
    public var transport: SocketTransport
    /// Lokale Adresse numerisch (`127.0.0.1`, `::`, `0.0.0.0`, `fe80::1`).
    public var localAddress: String
    public var localPort: UInt16
    /// Programmpfade der Elternkette (Eltern zuerst), ohne den Prozess selbst und ohne `launchd` (PID 1).
    public var ancestors: [String]
    /// Startzeit des Besitzers beim Lesen (`RunningProcess.startTime`); `nil` nur aus Scans älterer Helper.
    public var startTime: UInt64?
    /// `true`, wenn der Kernel den Port bei `bind(0)` vergab (`INP_ANONPORT`): ein Zufallsport, der mit jedem Start
    /// wechselt. `false` bei ausdrücklich gewähltem Port – auch im Ephemeralbereich (WireGuard auf 51820). `nil`, wenn
    /// der Lieferant das Flag nicht kennt (älterer Helper, Protokoll ≤ 5); dann entscheidet der Portbereich.
    public var hasSystemAssignedPort: Bool?

    public init(pid: Int32, uid: UInt32, executablePath: String, transport: SocketTransport, localAddress: String,
                localPort: UInt16, ancestors: [String] = [], startTime: UInt64? = nil,
                hasSystemAssignedPort: Bool? = nil) {
        self.pid = pid
        self.uid = uid
        self.executablePath = executablePath
        self.transport = transport
        self.localAddress = localAddress
        self.localPort = localPort
        self.ancestors = ancestors
        self.startTime = startTime
        self.hasSystemAssignedPort = hasSystemAssignedPort
    }

    /// Der Socket gehört zu `process` – gleicher Prozess derselben Generation (PID, Benutzer, Programm, Startzeit).
    /// Ohne `startTime` (älterer Helper) nie.
    public func belongs(to process: RunningProcess) -> Bool {
        process.pid == pid && process.uid == uid && process.executablePath == executablePath && process.startTime == startTime
    }
}

/// Ergebnis eines Durchlaufs: Sockets und die Zahl der Prozesse, deren Sockets mangels Berechtigung nicht lesbar waren
/// (fremde Benutzer ohne root). Während des Durchlaufs beendete Prozesse und Zombies zählen nicht mit.
///
/// Ob die Erfassung eingeschränkt war, leitet die App aus Erfolg und Misserfolg des Helpers ab; `deniedProcessCount`
/// einer Helper-Messung meldet sie zusätzlich als Einschränkung (`NetworkListenerSource`, #142). Lokal (ohne root) ist
/// er erwartbar und zählt nicht.
public struct ListeningSocketScan: Hashable, Sendable, Codable {
    public var sockets: [ListeningSocket]
    public var deniedProcessCount: Int

    public init(sockets: [ListeningSocket], deniedProcessCount: Int = 0) {
        self.sockets = sockets
        self.deniedProcessCount = deniedProcessCount
    }
}

/// Liefert die lauschenden Sockets aller lesbaren Prozesse.
public protocol ListeningSocketEnumerating: Sendable {
    func listeningSockets() throws -> ListeningSocketScan
}

/// Prüft, ob ein Prozess gerade mindestens einen lauschenden Socket hat (`ListeningRequirement`).
public protocol ListeningProcessChecking: Sendable {
    /// `false` auch, wenn die Sockets des Prozesses nicht lesbar sind (fail-closed).
    func isListening(_ pid: pid_t) -> Bool
}

/// Die Prozessliste war nicht lesbar.
public struct ListeningSocketError: LocalizedError, Equatable {
    /// `errno` des gescheiterten Aufrufs.
    public let code: Int32
    public init(code: Int32) { self.code = code }
    public var errorDescription: String? { "Prozessliste nicht lesbar (errno \(code))" }
}
