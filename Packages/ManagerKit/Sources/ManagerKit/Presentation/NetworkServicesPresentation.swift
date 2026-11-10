import Foundation

/// Stand der Ansicht Netzwerk › Dienste im Lagebild (#366): Zeilen nach Filter und Suche (`NetworkListenerPresenter`),
/// Zählungen für die Kacheln und das Urteil der Zustandszeile.
public struct NetworkServicesPresentation: Hashable, Sendable {
    /// Lauscher je Erreichbarkeit; Systemdienste nur mit „Systemdienste anzeigen“, Suche und übrige Filter zählen nicht.
    public struct Counts: Hashable, Sendable {
        public let total: Int
        /// Von außen erreichbare Dienste ohne vermutliche Clients (`NetworkListener.isExposedService`).
        public let exposed: Int
        /// Davon Systemdienste (nur mit „Systemdienste anzeigen“); die übrigen sind `ownExposedCount`.
        public let exposedSystem: Int
        public let thisMac: Int
        /// Lauscher mit mindestens einem Befund.
        public let withFindings: Int

        public init(total: Int, exposed: Int, exposedSystem: Int, thisMac: Int, withFindings: Int) {
            self.total = total
            self.exposed = exposed
            self.exposedSystem = exposedSystem
            self.thisMac = thisMac
            self.withFindings = withFindings
        }
    }

    public let rows: [NetworkListenerRow]
    public let counts: Counts
    /// Von außen erreichbare Dienste, die nicht von macOS stammen (`NetworkListener.countsAsExposed`) – dieselben, zu
    /// denen `ExposedListenerRule` Befunde liefert, und dieselbe Zahl wie `NetworkOverview.exposedCount`. Zustandszeile,
    /// Kachel und Firewall-Hinweis nennen nur diese Zahl.
    public let ownExposedCount: Int
    public let showsSystemServices: Bool

    public static let empty = NetworkServicesPresentation(listeners: [], severity: { _ in nil }, query: "",
                                                          filter: NetworkListenerFilter())

    /// - Parameter severity: höchster Schweregrad der Befunde zu einer Lauscher-ID.
    public init(listeners: [NetworkListener], severity: (String) -> RiskFinding.Severity?, query: String,
                filter: NetworkListenerFilter) {
        let visible = listeners.filter { filter.showsSystemServices || !$0.isAppleService }
        rows = NetworkListenerPresenter.rows(listeners, severity: severity, query: query, filter: filter)
        let exposed = visible.filter(\.isExposedService)
        counts = Counts(total: visible.count, exposed: exposed.count, exposedSystem: exposed.count(where: \.isAppleService),
                        thisMac: visible.count { $0.reachability == .thisMac },
                        withFindings: visible.count { severity($0.id) != nil })
        ownExposedCount = listeners.count(where: \.countsAsExposed)
        showsSystemServices = filter.showsSystemServices
    }

    /// Urteil für die Zustandszeile: Eigene, aus dem Netz erreichbare Dienste und eine ausgeschaltete Firewall sind ein
    /// Befund; Systemdienste und vermutliche Clients nicht.
    public func verdict(firewallHint: NetworkFirewallHint?) -> SystemVerdict {
        let title = switch ownExposedCount {
        case 0: counts.total == 0
            ? String(localized: "Keine Netzwerkdienste") : String(localized: "Kein Dienst aus dem Netz erreichbar")
        case 1: String(localized: "1 Dienst aus dem Netz erreichbar")
        default: String(localized: "\(ownExposedCount) Dienste aus dem Netz erreichbar")
        }
        var items: [SystemVerdict.Item] = []
        var firewallOff = false
        switch firewallHint {
        case .firewallOn: items.append(SystemVerdict.Item(text: String(localized: "Firewall an"), tone: .positive))
        case .firewallOff:
            firewallOff = true
            items.append(SystemVerdict.Item(text: String(localized: "Firewall aus"), tone: .warning))
        case nil: break
        }
        switch counts.withFindings {
        case 0: break
        case 1: items.append(SystemVerdict.Item(text: String(localized: "1 Dienst mit Hinweis"), tone: .warning))
        default:
            items.append(SystemVerdict.Item(text: String(localized: "\(counts.withFindings) Dienste mit Hinweis"),
                                            tone: .warning))
        }
        let services = counts.total == 1 ? String(localized: "1 Dienst") : String(localized: "\(counts.total) Dienste")
        let visibility = showsSystemServices
            ? String(localized: "mit Systemdiensten") : String(localized: "Systemdienste ausgeblendet")
        return SystemVerdict(level: ownExposedCount > 0 || firewallOff ? .finding : .calm, title: title, reason: "",
                             items: items, processFindings: [], facts: "\(services) · \(visibility)")
    }
}
