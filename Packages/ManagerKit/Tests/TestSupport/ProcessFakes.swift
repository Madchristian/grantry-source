import Foundation
import GrantryShared
import Synchronization

/// Prozessliste mit festem Inhalt.
public struct FixedProcessInspector: ProcessInspecting {
    private let processes: [pid_t: RunningProcess]
    private let unconfirmed: Set<pid_t>

    /// - Parameter unconfirmed: PIDs, deren Prozess läuft (`liveness(of:)`), dessen Identität aber nicht bestätigt
    ///   werden kann (`process(_:)` liefert `nil`) – etwa ein `exec` zwischen den beiden Token-Lesungen (#153).
    public init(_ processes: [RunningProcess], unconfirmed: Set<pid_t> = []) {
        self.processes = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        self.unconfirmed = unconfirmed
    }

    public func process(_ pid: pid_t) -> RunningProcess? { unconfirmed.contains(pid) ? nil : processes[pid] }

    public func liveness(of pid: pid_t) -> ProcessLiveness { Self.liveness(of: processes[pid]) }

    /// Lebendzustand laut Tabelleneintrag: vorhanden → läuft mit dessen Startzeit, sonst beendet.
    public static func liveness(of process: RunningProcess?) -> ProcessLiveness {
        process.map { .running(startTime: $0.startTime) } ?? .absent
    }
}

/// Lauschende Prozesse mit festem Inhalt.
public struct FixedListeningPIDs: ListeningProcessChecking {
    private let pids: Set<pid_t>

    public init(_ pids: Set<pid_t>) { self.pids = pids }

    public func isListening(_ pid: pid_t) -> Bool { pids.contains(pid) }
}

/// Signaturprüfung mit festem Ergebnis.
public struct FixedAppleSignature: AppleSignatureChecking {
    private let result: AppleSignatureVerdict

    public init(_ result: AppleSignatureVerdict) { self.result = result }

    public func verdict(pid: pid_t, executablePath: String) -> AppleSignatureVerdict { result }
}

/// Signalgeber ohne Wirkung: merkt sich jedes Signal (Leitplanke 5).
public final class RecordingSignaler: ProcessSignaling {
    public struct Sent: Equatable, Sendable {
        public let signal: TerminationSignal
        public let pid: pid_t

        public init(signal: TerminationSignal, pid: pid_t) {
            self.signal = signal
            self.pid = pid
        }
    }

    private let log = Mutex<[Sent]>([])
    private let delivery: SignalDelivery

    public init(delivery: SignalDelivery = .delivered) { self.delivery = delivery }

    public var sent: [Sent] { log.withLock { $0 } }

    public func send(_ signal: TerminationSignal, to process: RunningProcess) throws(ProcessTerminationViolation) -> SignalDelivery {
        log.withLock { $0.append(Sent(signal: signal, pid: process.pid)) }
        return delivery
    }
}
