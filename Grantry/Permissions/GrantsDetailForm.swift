import ManagerKit
import SwiftUI

/// Gemeinsames Gerüst der Berechtigungs-Details (nach App, nach Dienst): Kopf, Abschnitt mit den Berechtigungen samt
/// „Zurücksetzen …“ bzw. „Für alle Apps zurücksetzen …“ und Bestätigung, danach optionale weitere Abschnitte. Die Meldung zur Aktion zeigt
/// `PermissionsView` oberhalb (`ActionContext.permissions`).
struct GrantsDetailForm<Header: View, Extra: View>: View {
    let appModel: AppModel
    let grants: [PermissionGrant]
    /// Titel des Abschnitts mit den Berechtigungen.
    let grantsTitle: LocalizedStringKey
    /// Was jede Zeile benennt: in der App-Ansicht den Dienst, in der Dienst-Ansicht die App.
    let subject: GrantRow.Subject
    @ViewBuilder let header: Header
    @ViewBuilder let extra: (PresentationSnapshot) -> Extra
    @State private var pendingReset: PermissionGrant?
    @State private var pendingServiceReset: ServiceReset?

    var body: some View {
        if let presentation = appModel.presentation {
            Form {
                Section { header }
                Section(grantsTitle) {
                    if grants.isEmpty {
                        Text("Keine Berechtigungen").foregroundStyle(.secondary)
                    }
                    ForEach(grants) { grant in
                        GrantRow(grant: grant, subject: subject, presentation: presentation, actions: appModel.actions) {
                            pendingReset = $0
                        } requestServiceReset: { grant in
                            // Gegen den aktuellen Scan: Die Bestätigung nennt alle Apps, die die Berechtigung verlieren.
                            pendingServiceReset = appModel.monitoring.snapshot.flatMap { ServiceReset(service: grant.service, in: $0) }
                        }
                    }
                }
                extra(presentation)
            }
            .formStyle(.grouped)
            .actionConfirmation(for: $pendingReset, confirmation: ActionConfirmation.reset) { grant in
                Task { await appModel.actions.reset(grant, context: .permissions) }
            }
            .actionConfirmation(for: $pendingServiceReset, confirmation: { ActionConfirmation.resetService($0) }) { reset in
                Task { await appModel.actions.resetService(reset, context: .permissions) }
            }
        }
    }
}

extension GrantsDetailForm where Extra == EmptyView {
    init(
        appModel: AppModel, grants: [PermissionGrant], grantsTitle: LocalizedStringKey, subject: GrantRow.Subject,
        @ViewBuilder header: () -> Header
    ) {
        self.init(appModel: appModel, grants: grants, grantsTitle: grantsTitle, subject: subject, header: header) { _ in
            EmptyView()
        }
    }
}
