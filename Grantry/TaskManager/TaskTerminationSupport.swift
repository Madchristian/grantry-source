import ManagerKit
import SwiftUI

/// „Task beenden“ und „Priorität“ für die Tabs „Prozesse“ und „Details“ (Spec 2026-11-06 §2, TM9), einmal für beide:
/// Ergebnis im Kontext `.taskManager`, Bestätigungsblätter über `TaskTerminationFlow` und `TaskPriorityFlow`, Tasten
/// ⌫/⌥⌫ nur in der Tabelle. Beide Abläufe führen ihren Hinweis selbst; hier zeigt sich immer nur der Hinweis der zuletzt
/// gewählten Aktion, sonst bliebe die Meldung einer früheren Wahl neben der nächsten Rückfrage stehen.
@MainActor
struct TaskManagerFlows {
    let termination: TaskTerminationFlow
    let priority: TaskPriorityFlow
    let actions: ActionRunner

    init(_ appModel: AppModel) {
        termination = appModel.taskTermination
        priority = appModel.taskPriority
        actions = appModel.actions
    }

    var canStart: Bool { termination.canStart && priority.canStart }

    var notice: String? { termination.notice ?? priority.notice }

    func terminate(_ candidate: TaskTerminationCandidate, force: Bool) {
        priority.dismissNotice()
        termination.prepare(candidate, force: force)
    }

    func setPriority(_ level: ProcessPriority, of candidate: TaskTerminationCandidate) {
        termination.dismissNotice()
        priority.prepare(candidate, priority: level)
    }

    /// Aktuelle Stufe des gewählten Prozesses; `nil` bei keiner oder mehreren Prozessen oder wenn sie nicht lesbar ist.
    func currentPriority(of candidate: TaskTerminationCandidate?) -> ProcessPriority? {
        guard let candidate, candidate.keys.count == 1 else { return nil }
        return priority.currentPriority(of: candidate.keys[0])
    }
}

extension View {
    func taskManagerFlows(_ flows: TaskManagerFlows) -> some View {
        modifier(TaskManagerFlowsHost(termination: flows.termination, priority: flows.priority, actions: flows.actions))
    }

    /// ⌫ „Task beenden“, ⌥⌫ „Sofort beenden“ – über `onKeyPress` nur in der fokussierten Tabelle, nicht als
    /// Tastenkürzel, sonst löschte ⌫ im Suchfeld keinen Text mehr.
    func terminatesOnDelete(_ candidate: TaskTerminationCandidate?, using flows: TaskManagerFlows) -> some View {
        onKeyPress(.delete, phases: .down) { press in
            guard let candidate else { return .ignored }
            flows.terminate(candidate, force: press.modifiers.contains(.option))
            return .handled
        }
    }
}

extension ProcessActionBar {
    /// Leiste zur Auswahl eines Tabs; Hinweis, Sperre, Angebot „Sofort beenden“ und Priorität kommen aus `flows`.
    /// `needsAdmin`: Die Auswahl enthält Prozesse anderer Benutzer.
    init(candidate: TaskTerminationCandidate?, disabledReason: String?, needsAdmin: Bool = false,
         flows: TaskManagerFlows) {
        self.init(candidate: candidate, disabledReason: disabledReason, notice: flows.notice, canStart: flows.canStart,
                  forceOffer: flows.termination.forceOffer, needsAdmin: needsAdmin,
                  priority: flows.currentPriority(of: candidate),
                  prepare: { force in candidate.map { flows.terminate($0, force: force) } },
                  offerForce: flows.termination.offerForce,
                  setPriority: { level in candidate.map { flows.setPriority(level, of: $0) } })
    }
}

private struct TaskManagerFlowsHost: ViewModifier {
    @Bindable var termination: TaskTerminationFlow
    @Bindable var priority: TaskPriorityFlow
    let actions: ActionRunner

    func body(content: Content) -> some View {
        content
            .confirmedTaskManagerAction($termination.pendingStep, actions: actions, confirmation: \.confirmation) {
                await termination.confirm($0)
            }
            .actionConfirmation(for: $priority.pendingRequest, confirmation: { ActionConfirmation.setPriority($0) }) { request in
                Task { await priority.confirm(request) }
            }
    }
}

extension View {
    /// Rahmen der bestätigten Aktionen im Task-Manager („Task beenden“, Dienste starten und stoppen): Ergebnis im Kontext
    /// `.taskManager` über dem Inhalt, Bestätigungsblatt für den ausstehenden Schritt `pending`; `confirm` läuft erst
    /// nach der Bestätigung.
    func confirmedTaskManagerAction<Step: Sendable>(
        _ pending: Binding<Step?>, actions: ActionRunner, confirmation: @escaping (Step) -> ActionConfirmation,
        confirm: @escaping @MainActor (Step) async -> Void
    ) -> some View {
        ActionResultContainer(actions: actions, context: .taskManager) { self }
            .actionConfirmation(for: pending, confirmation: confirmation) { step in
                Task { await confirm(step) }
            }
    }
}
