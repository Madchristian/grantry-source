import Foundation
import GrantryShared

/// Befehle des Task-Managers (TM9, Plan „Helper-Entwurf“). Jede verändernde Aktion: Vorprüfung mit `taskPolicy`,
/// Admin-Bestätigung je Aktion (`authorizer`, Dialogtext aus der eigenen Lesung), Nachprüfung auf **dieselbe**
/// Prozessgeneration, dann die Wirkung – alles eingereiht in `taskQueue` und innerhalb von `taskRequestLifetime` ab
/// Eingang. Meldungen und Log nennen nur PID, Programmname laut Inspektor und Benutzer.
extension HelperService {
    /// Längste Zeit vom Eingang bis zur Wirkung, Dialog eingeschlossen. Unter der Frist des Clients
    /// (`HelperClient.taskActionTimeout`, 150 s): Hat der Client aufgegeben, handelt der Helper sicher nicht mehr.
    static let taskRequestLifetime: Duration = .seconds(120)

    /// Frist eines `powermetrics`-Laufs (Messfenster 500 ms).
    static let sensorTimeout: Duration = .seconds(5)

    /// Eine verändernde Task-Manager-Aktion.
    enum TaskAction: Sendable {
        case terminate(TerminationSignal)
        case priority(ProcessPriority)

        /// Eigene Prozesse beendet die App ohne Helper; eine Priorität darf auch eigene betreffen (Erhöhen braucht root).
        var excludesCaller: Bool {
            if case .terminate = self { true } else { false }
        }

        /// Satzende des Dialogtexts.
        var promptText: String {
            switch self {
            case .terminate(.terminate): "beenden"
            case .terminate(.kill): "sofort beenden (SIGKILL)"
            case .priority(let priority): "auf Priorität „\(priority.title)“ setzen"
            }
        }

        var logText: String {
            switch self {
            case .terminate(let signal): signal.rawValue
            case .priority(let priority): "Priorität \(priority.rawValue)"
            }
        }
    }

    public func terminateTaskProcess(
        pid: Int32, executablePath: String, startTime: UInt64, force: Bool, authorization: Data,
        reply: @escaping @Sendable (String?) -> Void
    ) {
        performTaskAction(.terminate(TerminationSignal(force: force)), pid: pid, executablePath: executablePath,
                          startTime: startTime, authorization: authorization, reply: reply)
    }

    public func setTaskProcessPriority(
        pid: Int32, executablePath: String, startTime: UInt64, priority: Int32, authorization: Data,
        reply: @escaping @Sendable (String?) -> Void
    ) {
        guard let allowed = ProcessPriority(rawValue: priority) else {
            Self.logger.error("Priorität \(priority, privacy: .public) für PID \(pid, privacy: .public) abgelehnt")
            return reply(TaskActionViolation.priorityNotAllowed(priority).readableDescription)
        }
        performTaskAction(.priority(allowed), pid: pid, executablePath: executablePath, startTime: startTime,
                          authorization: authorization, reply: reply)
    }

    /// Aufrufer und Stoppuhr synchron im XPC-Aufruf; alles Weitere eingereiht. Ohne Aufrufer fail-closed.
    private func performTaskAction(
        _ action: TaskAction, pid: Int32, executablePath: String, startTime: UInt64, authorization: Data,
        reply: @escaping @Sendable (String?) -> Void
    ) {
        let callerPID = callerPID(), callerUID = callerUID()
        let waited = startStopwatch()
        taskQueue.enqueue { [self] in
            let subject = "\(action.logText) für PID \(pid)"
            func ensureWithinLifetime() throws(ProcessTerminationViolation) {
                guard waited() <= Self.taskRequestLifetime else { throw .requestExpired(pid) }
            }
            /// Prüfung mit Exitnachweis: `nil` heißt nachweislich beendet.
            func check() throws -> RunningProcess? {
                guard let callerPID, let callerUID else { throw ProcessTerminationViolation.callerUnknown }
                let target = try taskPolicy.validate(
                    pid: pid, executablePath: executablePath, excludingUID: action.excludesCaller ? callerUID : nil,
                    startTime: startTime, callerPID: callerPID
                )
                guard case .running(let process) = target else { return nil }
                guard process.auditToken != nil else { throw ProcessTerminationViolation.identityUnknown(pid) }
                return process
            }
            do {
                try TaskActionViolation.validateAuthorization(authorization)
                try ensureWithinLifetime()
                guard let process = try check() else { return try finishGone(action, pid: pid, subject, reply) }
                let user = userName(process.uid)
                let name = ProcessTerminationPolicy.displayName(of: process.executablePath)
                try await AdminAuthorization.confirm(
                    authorization, prompt: AdminAuthorization.prompt(action.promptText, process: process, userName: user),
                    with: authorizer
                )
                try ensureWithinLifetime()
                guard let confirmed = try check() else { return try finishGone(action, pid: pid, subject, reply) }
                guard confirmed == process else { throw ProcessTerminationViolation.processChanged(pid) }
                try ensureWithinLifetime()
                try apply(action, to: confirmed)
                Self.logger.notice("\(subject, privacy: .public) (\(name, privacy: .public), Benutzer \(user, privacy: .public)): erledigt")
                reply(nil)
            } catch {
                Self.logger.error("\(subject, privacy: .public) abgelehnt/fehlgeschlagen: \(error.readableDescription, privacy: .public)")
                reply(error.readableDescription)
            }
        }
    }

    /// Beendet: Erfolg ohne Dialog; Priorität: Fehler.
    private func finishGone(
        _ action: TaskAction, pid: Int32, _ subject: String, _ reply: @Sendable (String?) -> Void
    ) throws {
        if case .priority = action { throw TaskActionViolation.processGone(pid) }
        Self.logger.notice("\(subject, privacy: .public) unnötig, bereits beendet")
        reply(nil)
    }

    private func apply(_ action: TaskAction, to process: RunningProcess) throws {
        switch action {
        case .terminate(let signal): _ = try processSignaler.send(signal, to: process)
        case .priority(let priority): try prioritySetter.setPriority(priority, of: process)
        }
    }

    // MARK: - Sensoren (TM-9.4)

    /// Ein `powermetrics`-Lauf mit fester Kommandozeile, eingereiht in `sensorQueue`. Erfolg wird nicht protokolliert
    /// (die App fragt alle 2 s), Fehler schon.
    public func readSensors(reply: @escaping @Sendable (Data?, String?) -> Void) {
        sensorQueue.enqueue { [runner] in
            do {
                // Begrenzt schon das Lesen (#355): Mehr als ein Dokument verwürfe der Parser ohnehin.
                let result = try await runner.run(PowerMetricsParser.executable, PowerMetricsParser.arguments,
                                                  timeout: Self.sensorTimeout,
                                                  outputLimit: PowerMetricsParser.maximumDocumentBytes)
                guard result.succeeded else { return reply(nil, Self.failure("powermetrics", result)) }
                let reading = try PowerMetricsParser.parse(Data(result.stdout.utf8))
                reply(try JSONEncoder().encode(reading), nil)
            } catch {
                Self.logger.error("Sensoren nicht lesbar: \(error.readableDescription, privacy: .public)")
                reply(nil, error.readableDescription)
            }
        }
    }
}
