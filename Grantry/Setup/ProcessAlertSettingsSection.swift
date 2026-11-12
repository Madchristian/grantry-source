import GrantryCharts
import ManagerKit
import SwiftUI

/// Gruppe „Prozesse“ mit der Einstellung „Hinweis bei vielen verwaisten Agenten-Prozessen“ (#224). Gespeichert unter
/// `OrphanAgentAlertPreferences.enabledKey`; der `OrphanAgentAlerter` liest sie je Prüfung, eine Änderung gilt also ab
/// der nächsten.
struct ProcessAlertSettingsSection: View {
    @AppStorage(OrphanAgentAlertPreferences.enabledKey)
    private var isEnabled = true

    var body: some View {
        SettingsPanel(String(localized: "Prozesse"), detail: String(localized: "Verwaiste Agenten-Prozesse")) {
            SettingToggle(String(localized: "Hinweis bei vielen verwaisten Agenten-Prozessen"),
                          note: ProcessCleanupPresentation.alertSettingNote, isOn: $isEnabled)
        }
    }
}
