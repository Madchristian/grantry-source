import ManagerKit
import SwiftUI

/// Ein Datenschutz-Dienst mit allen Apps, die dafür eingetragen sind.
struct ServiceDetailView: View {
    let group: ServiceGroup
    let appModel: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        GrantsDetailForm(appModel: appModel, grants: group.grants, grantsTitle: "Apps", subject: .app) {
            HStack(spacing: 12) {
                ServiceIconView(service: group.service, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: group.service.displayName)
                        .font(.title2.weight(.semibold))
                    Text(verbatim: group.service.id)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 12)
                if let url = group.service.settingsURL {
                    Button("In Systemeinstellungen öffnen") { openURL(url) }
                }
            }
        }
    }
}
