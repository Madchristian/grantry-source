import SwiftUI

/// Einstellungen (⌘,): dieselbe Checkliste wie im Onboarding, ohne Nummern, die Update-Prüfung und die Meldungen
/// neuer Netzwerkdienste.
struct SettingsView: View {
    let prerequisites: PrerequisitesModel

    var body: some View {
        VStack(spacing: 0) {
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
