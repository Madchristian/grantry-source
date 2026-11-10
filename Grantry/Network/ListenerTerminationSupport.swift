import ManagerKit
import SwiftUI

// Anbindung an `AppModel`, getrennt von `ListenerTerminationControls`, damit die Ansichten des Bereichs Netzwerk ohne
// `AppModel` gehostet werden können (Snapshot-Tests, TM-11.7).

extension ListenerTerminationControls {
    private static let policy = ListenerTerminationPolicy()

    /// „Prozess beenden …“ für `listener`; gesperrt laut `ListenerTerminationPolicy`.
    init(for listener: NetworkListener, appModel: AppModel, helperState: HelperState?) {
        self.init(flow: appModel.processTermination, actions: appModel.actions,
                  availability: Self.policy.availability(for: listener, helperState: helperState))
    }
}

/// Rahmen für „Prozess beenden …“ in den Ansichten des Bereichs Netzwerk: Bestätigungsdialog und Abgleich mit den
/// Lauschern jedes neuen Snapshots (Hinweis bzw. SIGKILL-Angebot zu einem wieder gesehenen bzw. verschwundenen Lauscher
/// verfallen).
struct ListenerTerminationSupport: ViewModifier {
    let appModel: AppModel

    func body(content: Content) -> some View {
        @Bindable var termination = appModel.processTermination
        content
            .onChange(of: appModel.presentation?.network.listeners ?? []) { _, listeners in
                termination.reconcile(with: listeners)
            }
            .actionConfirmation(for: $termination.pendingStep, confirmation: \.confirmation) { step in
                Task { await termination.confirm(step) }
            }
    }
}
