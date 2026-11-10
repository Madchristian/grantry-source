import GrantryCharts
import ManagerKit
import SwiftUI

/// Was Detail und Kontextmenü für „Prozess beenden …“ brauchen (fehlt in Previews).
@MainActor
struct ListenerTerminationControls {
    let flow: ProcessTerminationFlow
    let actions: ActionRunner
    let availability: ActionAvailability

    /// Grund der Sperre laut `ListenerTerminationPolicy`, für Tooltip und Hinweis.
    var disabledReason: String? {
        if case .readOnly(let reason) = availability { reason.description } else { nil }
    }

    var canStart: Bool { availability == .available && actions.canStart && flow.preparingListenerID == nil }

    func isBusy(_ listener: NetworkListener) -> Bool {
        flow.preparingListenerID == listener.id || actions.runningRecordID == listener.id
    }

    /// SIGKILL-Angebot nur, solange die Aktion laut Policy verfügbar ist (etwa der Helper für fremde Prozesse bereit).
    func offersForce(for listener: NetworkListener) -> Bool {
        availability == .available && flow.forceOffer?.listener.id == listener.id
    }

    func notice(for listener: NetworkListener) -> String? {
        flow.notice.flatMap { $0.listenerID == listener.id ? $0.text : nil }
    }

    func prepare(_ listener: NetworkListener) {
        Task { await flow.prepare(listener) }
    }
}

/// „Prozess beenden …“, nach einem SIGTERM mit Überlebenden „Sofort beenden (SIGKILL) …“ (zweite Bestätigung), dazu
/// `extra` (weitere Knöpfe derselben Zeile). Ein gesperrter Knopf nennt den Grund (`ListenerTerminationPolicy`) als
/// Tooltip und darunter. Gemeinsam für das Detail eines Dienstes und einer Verbindung.
struct ListenerTerminationActions<Extra: View>: View {
    let listener: NetworkListener
    let termination: ListenerTerminationControls
    @ViewBuilder let extra: Extra

    init(listener: NetworkListener, termination: ListenerTerminationControls,
         @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.listener = listener
        self.termination = termination
        self.extra = extra()
    }

    var body: some View {
        HStack(spacing: InstrumentSpacing.group) {
            Button("Prozess beenden …", role: .destructive) { termination.prepare(listener) }
                .disabled(!termination.canStart)
                .help(termination.disabledReason ?? String(localized: "Beendet den Prozess nach Bestätigung (SIGTERM)."))
            if termination.offersForce(for: listener) {
                Button("Sofort beenden (SIGKILL) …", role: .destructive) { termination.flow.offerForce() }
                    .disabled(!termination.actions.canStart)
            }
            extra
            if termination.isBusy(listener) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Aktion läuft")
            }
        }
        if let reason = termination.disabledReason {
            NetworkNote(text: reason, kind: .locked)
        }
        if let notice = termination.notice(for: listener) {
            NetworkNote(text: notice)
        }
    }
}
