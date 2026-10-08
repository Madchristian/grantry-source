import Foundation

/// Inline-Meldung zum Ergebnis einer Aktion: Text, semantische Farbe und ggf. ein Deeplink in die Systemeinstellungen.
public struct ActionOutcomePresentation: Hashable, Sendable {
    public let text: String
    public let tone: PresentationTone
    /// Passende Seite der Systemeinstellungen, wenn die Wirkung dort zu prüfen oder nachzuholen ist.
    public let settingsURL: URL?
    /// Einzelne Zeilen unter der Meldung (z. B. was beim Entfernen nicht gelang, mit Grund); höchstens
    /// `maximumDetails` plus eine Zeile „… und n weitere“.
    public let details: [String]

    /// Höchstzahl der Detailzeilen – die Meldung darf das Fenster nicht sprengen (Leitplanke 4).
    public static let maximumDetails = 8

    public var systemImage: String { tone.systemImage }

    /// - Parameter successMessage: Text für `.done`; die übrigen Fälle bringen ihren Text selbst mit.
    public init(_ outcome: ActionOutcome, successMessage: String) {
        switch outcome {
        case .done:
            (text, tone, settingsURL) = (successMessage, .positive, nil)
        case .doneButUnverified(let reason, let url):
            (text, tone, settingsURL) = (reason, .warning, url)
        case .failed(let message):
            (text, tone, settingsURL) = (message, .critical, nil)
        }
        details = []
    }

    init(text: String, tone: PresentationTone, settingsURL: URL?, details: [String]) {
        self.text = text
        self.tone = tone
        self.settingsURL = settingsURL
        self.details = details.count > Self.maximumDetails
            ? Array(details.prefix(Self.maximumDetails)) + ["… und \(details.count - Self.maximumDetails) weitere"]
            : details
    }

    /// Aktion abgebrochen, um den nicht erreichbaren Helper neu zu installieren (`ActionRunner.abandonRunningAction()`).
    public static let abandoned = ActionOutcomePresentation(
        text: "Abgebrochen, um den Helper neu zu installieren. Ob die Aktion noch gewirkt hat, zeigt der nächste Scan.",
        tone: .warning, settingsURL: nil, details: []
    )

    /// Ergebnis von `ActionCoordinator.reset(_:)`.
    public static func reset(_ grant: PermissionGrant, outcome: ActionOutcome) -> ActionOutcomePresentation {
        let service = PermissionCatalog.service(for: grant.service).displayName
        return ActionOutcomePresentation(
            outcome, successMessage: "\(service)-Berechtigung von \(grant.client.displayName) wurde zurückgesetzt."
        )
    }

    /// Ergebnis von `ActionCoordinator.resetService(_:)`; nach Erfolg mit Link zur Seite in den Systemeinstellungen, wenn
    /// installierte Apps neu zu erlauben sind.
    public static func resetService(_ reset: ServiceReset, outcome: ActionOutcome) -> ActionOutcomePresentation {
        let service = reset.serviceName
        guard outcome == .done, !reset.collateral.isEmpty else {
            return ActionOutcomePresentation(outcome, successMessage: "\(service) wurde zurückgesetzt – die Einträge entfernter Apps sind weg.")
        }
        return ActionOutcomePresentation(
            text: "\(service) wurde für alle Apps zurückgesetzt. Erlaube installierte Apps bei Bedarf neu.",
            tone: .positive, settingsURL: PermissionCatalog.service(for: reset.service).settingsURL, details: []
        )
    }

    /// Ergebnis von `ActionCoordinator.perform(_:)` für eine Sicherheitsaktion.
    public static func security(_ action: SecurityAction, outcome: ActionOutcome) -> ActionOutcomePresentation {
        ActionOutcomePresentation(outcome, successMessage: action.successMessage)
    }
}

extension SecurityAction {
    /// Text nach bestätigter Wirkung.
    public var successMessage: String {
        switch self {
        case .enableFirewall: "Die Firewall ist eingeschaltet."
        case .enableStealthMode: "Der Tarnmodus ist eingeschaltet."
        case .enableGatekeeper: "Gatekeeper ist eingeschaltet."
        case .enableAutomaticUpdates: "Automatische Updates sind eingeschaltet."
        case .updateXProtect: "XProtect ist aktuell."
        case .checkForUpdates: "Die Suche nach Updates ist abgeschlossen."
        }
    }
}
