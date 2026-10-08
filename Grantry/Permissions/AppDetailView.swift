import ManagerKit
import SwiftUI

/// Eine App mit Signatur, Pfad, allen Berechtigungen und ihren Autostart-Einträgen.
struct AppDetailView: View {
    let group: AppGroup
    let appModel: AppModel
    @Environment(MainWindowModel.self) private var window

    var body: some View {
        GrantsDetailForm(appModel: appModel, grants: group.grants, grantsTitle: "Berechtigungen", subject: .service) {
            header
        } extra: { presentation in
            if !group.autostartItems.isEmpty {
                Section("Autostart") {
                    ForEach(group.autostartItems) { item in
                        Button { window.show(item) } label: {
                            AutostartItemRow(item: item, badges: presentation.badges.badges(for: item.id))
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help("In „Autostart“ zeigen")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        let app = group.app
        Group {
            HStack(spacing: 12) {
                AppIconView(app: app, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: app.displayName)
                        .font(.title2.weight(.semibold))
                    if let bundleID = app.bundleID {
                        Text(verbatim: bundleID)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            LabeledContent("Signatur") {
                SigningLabel(signing: app.signing)
            }
            if let path = app.path {
                LabeledContent("Pfad") {
                    Text(verbatim: path)
                        .textSelection(.enabled)
                        .truncationMode(.middle)
                        .lineLimit(2)
                }
            }
            if app.presence != .present {
                LabeledContent("Auf dem Mac") {
                    Text(verbatim: app.presence.displayName)
                }
            }
        }
    }
}
