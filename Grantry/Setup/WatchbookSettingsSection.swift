import ManagerKit
import SwiftUI

/// Einstellung „Wachbuch führen“ (Spec 2026-11-08 §5.1, Standard aus) und darunter die Mitteilungen bei schweren
/// Befunden (TM-12.8, Standard an); der Recorder liest diese je 10-s-Punkt, eine Änderung gilt also sofort.
struct WatchbookSettingsSection: View {
    @Bindable var model: WatchbookModel
    @AppStorage(SevereFindingAlertPreferences.enabledKey) private var alertsSevereFindings = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Wachbuch führen", isOn: $model.isEnabled)
                .accessibilityIdentifier("recordsWatchbook")
            Text("""
                Zeichnet alle 10 Sekunden Auslastung, größte Verbraucher, Befunde und Systemereignisse auf, auch ohne \
                offenes Fenster – ohne Helper und ohne Netzwerkmessung. Gespeichert nur auf diesem Mac, 7 Tage.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Bei schweren Befunden benachrichtigen", isOn: $alertsSevereFindings)
                .disabled(!model.isEnabled)
                .accessibilityIdentifier("alertsSevereFindings")
            Text(alertsNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private var alertsNote: LocalizedStringKey {
        model.isEnabled
            ? "Dauerlast über 10 Minuten, ernster thermischer Zustand oder kritischer Speicherdruck – höchstens eine Mitteilung je Art und Stunde."
            : "Nur wirksam, solange das Wachbuch geführt wird."
    }
}
