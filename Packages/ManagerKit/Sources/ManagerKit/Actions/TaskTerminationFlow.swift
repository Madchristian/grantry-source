import Darwin
import Foundation
import GrantryShared
import Observation

/// „Task beenden“ im Task-Manager (Spec 2026-11-06 §2): ⌫ bzw. die Schaltfläche fragt nach SIGTERM, ⌥⌫ direkt nach
/// SIGKILL. Vor der Bestätigung liest `prepare` die Prozesse frisch (PID **und** Startzeit, eigener Benutzer; mit
/// `allowsForeignProcesses` auch andere), damit eine inzwischen neu vergebene PID nicht getroffen wird. Programme der
/// Schutzliste (`ProtectedProcesses.system`) bekommen statt der Rückfrage einen Hinweis, auf jedem Weg hierher
/// (Tabellenzeile, Tasten, Aktionsleiste, Kontextmenü) und noch einmal in `confirm`. Unmittelbar vor dem Signal prüft
/// `OwnProcessSignaler` mit `ProcessTerminationPolicy.taskManagerProcess()` erneut, bei fremden Prozessen der Helper.
/// Überleben Prozesse das SIGTERM, bietet `forceOffer` die zweite Bestätigung an. Wie `ProcessTerminationFlow`, aber
/// ohne Lauscher-Bezug und Prüfscan.
@MainActor
@Observable
public final class TaskTerminationFlow {
    public enum Step: Hashable, Identifiable, Sendable {
        case terminate(TaskTerminationRequest)
        case forceTerminate(TaskTerminationRequest)

        public var request: TaskTerminationRequest {
            switch self {
            case .terminate(let request), .forceTerminate(let request): request
            }
        }

        public var isForce: Bool {
            if case .forceTerminate = self { true } else { false }
        }

        public var id: String { (isForce ? "kill:" : "term:") + request.id }

        public var confirmation: ActionConfirmation {
            isForce ? .forceTerminateTask(request) : .terminateTask(request)
        }
    }

    static let notRunning = "Der Prozess läuft nicht mehr."
    static let ownProcess = "Grantry beendet sich nicht selbst."

    /// Schritt für das Bestätigungsblatt; das Blatt setzt ihn beim Schließen zurück.
    public var pendingStep: Step?
    /// Überlebende des letzten SIGTERM.
    public private(set) var forceOffer: TaskTerminationRequest?
    /// Hinweis, warum nichts zu bestätigen war.
    public private(set) var notice: String?

    private let actions: ActionRunner
    private let terminator: any ProcessListTerminating
    private let inspector: any ProcessInspecting
    private let currentUID: UInt32
    private let ownPID: Int32
    /// Prozesse anderer Benutzer annehmen (TM9: `terminator` beendet sie über den Helper mit Admin-Bestätigung).
    private let allowsForeignProcesses: Bool
    private let log: (any TaskActionLogging)?
    private let userName: @Sendable (UInt32) -> String
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - allowsForeignProcesses: Prozesse anderer Benutzer zulassen; nur mit einem `terminator`, der sie über den
    ///     Helper beendet (`HelperTaskTerminator`).
    ///   - log: Verlauf für beendete Prozesse anderer Benutzer.
    public init(
        actions: ActionRunner,
        terminator: any ProcessListTerminating = ProcessTerminator(
            own: OwnProcessSignaler(policy: .taskManagerProcess()), privileged: nil, ledger: nil
        ),
        inspector: any ProcessInspecting = LibprocProcessInspector(allowingUnreadableExecutablePath: true),
        currentUID: UInt32 = getuid(), ownPID: Int32 = getpid(), allowsForeignProcesses: Bool = false,
        log: (any TaskActionLogging)? = nil,
        userName: @escaping @Sendable (UInt32) -> String = UserAccount.shortName(of:),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.actions = actions
        self.terminator = terminator
        self.inspector = inspector
        self.currentUID = currentUID
        self.ownPID = ownPID
        self.allowsForeignProcesses = allowsForeignProcesses
        self.log = log
        self.userName = userName
        self.now = now
    }

    /// Ob gerade beendet werden kann (keine andere Aktion, keine Helper-Installation).
    public var canStart: Bool { actions.canStart && !actions.isRunning }

    /// ⌫ (`force == false`) bzw. ⌥⌫: Prozesse bestätigen und die passende Rückfrage öffnen.
    public func prepare(_ candidate: TaskTerminationCandidate, force: Bool) {
        guard canStart else { return }
        notice = nil
        forceOffer = nil
        guard !candidate.keys.contains(where: { $0.pid == ownPID }) else {
            notice = Self.ownProcess
            return
        }
        let processes = candidate.keys.compactMap { key in
            inspector.process(key.pid).flatMap { process in
                process.startTime == key.startTime && (allowsForeignProcesses || process.uid == currentUID)
                    ? process : nil
            }
        }
        guard !processes.isEmpty else {
            notice = Self.notRunning
            return
        }
        // Vor der Rückfrage, damit niemand für `loginwindow` & Co. bestätigt; maßgeblich bleibt die Policy beim Signal.
        if let protected = ProtectedProcesses.system.notice(forAny: processes) {
            notice = protected
            return
        }
        let request = TaskTerminationRequest(name: candidate.name, processes: processes)
        pendingStep = force ? .forceTerminate(request) : .terminate(request)
    }

    /// Bestätigter Schritt: beenden; nach SIGTERM mit Überlebenden SIGKILL anbieten. Prozesse anderer Benutzer kommen
    /// in den Verlauf (TM-9.5). Ein Schritt mit einem Programm der Schutzliste geht auch dann nicht hinaus, wenn er
    /// nicht aus `prepare` stammt: Fremde Prozesse erreichten sonst den Helper, eigene erst die Policy beim Signal.
    public func confirm(_ step: Step) async {
        if let protected = ProtectedProcesses.system.notice(forAny: step.request.processes) {
            notice = protected
            return
        }
        guard let result = await actions.terminate(step.request, force: step.isForce, using: terminator) else { return }
        forceOffer = result.forceRequest
        for record in TaskActionRecord.terminations(of: result, currentUID: currentUID, userName: userName) {
            await TaskActionHistory.record(record, in: log, at: now())
        }
    }

    /// „Sofort beenden“ für die Überlebenden: zweite Bestätigung.
    public func offerForce() {
        guard let forceOffer else { return }
        pendingStep = .forceTerminate(forceOffer)
    }

    public func dismissNotice() {
        notice = nil
    }
}
