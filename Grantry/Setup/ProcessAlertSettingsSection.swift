import ManagerKit
import SwiftUI

/// Einstellung „Hinweis bei vielen verwaisten Agenten-Prozessen“ (#224). Gespeichert unter
/// `OrphanAgentAlertPreferences.enabledKey`; der `OrphanAgentAlerter` liest sie je Prüfung, eine Änderung gilt also ab
/// der nächsten.
struct ProcessAlertSettingsSection: View {
    @AppStorage(OrphanAgentAlertPreferences.enabledKey)
    private var isEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Hinweis bei vielen verwaisten Agenten-Prozessen", isOn: $isEnabled)
                .toggleStyle(.switch)
            Text(verbatim: ProcessCleanupPresentation.alertSettingNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
}
