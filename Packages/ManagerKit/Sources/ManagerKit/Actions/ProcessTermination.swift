import Foundation

/// Was „Prozess beenden …“ treffen soll: der Lauscher und seine beim Klick frisch ermittelten Prozesse (Spec §2).
public struct ProcessTerminationRequest: Hashable, Sendable, Identifiable {
    public let listener: NetworkListener
    /// Nach PID sortiert, jede PID einmal.
    public let processes: [RunningProcess]

    public init(listener: NetworkListener, processes: [RunningProcess]) {
        self.listener = listener
        self.processes = processes
    }

    /// `NetworkListener.id` – auch `ActionRunner.runningRecordID`.
    public var id: String { listener.id }
}

/// Fehler von „Prozess beenden …“ außerhalb der Prüfungen (`ProcessTerminationViolation`).
public enum ProcessTerminationError: LocalizedError, Equatable {
    /// Prozess eines anderen Benutzers, aber kein Helper-Zugang.
    case helperRequired
    /// Kein Prozess wurde beendet; Meldung des ersten Fehlers.
    case notTerminated(String)

    public var errorDescription: String? {
        switch self {
        case .helperRequired: "Prozesse anderer Benutzer beendet nur der Helper – er ist nicht bereit (Einstellungen)"
        case .notTerminated(let message): "Prozess nicht beendet: \(message)"
        }
    }
}

/// Ein Prozess, an den kein Signal ging; `message` ist die lesbare Meldung.
public struct ProcessTerminationFailure: Hashable, Sendable {
    public let process: RunningProcess
    public let message: String

    public init(process: RunningProcess, message: String) {
        self.process = process
        self.message = message
    }
}

/// Wie das Beenden ausging.
public struct ProcessTerminationReport: Hashable, Sendable {
    public var ended: [RunningProcess]
    /// Signal zugestellt, Prozess läuft nach der Wartezeit noch.
    public var stillRunning: [RunningProcess]
    public var failures: [ProcessTerminationFailure]

    public init(ended: [RunningProcess] = [], stillRunning: [RunningProcess] = [], failures: [ProcessTerminationFailure] = []) {
        self.ended = ended
        self.stillRunning = stillRunning
        self.failures = failures
    }

    /// Kein Prozess läuft mehr, und kein Signal scheiterte.
    public var allEnded: Bool { stillRunning.isEmpty && failures.isEmpty }
}

/// Ergebnis von `ActionCoordinator.terminate(_:force:)`.
public struct ProcessTerminationResult: Hashable, Sendable {
    public let request: ProcessTerminationRequest
    public let force: Bool
    public let outcome: ActionOutcome
    public let report: ProcessTerminationReport

    public init(request: ProcessTerminationRequest, force: Bool, outcome: ActionOutcome, report: ProcessTerminationReport) {
        self.request = request
        self.force = force
        self.outcome = outcome
        self.report = report
    }

    /// „Sofort beenden (SIGKILL) …“ für die Überlebenden eines SIGTERM (Spec §6.5); nach SIGKILL nie.
    public var forceRequest: ProcessTerminationRequest? {
        guard !force, !report.stillRunning.isEmpty else { return nil }
        return ProcessTerminationRequest(listener: request.listener, processes: report.stillRunning)
    }

    /// Ohne Coordinator (Überwachung nicht verfügbar).
    @MainActor static func unavailable(_ request: ProcessTerminationRequest, force: Bool) -> Self {
        Self(request: request, force: force, outcome: .failed(ActionRunner.unavailableMessage), report: ProcessTerminationReport())
    }
}
