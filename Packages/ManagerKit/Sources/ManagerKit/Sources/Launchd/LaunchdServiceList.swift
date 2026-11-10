import Darwin
import GrantryShared

/// launchd-Domäne im Tab „Dienste“ (Spec 2026-11-06 §6, Stufe 4): die grafische Sitzung des Benutzers oder das System.
public enum LaunchdServiceDomain: Hashable, Sendable {
    case user(uid_t)
    case system

    /// Name für `launchctl`, z. B. `gui/501` oder `system`.
    public var name: String {
        switch self {
        case .user(let uid): "gui/\(uid)"
        case .system: PrivilegedOperationPolicy.systemLaunchctlDomain
        }
    }

    public var isSystem: Bool {
        if case .system = self { true } else { false }
    }
}

/// Letzter Exit-Status eines Dienstes laut `launchctl print`.
public enum LaunchdExitStatus: Hashable, Sendable {
    /// „-“: seit dem Laden nicht beendet.
    case never
    case exited(Int32)
    /// Negativer Wert in der Ausgabe: durch dieses Signal beendet.
    case signaled(Int32)
    /// Andere Angabe von launchd, unverändert (z. B. „(jt)“).
    case other(String)

    init(_ text: some StringProtocol) {
        if text == "-" {
            self = .never
        } else if let code = Int32(text) {
            self = code < 0 ? .signaled(Int32(clamping: code.magnitude)) : .exited(code)
        } else {
            self = .other(String(text))
        }
    }
}

/// Ein Dienst einer Domäne: PID, solange er läuft, und sein letzter Exit-Status.
public struct LaunchdServiceStatus: Hashable, Sendable {
    public let label: String
    public let pid: Int32?
    public let lastExit: LaunchdExitStatus

    public init(label: String, pid: Int32?, lastExit: LaunchdExitStatus) {
        self.label = label
        self.pid = pid
        self.lastExit = lastExit
    }
}

/// Liest die Dienste einer Domäne über `launchctl print <domäne>` – nur lesend, als Benutzer auch für `system`.
public struct LaunchdServiceReader: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    /// - Throws: `LaunchdSourceError.launchctlFailed` bei Fehlern und unbekanntem Ausgabeformat; `CancellationError`
    ///   unverändert.
    public func services(in domain: LaunchdServiceDomain) async throws -> [LaunchdServiceStatus] {
        try await runner.launchctl(["print", domain.name], domain: domain.name, parse: LaunchctlParsers.services)
    }
}
