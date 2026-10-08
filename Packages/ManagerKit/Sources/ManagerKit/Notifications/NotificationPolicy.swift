/// Welche Änderungen eine Benachrichtigung auslösen (alle landen im Verlauf). Berechtigungen und Autostart wie in v1
/// immer; Sicherheitsprüfungen nur bei Verschlechterung der Ampel (nach `effectiveState`, also auch über einen Ausfall
/// hinweg) oder einem Wechsel der MDM-Anmeldung (Spec v2 §3). Neue oder entfernte Prüfungen melden sich nicht.
/// Netzwerkdienste je Einstellung (`ListenerNotificationSetting`): neue Lauscher bei „alle“ immer, bei „nur von außen
/// erreichbare“ nur solche; ein Wechsel auf „von außen erreichbar“ außer bei „aus“; beendete, Dienste von macOS
/// (`NetworkListener.isAppleService`; Interpreter und Netzwerkwerkzeuge zählen nie dazu) und vermutliche Clients
/// (`NetworkListener.isBenignClientUDP`) nie.
public struct NotificationPolicy: Sendable {
    private let listenerSetting: @Sendable () -> ListenerNotificationSetting

    /// - Parameter listenerSetting: wird je Event gelesen, damit eine geänderte Einstellung sofort gilt.
    public init(listenerSetting: @escaping @Sendable () -> ListenerNotificationSetting = { .exposedOnly }) {
        self.listenerSetting = listenerSetting
    }

    public func shouldNotify(_ event: ChangeEvent) -> Bool {
        switch event.subject {
        case .securityCheck(let after): shouldNotify(event, check: after)
        case .networkListener(let after): shouldNotify(event, listener: after)
        case .grant, .autostartItem, .installedApp, .mcpServer, .agentAutoApproval: true
        }
    }

    private func shouldNotify(_ event: ChangeEvent, check after: SecurityCheck) -> Bool {
        guard event.kind == .modified, case .securityCheck(let before)? = event.before else { return false }
        if after.kind == .mdmEnrollment {
            guard case .mdmEnrollment(let wasEnrolled, _)? = before.facts,
                  case .mdmEnrollment(let isEnrolled, _)? = after.facts else { return false }
            return wasEnrolled != isEnrolled
        }
        guard let old = before.effectiveState, let new = after.effectiveState else { return false }
        return new.isDeterioration(from: old)
    }

    private func shouldNotify(_ event: ChangeEvent, listener after: NetworkListener) -> Bool {
        let setting = listenerSetting()
        guard setting != .off, !after.isAppleService, !after.isBenignClientUDP else { return false }
        switch event.kind {
        case .added: return setting == .all || after.reachability.isExposed
        case .modified:
            guard case .networkListener(let before)? = event.before else { return false }
            return after.reachability.isExposed && !before.reachability.isExposed
        case .removed: return false
        }
    }
}
