import GrantryCharts
import ManagerKit
import SwiftUI

/// Gemeinsames Gerüst der Berechtigungs-Details (nach App, nach Dienst) im Lagebild (LB-2.2, #539): `GrantDetailPanel` mit
/// Kopf, Knopfzeile, Angaben und den Berechtigungen samt „Zurücksetzen …“ bzw. „Für alle Apps zurücksetzen …“ und
/// Bestätigung, danach optionale weitere Gruppen. Bestätigungen, Texte und Ablauf wie zuvor; die Meldung zur Aktion zeigt
/// `PermissionsView` oberhalb (`ActionContext.permissions`).
struct GrantsDetail<Icon: View, Actions: View, Extra: View>: View {
    let appModel: AppModel
    let content: GrantDetailContent
    /// Die Berechtigungen in der Reihenfolge von `content.grants`.
    let grants: [PermissionGrant]
    /// Was jeder Eintrag benennt: in der App-Ansicht den Dienst, in der Dienst-Ansicht die App.
    let subject: GrantSubject
    @ViewBuilder let icon: Icon
    @ViewBuilder let actions: Actions
    @ViewBuilder let extra: Extra
    @State private var pendingReset: PermissionGrant?
    @State private var pendingServiceReset: ServiceReset?

    var body: some View {
        let byID = Dictionary(grants.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        GrantDetailPanel(content: content) {
            icon
        } actions: {
            actions
        } grantIcon: { entry in
            if let grant = byID[entry.id] { GrantIcon(grant: grant, subject: subject) }
        } grantActions: { entry in
            if let grant = byID[entry.id] {
                GrantActions(grant: grant, actions: appModel.actions) {
                    pendingReset = $0
                } requestServiceReset: { grant in
                    // Gegen den aktuellen Scan: Die Bestätigung nennt alle Apps, die die Berechtigung verlieren.
                    pendingServiceReset = appModel.monitoring.snapshot.flatMap { ServiceReset(service: grant.service, in: $0) }
                }
            }
        } extra: {
            extra
        }
        .actionConfirmation(for: $pendingReset, confirmation: {
            ActionConfirmation.reset($0, knownGrants: appModel.monitoring.snapshot?.grants ?? [])
        }) { grant in
            Task { await appModel.actions.reset(grant, context: .permissions) }
        }
        .actionConfirmation(for: $pendingServiceReset, confirmation: { ActionConfirmation.resetService($0) }) { reset in
            Task { await appModel.actions.resetService(reset, context: .permissions) }
        }
    }
}

/// Symbol eines Eintrags: in der App-Ansicht der Dienst, in der Dienst-Ansicht die App.
private struct GrantIcon: View {
    let grant: PermissionGrant
    let subject: GrantSubject

    var body: some View {
        switch subject {
        case .service: ServiceIconView(service: PermissionCatalog.service(for: grant.service),
                                       size: InstrumentSize.rowIconTall)
        case .app: AppIconView(app: grant.client, size: InstrumentSize.rowIconTall)
        }
    }
}
