import GrantryCharts
import ManagerKit
import SwiftUI

/// Ein Datenschutz-Dienst mit allen Apps, die dafür eingetragen sind; „In Systemeinstellungen öffnen“ in der Knopfzeile
/// unter dem Kopf (Spec §11.2 d).
struct ServiceDetailView: View {
    let group: ServiceGroup
    let appModel: AppModel
    let presentation: PresentationSnapshot
    @Environment(\.openURL) private var openURL

    var body: some View {
        GrantsDetail(
            appModel: appModel,
            content: PermissionsBoardMapping.serviceDetail(group, presentation: presentation,
                                                           runningRecordID: appModel.actions.runningRecordID),
            grants: group.grants, subject: .app
        ) {
            ServiceIconView(service: group.service, size: InstrumentSize.shield)
        } actions: {
            if let url = group.service.settingsURL {
                DetailActions {
                    Button("In Systemeinstellungen öffnen") { openURL(url) }
                }
            }
        } extra: {
            EmptyView()
        }
    }
}
