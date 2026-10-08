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
        let details = result.report.failures.map { "PID \($0.process.pid): \($0.message)" }
            + result.report.stillRunning.map { "PID \($0.pid) läuft noch" }
        return ActionOutcomePresentation(text: base.text + hint, tone: base.tone, settingsURL: base.settingsURL, details: details)
    }
}
