import GrantryCharts
import ManagerKit
import SwiftUI

/// Eine App mit Signatur, Pfad, allen Berechtigungen und ihren Autostart-Einträgen; Autostart als Sprungzeilen
/// (Spec §11.2 e).
struct AppDetailView: View {
    let group: AppGroup
    let appModel: AppModel
    let presentation: PresentationSnapshot
    @Environment(MainWindowModel.self) private var window

    var body: some View {
        GrantsDetail(
            appModel: appModel,
            content: PermissionsBoardMapping.appDetail(group, presentation: presentation,
                                                       runningRecordID: appModel.actions.runningRecordID),
            grants: group.grants, subject: .service
        ) {
            AppIconView(app: group.app, size: InstrumentSize.shield)
        } actions: {
            EmptyView()
        } extra: {
            if !group.autostartItems.isEmpty {
                DetailGroup(String(localized: "Autostart"), count: group.autostartItems.count) {
                    ForEach(group.autostartItems) { item in
                        JumpRow(item.jumpRowContent(badges: presentation.badges.badges(for: item.id)),
                                destination: MainSection.autostart.title) {
                            window.show(item)
                        } icon: {
                            AutostartItemIcon(item: item, size: InstrumentSize.rowIconTall)
                        }
                    }
                }
            }
        }
    }
}
