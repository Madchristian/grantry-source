import Foundation
import Observation

/// Ablauf „Prozess beenden …“ für die Oberfläche (Spec §6): Prozesse frisch ermitteln → bestätigen (`pendingStep`) →
/// beenden über den `ActionRunner`; laufen danach noch Prozesse, bietet `forceOffer` die zweite Bestätigung für SIGKILL
/// an. Läuft der Dienst schon nicht mehr, steht ein Hinweis da, der Lauscher wird im `ListenerTerminationLedger`
/// vermerkt und `refresh` liest die Lauscher neu – so fällt er sofort aus der Liste, statt wegen der Entprellung 5 bzw.
/// 20 Minuten stehen zu bleiben. Gefahrlos: Der Vermerk verhindert nur das Fortschreiben, ein wieder gesehener
/// Lauscher bleibt sichtbar. Hinweis und Angebot gleicht
/// `reconcile(with:)` mit der aktuellen Liste ab, damit nichts Veraltetes stehen bleibt.
@MainActor
@Observable
public final class ProcessTerminationFlow {
    /// Ein zu bestätigender Schritt.
    public enum Step: Hashable, Identifiable, Sendable {
        case terminate(ProcessTerminationRequest)
        case forceTerminate(ProcessTerminationRequest)

        public var request: ProcessTerminationRequest {
            switch self {
            case .terminate(let request), .forceTerminate(let request): request
            }
        }

        public var isForce: Bool {
            if case .forceTerminate = self { true } else { false }
        }

        public var id: String { (isForce ? "kill:" : "term:") + request.id }

        public var confirmation: ActionConfirmation {
            isForce ? .forceTerminate(request) : .terminate(request)
        }
    }

    /// Hinweis zu einem Lauscher (etwa „läuft nicht mehr“).
    public struct Notice: Hashable, Sendable {
        public let listenerID: String
        public let text: String
        /// `NetworkListener.lastSeenAt` beim Hinweis: Ein späterer Wert heißt, der Lauscher wurde seither wieder
        /// gesehen – ein bloß fortgeschriebener (Entprellung) behält ihn.
        let lastSeenAt: Date

        init(_ listener: NetworkListener, text: String) {
            listenerID = listener.id
            self.text = text
            lastSeenAt = listener.lastSeenAt
        }
    }

    static let notRunning = "Der Dienst läuft nicht mehr."

    /// Schritt für das Bestätigungsblatt; das Blatt setzt ihn beim Schließen zurück.
    public var pendingStep: Step?
    /// Lauscher, dessen Prozesse gerade ermittelt werden.
    public private(set) var preparingListenerID: String?
    /// Überlebende des letzten SIGTERM: „Sofort beenden (SIGKILL) …“.
    public private(set) var forceOffer: ProcessTerminationRequest?
    public private(set) var notice: Notice?

    private let resolver: ListenerProcessResolver
    private let actions: ActionRunner
    private let ledger: ListenerTerminationLedger
    private let refresh: @MainActor () async -> Void
    private let now: @Sendable () -> Date

    /// - Parameter refresh: liest die Lauscher neu (Teilscan der Quelle `networkListeners`, Spec §6.4).
    public init(
        resolver: ListenerProcessResolver, actions: ActionRunner, ledger: ListenerTerminationLedger,
        refresh: @escaping @MainActor () async -> Void, now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.resolver = resolver
        self.actions = actions
        self.ledger = ledger
        self.refresh = refresh
        self.now = now
    }

    /// „Prozess beenden …“ geklickt: Prozesse frisch ermitteln, dann bestätigen lassen.
    public func prepare(_ listener: NetworkListener) async {
        guard preparingListenerID == nil, actions.canStart else { return }
        preparingListenerID = listener.id
        notice = nil
        forceOffer = nil
        defer { preparingListenerID = nil }
        do {
            let request = try await resolver.request(for: listener)
            if request.processes.isEmpty {
                notice = Notice(listener, text: Self.notRunning)
                ledger.record(listener.id, at: now())
                await refresh()
            } else {
                pendingStep = .terminate(request)
            }
        } catch {
            notice = Notice(listener, text: "Prozesse nicht ermittelbar: \(error.readableDescription)")
        }
    }

    /// Bestätigter Schritt: beenden; nach SIGTERM mit Überlebenden SIGKILL anbieten. Beginnt die Aktion nicht (es lief
    /// schon eine Aktion oder eine Helper-Installation), bleibt ein bestehendes Angebot erhalten.
    public func confirm(_ step: Step) async {
        guard let result = await actions.terminate(step.request, force: step.isForce) else { return }
        forceOffer = result.forceRequest
    }

    /// Abgleich mit der aktuellen Lauscher-Liste: Ein Hinweis verfällt, sobald sein Lauscher wieder gesehen wurde; das
    /// SIGKILL-Angebot, sobald sein Lauscher nicht mehr in der Liste steht.
    public func reconcile(with listeners: [NetworkListener]) {
        if let notice, let current = listeners.first(where: { $0.id == notice.listenerID }),
           current.lastSeenAt > notice.lastSeenAt {
            self.notice = nil
        }
        if let forceOffer, !listeners.contains(where: { $0.id == forceOffer.listener.id }) {
            self.forceOffer = nil
        }
    }

    /// „Sofort beenden (SIGKILL) …“ geklickt: zweite Bestätigung.
    public func offerForce() {
        guard let forceOffer else { return }
        pendingStep = .forceTerminate(forceOffer)
    }
}
