import ManagerKit
import SwiftUI

/// Eine Berechtigung im Detail: Dienst bzw. App, Zustand, Badges, Prüf- und Aufräumhinweise sowie die Aktionen
/// „Zurücksetzen…“ und „In Systemeinstellungen öffnen“; schreibgeschützte Einträge nennen den Grund. Berechtigungen
/// entfernter Apps bieten „Für alle Apps zurücksetzen …“ an (`ServiceReset`).
struct GrantRow: View {
    /// Was die Zeile benennt: in der App-Ansicht den Dienst, in der Dienst-Ansicht die App.
    enum Subject {
        case service, app
    }

    let grant: PermissionGrant
    let subject: Subject
    let presentation: PresentationSnapshot
    let actions: ActionRunner
    /// Fordert die Bestätigung zum Zurücksetzen an.
    let requestReset: (PermissionGrant) -> Void
    /// Fordert die Bestätigung an, den Dienst einer verwaisten Berechtigung für alle Apps zurückzusetzen.
    let requestServiceReset: (PermissionGrant) -> Void
    @Environment(\.openURL) private var openURL

    private static let policy = ActionPolicy()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: title)
                        .fontWeight(.medium)
                    RecordBadgesRow(badges: presentation.badges.badges(for: grant.id))
                    Spacer(minLength: 8)
                    Text(verbatim: grant.authValue.displayName.capitalizedFirst)
                        .foregroundStyle(grant.authValue.tone.color)
                }
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                RecordHints(presentation: presentation, recordID: grant.id)
                actionRow
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var icon: some View {
        switch subject {
        case .service: ServiceIconView(service: PermissionCatalog.service(for: grant.service))
        case .app: AppIconView(app: grant.client)
        }
    }

    private var title: String {
        switch subject {
        case .service: grant.serviceName
        case .app: grant.target.map { String(localized: "\(grant.client.displayName) (Ziel: \($0))") } ?? grant.client.displayName
        }
    }

    private var details: String {
        let date = grant.lastModified.formatted(date: .abbreviated, time: .omitted)
        return String(localized: "\(grant.scope.displayName) · geändert am \(date)")
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            switch Self.policy.availability(for: grant) {
            case .available:
                Button("Zurücksetzen …") { requestReset(grant) }
                    .disabled(!actions.canStart)
            case .readOnly(let reason):
                HintLabel(text: reason.description, systemImage: "lock", color: .secondary)
                if grant.isOrphaned {
                    Button("Für alle Apps zurücksetzen …") { requestServiceReset(grant) }
                        .disabled(!actions.canStart)
                        .help("Entfernt diesen Eintrag – auch alle installierten Apps verlieren die Berechtigung")
                }
            }
            if let url = PermissionCatalog.service(for: grant.service).settingsURL {
                Button("In Systemeinstellungen öffnen") { openURL(url) }
            }
            if [grant.id, ServiceReset.recordID(for: grant.service)].contains(actions.runningRecordID) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Aktion läuft")
            }
        }
        .controlSize(.small)
        .padding(.top, 2)
    }
}

extension String {
    /// Erster Buchstabe groß („erlaubt“ → „Erlaubt“).
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
