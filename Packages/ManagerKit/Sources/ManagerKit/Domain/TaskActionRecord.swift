import Foundation

/// Eine Aktion des Task-Managers im Verlauf (TM-9.5): fremden Prozess beenden, Priorität ändern oder einen eigenen
/// Dienst starten bzw. stoppen (TM10). Nur Name, PID, Benutzer und Ergebnis – kein Pfad, keine Argumente, keine
/// Messwerte (Spec §2, §3).
public struct TaskActionRecord: Hashable, Sendable, Codable, Identifiable {
    public enum Action: Hashable, Sendable, Codable {
        case terminate
        case forceTerminate
        case setPriority(ProcessPriority)
        /// Dienst starten (`ServiceControl`); `processName` ist das Label, `pid` fehlt.
        case startService
        /// Dienst stoppen (`ServiceControl`); `processName` ist das Label, `pid` fehlt.
        case stopService
    }

    public enum Outcome: Hashable, Sendable, Codable {
        case done
        case failed(String)
    }

    public let id: UUID
    public let action: Action
    public let processName: String
    /// `nil` bei Diensten: Jeder Start vergibt eine neue PID, der Dienst steht über sein Label im Verlauf.
    public let pid: Int32?
    public let userName: String
    public let outcome: Outcome

    public init(id: UUID = UUID(), action: Action, processName: String, pid: Int32?, userName: String, outcome: Outcome) {
        self.id = id
        self.action = action
        self.processName = processName
        self.pid = pid
        self.userName = userName
        self.outcome = outcome
    }

    /// Ereignis für den Verlauf (immer „hinzugefügt“, gelesen).
    public func event(at date: Date) -> ChangeEvent {
        ChangeEvent(kind: .added, before: nil, after: .taskAction(self), detectedAt: date)
    }
}

/// Schreibt Task-Manager-Aktionen in den Verlauf; in der App `SwiftDataSnapshotStore`. Eigenes Protokoll statt einer
/// Erweiterung von `SnapshotStore` (ISP): Die Überwachung braucht es nicht.
public protocol TaskActionLogging: Sendable {
    func record(_ record: TaskActionRecord, at date: Date) async throws
}

extension TaskActionRecord {
    /// Je Prozess anderer Benutzer ein Eintrag; eigene Prozesse beendet die App ohne Helper und protokolliert sie nicht
    /// (TM3).
    static func terminations(of result: TaskTerminationResult, currentUID: UInt32,
                             userName: (UInt32) -> String) -> [TaskActionRecord] {
        let failures = Dictionary(result.report.failures.map { ($0.process, $0.message) }, uniquingKeysWith: { $1 })
        let running = Set(result.report.stillRunning)
        return result.request.processes.filter { $0.uid != currentUID }.map { process in
            let outcome: Outcome = if let message = failures[process] {
                .failed(message)
            } else if running.contains(process) {
                .failed("läuft noch")
            } else {
                .done
            }
            return TaskActionRecord(action: result.force ? .forceTerminate : .terminate,
                                    processName: ProcessTerminationPolicy.displayName(of: process.executablePath),
                                    pid: process.pid, userName: userName(process.uid), outcome: outcome)
        }
    }
}
