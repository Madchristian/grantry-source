import ManagerKit
import SwiftUI

/// Einstellung „Neue Netzwerkdienste melden“ (#128). Gespeichert unter `ListenerNotificationPreferences.storageKey`;
/// die `NotificationPolicy` liest sie je Event, eine Änderung gilt also sofort.
struct NetworkSettingsSection: View {
    @AppStorage(ListenerNotificationPreferences.storageKey)
    private var setting = ListenerNotificationSetting.exposedOnly

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Neue Netzwerkdienste melden", selection: $setting) {
                ForEach(ListenerNotificationSetting.allCases, id: \.self) { Text(verbatim: $0.displayName).tag($0) }
            }
            .fixedSize()
            Text("Dienste von macOS und beendete Dienste werden nie gemeldet; der Verlauf enthält alle Änderungen.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
}
