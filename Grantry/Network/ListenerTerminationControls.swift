import ManagerKit

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
