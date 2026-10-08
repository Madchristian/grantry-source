import Foundation

/// Signal an einen Prozess des eigenen Benutzers, ohne Helper (Spec §4).
public protocol OwnProcessSignaling: Sendable {
    /// - Throws: `ProcessTerminationViolation`, wenn sich der Prozess geändert hat oder geschützt ist; ein bereits
    ///   beendeter Prozess ist kein Fehler.
    func signal(_ process: RunningProcess, _ signal: TerminationSignal) throws
}

/// Nimmt nur Prozesse des eigenen Benutzers an (sonst `notPermitted`) und prüft unmittelbar vor dem Signal mit
/// `ProcessTerminationPolicy.app()` – PID > 1, nicht Grantry, Pfad, uid und **Startzeit gleich**, lauschender Socket
/// (bzw. SIGKILL nach erlaubtem SIGTERM, `ListeningRequirement`) – und sendet dann an den **bestätigten** Prozess
/// (`ProcessAuditToken`, nicht an die PID). Die Startzeit (`RunningProcess.startTime`) erkennt eine inzwischen neu
/// vergebene PID auch dann, wenn derselbe Benutzer dasselbe Programm neu gestartet hat; der Prozess gilt dann als „hat
/// sich geändert“ und bekommt kein Signal.
public struct OwnProcessSignaler: OwnProcessSignaling {
    private let policy: ProcessTerminationPolicy
    private let signaler: any ProcessSignaling
    private let currentUID: UInt32

    public init(
        policy: ProcessTerminationPolicy = .app(),
        signaler: any ProcessSignaling = PosixProcessSignaler(),
        currentUID: UInt32 = getuid()
    ) {
        self.policy = policy
        self.signaler = signaler
        self.currentUID = currentUID
    }

    public func signal(_ process: RunningProcess, _ signal: TerminationSignal) throws {
        guard process.uid == currentUID else { throw ProcessTerminationViolation.notPermitted(process.pid) }
        let target = try policy.validate(
            pid: process.pid, executablePath: process.executablePath, requiredUID: process.uid, startTime: process.startTime,
            force: signal == .kill
        )
        guard case .running(let confirmed) = target else { return }
        _ = try signaler.send(signal, to: confirmed)
    }
}
