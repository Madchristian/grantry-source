import GrantryCharts
import ManagerKit
import SwiftUI

/// Gruppe „Netzwerk“ mit der Einstellung „Neue Netzwerkdienste melden“ (#128). Gespeichert unter
/// `ListenerNotificationPreferences.storageKey`; die `NotificationPolicy` liest sie je Event, eine Änderung gilt also
/// sofort. Drei Möglichkeiten, deshalb ein natives Menü statt eines Schalters.
struct NetworkSettingsSection: View {
    @AppStorage(ListenerNotificationPreferences.storageKey)
    private var setting = ListenerNotificationSetting.exposedOnly

    var body: some View {
        let title = String(localized: "Neue Netzwerkdienste melden")
        SettingsPanel(String(localized: "Netzwerk"), detail: String(localized: "Mitteilungen zu Diensten")) {
            SettingRow(title, note: String(localized: "Dienste von macOS und beendete Dienste werden nie gemeldet; der Verlauf enthält alle Änderungen.")) {
                Picker(title, selection: $setting) {
                    ForEach(ListenerNotificationSetting.allCases, id: \.self) { Text(verbatim: $0.displayName).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}
