import ManagerKit
import SwiftUI

/// Knöpfe einer Berechtigung im Detail (Einträge auf der Mulde, LB-2.2): „Zurücksetzen …“, bei schreibgeschützten
/// Einträgen entfernter Apps „Für alle Apps zurücksetzen …“ (`ServiceReset`) und „In Systemeinstellungen öffnen“. Den
/// Grund eines Schreibschutzes und die laufende Aktion zeigt der Eintrag (`PermissionsBoardMapping.grant`).
struct GrantActions: View {
    let grant: PermissionGrant
    let actions: ActionRunner
    /// Fordert die Bestätigung zum Zurücksetzen an.
    let requestReset: (PermissionGrant) -> Void
    /// Fordert die Bestätigung an, den Dienst einer verwaisten Berechtigung für alle Apps zurückzusetzen.
    let requestServiceReset: (PermissionGrant) -> Void
    @Environment(\.openURL) private var openURL

    static let policy = ActionPolicy()

    var body: some View {
        switch Self.policy.availability(for: grant) {
        case .available:
            Button("Zurücksetzen …") { requestReset(grant) }
                .disabled(!actions.canStart)
        case .readOnly:
            if grant.isOrphaned {
                Button("Für alle Apps zurücksetzen …") { requestServiceReset(grant) }
                    .disabled(!actions.canStart)
                    .help("Entfernt diesen Eintrag – auch alle installierten Apps verlieren die Berechtigung")
            }
        }
        if let url = PermissionCatalog.service(for: grant.service).settingsURL {
            Button("In Systemeinstellungen öffnen") { openURL(url) }
        }
    }
}

extension String {
    /// Erster Buchstabe groß („erlaubt“ → „Erlaubt“).
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
