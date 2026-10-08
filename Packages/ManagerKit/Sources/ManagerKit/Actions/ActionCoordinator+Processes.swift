import Foundation
import Synchronization

/// „Prozess beenden …“ (#128, Spec §6) – eingereiht wie jede Aktion; danach Prüfscan der Quelle `networkListeners`.
extension ActionCoordinator {
    static let listenerRestarted =
        "Beendet, der Dienst läuft aber wieder – vermutlich hat ihn sein Autostart-Eintrag oder die App neu gestartet."

    /// Sendet SIGTERM (mit `force` SIGKILL) und wartet bis 5 s auf das Ende; bestätigt, wenn der Lauscher im neuen
    /// Snapshot fehlt. Laufen Prozesse weiter, ist das Ergebnis ein Hinweis, und `forceRequest` bietet SIGKILL an.
    /// Wurde kein Prozess beendet (`ProcessTerminationError.notTerminated`), bleibt es beim Fehler, auch wenn der
    /// Lauscher im neuen Scan zufällig fehlt – das war dann nicht die Aktion.
    public func terminate(_ request: ProcessTerminationRequest, force: Bool) async -> ProcessTerminationResult {
        let captured = CapturedReport()
        var check = Check(source: .networkListeners, unconfirmed: .doneButUnverified(Self.listenerRestarted)) { snapshot in
            !snapshot.networkListeners.contains { $0.id == request.listener.id }
        }
        check.failureRulesOutEffect = Self.terminationFailureRulesOutEffect
        let outcome = await perform(check) { [processTermination] in
            let report = await processTermination.terminate(request, force: force)
            captured.set(report)
            return try Self.warning(after: report, force: force)
        }
        return ProcessTerminationResult(request: request, force: force, outcome: outcome, report: captured.value)
    }

    /// Kein Prozess wurde beendet (`notTerminated`): Jedes Signal scheiterte, und der `ProcessTerminator` sah keinen
    /// der Prozesse danach verschwinden (auch nicht bei unsicherer Zustellung) – ein fehlender Lauscher ist dann Zufall.
    static func terminationFailureRulesOutEffect(_ error: any Error) -> Bool {
        guard case .notTerminated = error as? ProcessTerminationError else { return false }
        return true
    }

    /// `nil`, wenn alle beendet sind; sonst der Hinweis. Wirft, wenn kein Prozess beendet wurde.
    static func warning(after report: ProcessTerminationReport, force: Bool) throws -> String? {
        if !report.stillRunning.isEmpty {
            let running = report.stillRunning.count == 1 ? "1 Prozess läuft" : "\(report.stillRunning.count) Prozesse laufen"
            return force ? "\(running) auch nach dem sofortigen Beenden noch." : "\(running) noch."
        }
        guard let first = report.failures.first else { return nil }
        guard !report.ended.isEmpty else { throw ProcessTerminationError.notTerminated(first.message) }
        return "Nicht alle Prozesse ließen sich beenden."
    }
}

/// Bericht aus der eingereihten Aktion (Referenztyp, weil die Aktion als `@Sendable`-Closure läuft).
private final class CapturedReport: Sendable {
    private let report = Mutex(ProcessTerminationReport())

    var value: ProcessTerminationReport { report.withLock { $0 } }

    func set(_ value: ProcessTerminationReport) { report.withLock { $0 = value } }
}
