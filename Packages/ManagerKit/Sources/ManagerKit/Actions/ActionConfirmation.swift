import Foundation

/// Texte des Bestätigungsdialogs vor einer verändernden Aktion (Spec §5: jede Aktion wird bestätigt).
public struct ActionConfirmation: Hashable, Sendable {
    public let title: String
    public let message: String?
    /// Zusätzlicher, deutlich anzuzeigender Hinweis, z. B. dass Automation-Freigaben **aller** Ziele zurückgesetzt werden.
    public let note: String?
    public let confirmTitle: String
    /// Ob der Bestätigungsknopf als destruktiv dargestellt wird.
    public let isDestructive: Bool

    public init(title: String, message: String? = nil, note: String? = nil, confirmTitle: String, isDestructive: Bool) {
        self.title = title
        self.message = message
        self.note = note
        self.confirmTitle = confirmTitle
        self.isDestructive = isDestructive
    }
}

extension ActionConfirmation {
    /// Zurücksetzen per `tccutil`; bei Automation mit dem Hinweis, dass alle Ziele der App betroffen sind
    /// (siehe `PermissionActions`).
    public static func reset(_ grant: PermissionGrant) -> ActionConfirmation {
        let service = PermissionCatalog.service(for: grant.service).displayName
        return ActionConfirmation(
            title: "\(service)-Berechtigung von \(grant.client.displayName) zurücksetzen?",
            message: "Die App fragt beim nächsten Zugriff erneut nach.",
            note: grant.service == PermissionCatalog.automationServiceID ? "Setzt alle Automation-Freigaben dieser App zurück." : nil,
            confirmTitle: "Zurücksetzen",
            isDestructive: true
        )
    }

    /// Zurücksetzen eines Dienstes für alle Apps (`ServiceReset`): nennt, welche installierten Apps die Berechtigung
    /// ebenfalls verlieren, und ob Grantry selbst darunter ist (`ownBundleID`).
    public static func resetService(_ reset: ServiceReset, ownBundleID: String? = Bundle.main.bundleIdentifier) -> ActionConfirmation {
        let service = reset.serviceName
        var notes = [
            reset.collateralNames.isEmpty
                ? "Andere Apps mit dieser Berechtigung sind Grantry nicht bekannt."
                : "Auch diese \(reset.collateralNames.count) Apps verlieren die Berechtigung: \(list(reset.collateralNames))."
        ]
        if reset.affects(bundleID: ownBundleID) { notes.append("Auch Grantry selbst verliert diese Berechtigung.") }
        notes.append("Laufende Apps verlieren den Zugriff sofort. Jede App fragt beim nächsten Zugriff erneut nach, "
            + "oder du erlaubst sie in den Systemeinstellungen neu. Rückgängig machen lässt sich das nicht.")
        return ActionConfirmation(
            title: "\(service) für alle Apps zurücksetzen?",
            message: "macOS entfernt Berechtigungen gelöschter Apps nur, wenn \(service) für alle Apps zurückgesetzt wird. "
                + "Entfernt werden die Einträge von: \(list(reset.orphanNames)).",
            note: notes.joined(separator: " "),
            confirmTitle: "Für alle Apps zurücksetzen",
            isDestructive: true
        )
    }

    public static func setEnabled(_ item: AutostartItem, _ enabled: Bool) -> ActionConfirmation {
        let verb = enabled ? "aktivieren" : "deaktivieren"
        return ActionConfirmation(
            title: "\(name(of: item)) \(verb)?",
            message: enabled ? nil : "Der Eintrag startet nicht mehr automatisch und wird beendet, falls er läuft.",
            confirmTitle: enabled ? "Aktivieren" : "Deaktivieren",
            isDestructive: false
        )
    }

    public static func remove(_ item: AutostartItem) -> ActionConfirmation {
        ActionConfirmation(
            title: "\(name(of: item)) entfernen?",
            message: "Der Eintrag wird beendet, falls er läuft, und seine launchd-Plist gelöscht.",
            note: "Die Plist wird vorher gesichert und lässt sich im Verlauf wiederherstellen.",
            confirmTitle: "Entfernen",
            isDestructive: true
        )
    }

    public static func restore(_ entry: ReceiptEntry) -> ActionConfirmation {
        let note: String? = switch (entry.receipt.wasEnabled, entry.receipt.wasLoaded) {
        case (false, _): "Der Eintrag war vor dem Entfernen deaktiviert und bleibt es."
        case (true, false): "Der Eintrag lief vor dem Entfernen nicht und wird deshalb nicht gestartet."
        case (true, true): nil
        }
        return ActionConfirmation(
            title: "„\(entry.label)“ wiederherstellen?",
            message: "Die gesicherte launchd-Plist wird an ihren ursprünglichen Ort zurückgelegt.",
            note: note,
            confirmTitle: "Wiederherstellen",
            isDestructive: false
        )
    }

    /// Höchstens `maximumListedNames` Namen, danach „und n weitere“ – das Blatt darf das Fenster nicht sprengen.
    static func list(_ names: [String]) -> String {
        guard names.count > maximumListedNames else { return names.joined(separator: ", ") }
        return names.prefix(maximumListedNames).joined(separator: ", ") + " und \(names.count - maximumListedNames) weitere"
    }

    static let maximumListedNames = 12

    /// `„Label“`, ergänzt um den App-Namen des Eigentümers.
    private static func name(of item: AutostartItem) -> String {
        "„\(item.label)“" + (item.owner.map { " (\($0.displayName))" } ?? "")
    }
}
