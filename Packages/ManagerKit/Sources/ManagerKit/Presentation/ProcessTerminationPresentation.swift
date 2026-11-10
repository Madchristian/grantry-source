import Foundation

extension ActionOutcomePresentation {
    /// Ergebnis von „Prozess beenden …“: je PID, was scheiterte bzw. noch läuft; nach einem SIGTERM mit Überlebenden der
    /// Hinweis auf „Sofort beenden (SIGKILL) …“ im Detail.
    public static func termination(_ result: ProcessTerminationResult) -> ActionOutcomePresentation {
        let name = NetworkListenerRow(result.request.listener).title
        let base = ActionOutcomePresentation(
            result.outcome, successMessage: result.force ? "„\(name)“ wurde sofort beendet." : "„\(name)“ wurde beendet."
        )
        let hint = result.forceRequest == nil ? "" : " „Sofort beenden (SIGKILL) …“ steht im Detail des Dienstes."
        return ActionOutcomePresentation(text: base.text + hint, tone: base.tone, settingsURL: base.settingsURL,
                                         details: terminationDetails(result.report))
    }

    /// Ergebnis von „Task beenden“ im Task-Manager; nach einem SIGTERM mit Überlebenden der Hinweis auf ⌥⌫.
    public static func taskTermination(_ result: TaskTerminationResult) -> ActionOutcomePresentation {
        let name = result.request.name
        let base = ActionOutcomePresentation(
            result.outcome, successMessage: result.force ? "„\(name)“ wurde sofort beendet." : "„\(name)“ wurde beendet."
        )
        let hint = result.forceRequest == nil ? "" : " „Sofort beenden“ (⌥⌫) steht bereit."
        return ActionOutcomePresentation(text: base.text + hint, tone: base.tone, settingsURL: base.settingsURL,
                                         details: terminationDetails(result.report))
    }

    /// Ergebnis einer Prioritätsänderung im Task-Manager (TM-9.3).
    public static func taskPriority(_ result: TaskPriorityResult) -> ActionOutcomePresentation {
        ActionOutcomePresentation(result.outcome, successMessage:
            "„\(result.request.name)“ läuft jetzt mit Priorität „\(result.request.priority.title)“.")
    }

    /// Je PID, was scheiterte bzw. noch läuft.
    private static func terminationDetails(_ report: ProcessTerminationReport) -> [String] {
        report.failures.map { "PID \($0.process.pid): \($0.message)" } + report.stillRunning.map { "PID \($0.pid) läuft noch" }
    }
}
