import ManagerKit
import SwiftUI

/// Einstellungen (⌘,): dieselbe Checkliste wie im Onboarding, ohne Nummern, die Update-Prüfung und die Meldungen
/// neuer Netzwerkdienste.
struct SettingsView: View {
    let prerequisites: PrerequisitesModel
    let dockVisibility: DockVisibilityModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Dock-Symbol anzeigen", isOn: Binding(
                    get: { dockVisibility.showsDockIcon },
                    set: { dockVisibility.setShowsDockIcon($0) }
                ))
                .accessibilityIdentifier("showsDockIcon")
                Text("Grantry bleibt über die Menüleiste erreichbar, auch ohne Dock-Symbol.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            Divider()
            SetupChecklistView(model: prerequisites)
            Divider()
            UpdateSettingsSection()
            Divider()
            NetworkSettingsSection()
            Divider()
            HStack {
                Spacer()
                Button("Erneut prüfen") { Task { await prerequisites.refresh() } }
                    .disabled(prerequisites.isUpdatingPrerequisites)
            }
            .padding()
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .task { await prerequisites.refresh(showsProgress: false) }
    }
}
