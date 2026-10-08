import ManagerKit

/// Wunsch, das Entfernen-Blatt zu öffnen (alle Einstiegspunkte führen hierher, Spec v3 §3): „App entfernen …“ oder
/// „Reste anzeigen“ – dann sind nur die Reste vorausgewählt, nicht die App selbst, ihre Berechtigungen und ihr Autostart.
struct RemovalRequest: Identifiable, Equatable {
    enum Mode: String {
        case uninstall, leftovers
    }

    let app: InstalledApp
    let mode: Mode
    /// Nur ansehen (DEBUG-Vorschau `-DebugRemovalPreview`): Die Bestätigung bleibt gesperrt.
    var isPreview = false

    var id: String { "\(mode.rawValue)|\(app.id)" }
}
