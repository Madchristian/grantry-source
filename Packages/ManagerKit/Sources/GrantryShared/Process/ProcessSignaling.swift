import Darwin

/// Signal von „Prozess beenden …“: erst höflich, auf Nachfrage hart.
public enum TerminationSignal: String, Sendable, Equatable {
    case terminate = "SIGTERM"
    case kill = "SIGKILL"

    public init(force: Bool) {
        self = force ? .kill : .terminate
    }

    public var number: Int32 { self == .terminate ? SIGTERM : SIGKILL }
}

/// Ergebnis eines zugestellten Signals.
public enum SignalDelivery: Equatable, Sendable {
    case delivered
    /// `ESRCH`: Der Prozess war schon beendet – zählt als Erfolg.
    case alreadyGone
}

/// Stellt ein Signal an einen geprüften Prozess zu; prüft nichts außer PID und Prozessgeneration (die Prüfungen macht
/// `ProcessTerminationPolicy`).
public protocol ProcessSignaling: Sendable {
    func send(_ signal: TerminationSignal, to process: RunningProcess) throws(ProcessTerminationViolation) -> SignalDelivery
}

/// `proc_signal_with_audittoken`: Das Signal geht an die Prozessgeneration aus `RunningProcess.auditToken`, nicht an die
/// PID – ein Nachfolger, der die PID zwischen Prüfung und Zustellung bekommen hat, bleibt unberührt (`ESRCH`, zählt als
/// bereits beendet). Ohne Token wird nicht gesendet (`identityUnknown`, fail-closed). Jede PID ≤ 1 ist **vor** dem
/// Aufruf ausgeschlossen: `kill(0, …)` träfe die eigene Prozessgruppe, `kill(-1, …)` alle erlaubten Prozesse, PID 1 ist
/// launchd.
public struct PosixProcessSignaler: ProcessSignaling {
    /// Zustellung mit Rückgabe `0` oder `errno`.
    private let deliver: @Sendable (ProcessAuditToken, Int32) -> Int32

    public init() {
        self.init(deliver: { token, signal in
            var raw = token.raw
            let code = proc_signal_with_audittoken(&raw, signal)
            return code == -1 ? errno : code
        })
    }

    init(deliver: @escaping @Sendable (ProcessAuditToken, Int32) -> Int32) {
        self.deliver = deliver
    }

    public func send(_ signal: TerminationSignal, to process: RunningProcess) throws(ProcessTerminationViolation) -> SignalDelivery {
        let pid = process.pid
        guard pid > 1 else { throw .protectedProcess(pid) }
        guard let token = process.auditToken, token.pid == pid else { throw .identityUnknown(pid) }
        switch deliver(token, signal.number) {
        case 0: return .delivered
        case ESRCH: return .alreadyGone
        case EPERM: throw .notPermitted(pid)
        case let code: throw .signalFailed(pid, errno: code)
        }
    }
}
