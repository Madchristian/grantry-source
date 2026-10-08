/// Deutsche Darstellung eines `HelperState`: Text, semantische Farbe und angebotene Aktion.
public struct HelperStatePresentation: Hashable, Sendable {
    /// Aktion, die für einen Helper-Zustand angeboten wird.
    public enum Action: String, Hashable, Sendable {
        /// Helper registrieren (`HelperManager.register()`).
        case install
        /// *Anmeldeobjekte & Erweiterungen* öffnen (`HelperManager.openApprovalSettings()`).
        case approve
        /// Helper neu registrieren (`HelperManager.reinstall()`).
        case reinstall

        /// Deutsche Schaltflächenbeschriftung.
        public var title: String {
            switch self {
            case .install: "Installieren"
            case .approve: "Genehmigen"
            case .reinstall: "Neu installieren"
            }
        }
    }

    public let text: String
    public let tone: PresentationTone
    /// `nil`, wenn keine Aktion sinnvoll ist (bereit, fehlt im Bundle, keine Administratorrechte).
    public let action: Action?

    /// SF Symbol passend zur Farbe.
    public var systemImage: String { tone.systemImage }

    public init(_ state: HelperState) {
        switch state {
        case .ready:
            (text, tone, action) = ("Bereit", .positive, nil)
        case .notInstalled:
            (text, tone, action) = ("Nicht installiert", .critical, .install)
        case .awaitingApproval:
            (text, tone, action) = ("Wartet auf Genehmigung unter „Anmeldeobjekte & Erweiterungen“", .warning, .approve)
        case .outdated(let installed, let expected):
            (text, tone, action) = ("Veraltet (Protokollversion \(installed), erwartet \(expected))", .warning, .reinstall)
        case .unreachable(let reason):
            (text, tone, action) = ("Nicht erreichbar: \(reason)", .critical, .reinstall)
        case .missingFromBundle:
            (text, tone, action) = ("Fehlt im App-Bundle", .critical, nil)
        case .requiresAdministrator:
            (text, tone, action) = ("Administratorrechte erforderlich", .critical, nil)
        }
    }
}
