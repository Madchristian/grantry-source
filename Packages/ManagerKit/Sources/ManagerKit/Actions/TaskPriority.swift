import Darwin
import Foundation
import Observation
import os

/// Schreibt Task-Manager-Aktionen in den Verlauf; ein Fehler der Ablage verhindert die Aktion nicht, er wird protokolliert.
enum TaskActionHistory {
    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "task-manager")

    static func record(_ record: TaskActionRecord, in log: (any TaskActionLogging)?, at date: Date) async {
        guard let log else { return }
        do {
            try await log.record(record, at: date)
        } catch {
            logger.error("Task-Aktion nicht im Verlauf: \(error.readableDescription, privacy: .public)")
        }
    }
}

/// Bestätigte Prioritätsänderung: ein Prozess mit frisch gelesener Identität, Ziel- und bisherige Stufe.
public struct TaskPriorityRequest: Hashable, Sendable, Identifiable {
    public let name: String
    public let process: RunningProcess
    public let priority: ProcessPriority
    /// Aktueller nice-Wert; `nil`, wenn nicht lesbar.
    public let currentNice: Int32?

    public init(name: String, process: RunningProcess, priority: ProcessPriority, currentNice: Int32?) {
        self.name = name
        self.process = process
        self.priority = priority
        self.currentNice = currentNice
    }

    public var id: String { "priority:\(process.pid)-\(process.startTime)" }

    /// Eigene Prozesse darf die App selbst nur „herunterstufen“ (nice gleich oder höher); alles andere geht über den
    /// Helper mit Admin-Bestätigung.
    public func needsHelper(currentUID: UInt32) -> Bool {
        guard process.uid == currentUID, let currentNice else { return true }
        return priority.rawValue < currentNice
    }
}

/// Setzt die Priorität: eigene Prozesse ohne Helper (nach erneuter Prüfung mit `taskManagerProcess()`), sonst über den
/// Helper mit frischer Admin-Bestätigung (TM-9.3).
public protocol TaskPrioritySetting: Sendable {
    func setPriority(_ request: TaskPriorityRequest) async throws
}

public struct TaskPrioritySetter: TaskPrioritySetting {
    private let policy: ProcessTerminationPolicy
    private let setter: any ProcessPrioritySetting
    private let helper: (any PrivilegedTaskControlling)?
    private let authorization: any ActionAuthorizationIssuing
    private let currentUID: UInt32

    public init(policy: ProcessTerminationPolicy = .taskManagerProcess(),
                setter: any ProcessPrioritySetting = PosixPrioritySetter(), helper: (any PrivilegedTaskControlling)?,
                authorization: any ActionAuthorizationIssuing = ActionAuthorization(), currentUID: UInt32 = getuid()) {
        self.policy = policy
        self.setter = setter
        self.helper = helper
        self.authorization = authorization
        self.currentUID = currentUID
    }

    public func setPriority(_ request: TaskPriorityRequest) async throws {
        let process = request.process
        guard request.needsHelper(currentUID: currentUID) else {
            let target = try policy.validate(pid: process.pid, executablePath: process.executablePath,
                                             requiredUID: process.uid, startTime: process.startTime)
            guard case .running(let confirmed) = target else { throw TaskActionViolation.processGone(process.pid) }
            return try setter.setPriority(request.priority, of: confirmed)
        }
        guard let helper else { throw ProcessTerminationError.helperRequired }
        let issued = try authorization.issue()
        defer { withExtendedLifetime(issued) {} }
        try await helper.setTaskProcessPriority(pid: process.pid, executablePath: process.executablePath,
                                                startTime: process.startTime, priority: request.priority,
                                                authorization: issued.externalForm)
    }
}

/// Ergebnis einer Prioritätsänderung.
public struct TaskPriorityResult: Hashable, Sendable {
    public let request: TaskPriorityRequest
    public let outcome: ActionOutcome

    public init(request: TaskPriorityRequest, outcome: ActionOutcome) {
        self.request = request
        self.outcome = outcome
    }

    var record: TaskActionRecord {
        TaskActionRecord(action: .setPriority(request.priority),
                         processName: ProcessTerminationPolicy.displayName(of: request.process.executablePath),
                         pid: request.process.pid, userName: UserAccount.shortName(of: request.process.uid),
                         outcome: outcome.failureMessage.map { .failed($0) } ?? .done)
    }
}

extension ActionOutcome {
    /// Meldung eines gescheiterten Ergebnisses, sonst `nil`.
    var failureMessage: String? {
        if case .failed(let message) = self { message } else { nil }
    }
}

extension ActionRunner {
    /// „Priorität“ im Task-Manager: wie jede Aktion höchstens eine zur Zeit; Ergebnis im Kontext `.taskManager`.
    @discardableResult
    public func setPriority(_ request: TaskPriorityRequest, using setter: any TaskPrioritySetting,
                            context: ActionContext = .taskManager) async -> TaskPriorityResult? {
        var finished: TaskPriorityResult?
        await run(recordID: request.id, context: context,
                  unavailable: { TaskPriorityResult(request: request, outcome: .failed(Self.unavailableMessage)) }) { _ in
            do {
                try await setter.setPriority(request)
                return TaskPriorityResult(request: request, outcome: .done)
            } catch {
                return TaskPriorityResult(request: request, outcome: .failed(error.readableDescription))
            }
        } present: { result in
            finished = result
            return .taskPriority(result)
        }
        return finished
    }
}

/// „Priorität“ im Task-Manager (TM-9.3): Menü an der Aktionsleiste → Bestätigung → setzen; jede Änderung kommt in den
/// Verlauf. Nur für **einen** Prozess (bei Apps mit mehreren Prozessen je Prozess).
@MainActor
@Observable
public final class TaskPriorityFlow {
    static let singleProcessOnly = "Die Priorität lässt sich nur je Prozess ändern – App aufklappen und Prozess wählen."

    /// Rückfrage für das Bestätigungsblatt; das Blatt setzt sie beim Schließen zurück.
    public var pendingRequest: TaskPriorityRequest?
    public private(set) var notice: String?

    private let actions: ActionRunner
    private let setter: any TaskPrioritySetting
    private let inspector: any ProcessInspecting
    private let niceValues: any ProcessPrioritySetting
    private let log: (any TaskActionLogging)?
    private let now: @Sendable () -> Date

    public init(actions: ActionRunner, setter: any TaskPrioritySetting,
                inspector: any ProcessInspecting = LibprocProcessInspector(),
                niceValues: any ProcessPrioritySetting = PosixPrioritySetter(), log: (any TaskActionLogging)? = nil,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.actions = actions
        self.setter = setter
        self.inspector = inspector
        self.niceValues = niceValues
        self.log = log
        self.now = now
    }

    public var canStart: Bool { actions.canStart && !actions.isRunning }

    /// Aktuelle Stufe eines Prozesses für das Menü (nächstgelegene); `nil`, wenn nicht lesbar.
    public func currentPriority(of key: ProcessKey) -> ProcessPriority? {
        niceValues.niceValue(of: key.pid).map(ProcessPriority.init(nearest:))
    }

    /// Prozess frisch lesen (PID **und** Startzeit) und die Rückfrage öffnen.
    public func prepare(_ candidate: TaskTerminationCandidate, priority: ProcessPriority) {
        guard canStart else { return }
        notice = nil
        guard candidate.keys.count == 1, let key = candidate.keys.first else {
            notice = Self.singleProcessOnly
            return
        }
        guard let process = inspector.process(key.pid), process.startTime == key.startTime else {
            notice = TaskTerminationFlow.notRunning
            return
        }
        if let protected = ProtectedProcesses.system.notice(forAny: [process]) {
            notice = protected
            return
        }
        pendingRequest = TaskPriorityRequest(name: candidate.name, process: process, priority: priority,
                                             currentNice: niceValues.niceValue(of: process.pid))
    }

    /// Wie bei „Task beenden“ geht auch ein Auftrag mit einem Programm der Schutzliste nicht hinaus, der nicht aus
    /// `prepare` stammt.
    public func confirm(_ request: TaskPriorityRequest) async {
        if let protected = ProtectedProcesses.system.notice(forAny: [request.process]) {
            notice = protected
            return
        }
        guard let result = await actions.setPriority(request, using: setter) else { return }
        await TaskActionHistory.record(result.record, in: log, at: now())
    }

    public func dismissNotice() {
        notice = nil
    }
}
