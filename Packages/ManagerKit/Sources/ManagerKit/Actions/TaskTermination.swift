import Foundation
import GrantryShared

/// Was „Task beenden“ träfe (`ProcessListRow.terminationCandidate(currentUID:)`): bei einer App alle ihre Prozesse,
/// App-Prozess zuerst, sonst der eine Prozess.
public struct TaskTerminationCandidate: Hashable, Sendable {
    /// Warum eine Zeile mit Prozessen anderer Benutzer nicht beendbar ist (Spec §2: deaktiviert mit Hinweis): Sie hat
    /// mehrere Prozesse, und TM9 fragt je Prozess nach dem Kennwort.
    public static let foreignProcessNote = "Prozesse anderer Benutzer einzeln beenden: Zeile aufklappen und Prozess "
        + "wählen (je Prozess fragt macOS nach dem Administratorkennwort)."
    /// Warum im Tab „Details“ ein Prozess eines anderen Benutzers gesperrt ist: Dort gibt es keine Zeile zum Aufklappen,
    /// beendet wird im Tab „Prozesse“ (TM9).
    public static let foreignProcessInDetailsNote = "Prozesse anderer Benutzer beendet Grantry im Tab „Prozesse“ "
        + "(je Prozess fragt macOS nach dem Administratorkennwort)."

    public let name: String
    public let keys: [ProcessKey]

    public init(name: String, keys: [ProcessKey]) {
        self.name = name
        self.keys = keys
    }
}

extension ProtectedProcesses {
    /// Hinweis für den Task-Manager, wenn einer der frisch gelesenen Prozesse auf der Schutzliste steht, sonst `nil`.
    /// Gemeinsam für „Task beenden“ und „Priorität“: Der Hinweis ersetzt die Rückfrage; die Policy beim Signal und der
    /// Helper prüfen dieselbe Liste noch einmal.
    func notice(forAny processes: [RunningProcess]) -> String? {
        processes.first { protects(pid: $0.pid, executablePath: $0.executablePath) }.map {
            ProcessTerminationViolation.systemCritical(ProcessTerminationPolicy.displayName(of: $0.executablePath))
                .readableDescription
        }
    }
}

/// Bestätigte Prozesse für „Task beenden“; Identität (PID, Startzeit, Pfad) frisch gelesen, Reihenfolge wie in der Zeile.
public struct TaskTerminationRequest: Hashable, Sendable, Identifiable {
    public let name: String
    public let processes: [RunningProcess]

    public init(name: String, processes: [RunningProcess]) {
        precondition(!processes.isEmpty, "Anfrage ohne Prozesse")
        self.name = name
        self.processes = processes
    }

    /// Auch `ActionRunner.runningRecordID`.
    public var id: String { "task:\(processes[0].pid)-\(processes[0].startTime)" }
}

/// Ergebnis von „Task beenden“.
public struct TaskTerminationResult: Hashable, Sendable {
    public let request: TaskTerminationRequest
    public let force: Bool
    public let outcome: ActionOutcome
    public let report: ProcessTerminationReport

    public init(request: TaskTerminationRequest, force: Bool, outcome: ActionOutcome, report: ProcessTerminationReport) {
        self.request = request
        self.force = force
        self.outcome = outcome
        self.report = report
    }

    /// „Sofort beenden“ für die Überlebenden eines SIGTERM; nach SIGKILL nie.
    public var forceRequest: TaskTerminationRequest? {
        guard !force, !report.stillRunning.isEmpty else { return nil }
        return TaskTerminationRequest(name: request.name, processes: report.stillRunning)
    }

    /// Beendet über `terminator` und bewertet wie „Prozess beenden …“ (`ActionCoordinator.warning(after:force:)`), aber
    /// ohne Prüfscan: Der Task-Manager zeigt das Ende im nächsten Takt.
    static func perform(_ request: TaskTerminationRequest, force: Bool,
                        using terminator: any ProcessListTerminating) async -> TaskTerminationResult {
        let report = await terminator.terminate(request.processes, force: force)
        let outcome: ActionOutcome
        do {
            outcome = try ActionCoordinator.warning(after: report, force: force).map { .doneButUnverified($0) } ?? .done
        } catch {
            outcome = .failed(error.readableDescription)
        }
        return TaskTerminationResult(request: request, force: force, outcome: outcome, report: report)
    }

    /// Ohne Coordinator (Überwachung nicht verfügbar).
    @MainActor static func unavailable(_ request: TaskTerminationRequest, force: Bool) -> TaskTerminationResult {
        TaskTerminationResult(request: request, force: force, outcome: .failed(ActionRunner.unavailableMessage),
                              report: ProcessTerminationReport())
    }
}

extension ActionRunner {
    /// „Task beenden“ im Task-Manager: wie jede Aktion höchstens eine zur Zeit und nie während einer
    /// Helper-Installation; das Ergebnis erscheint im Kontext `.taskManager`. `nil`, wenn die Aktion nicht begonnen hat.
    @discardableResult
    public func terminate(
        _ request: TaskTerminationRequest, force: Bool, using terminator: any ProcessListTerminating,
        context: ActionContext = .taskManager
    ) async -> TaskTerminationResult? {
        var finished: TaskTerminationResult?
        await run(recordID: request.id, context: context,
                  unavailable: { TaskTerminationResult.unavailable(request, force: force) }) { _ in
            await TaskTerminationResult.perform(request, force: force, using: terminator)
        } present: { result in
            finished = result
            return .taskTermination(result)
        }
        return finished
    }
}
