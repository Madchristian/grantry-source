import GrantryCharts
import ManagerKit
import SwiftUI

/// Gruppe „Wachbuch“: „Wachbuch führen“ (Spec 2026-11-08 §5.1, Standard aus) und darunter die Mitteilungen bei schweren
/// Befunden (TM-12.8, Standard an), beide als Schalter (Spec 2026-11-10 § 11.5 b); der Recorder liest sie je
/// 10-s-Punkt, eine Änderung gilt also sofort.
struct WatchbookSettingsSection: View {
    @Bindable var model: WatchbookModel
    @AppStorage(SevereFindingAlertPreferences.enabledKey) private var alertsSevereFindings = true

    var body: some View {
        SettingsPanel(String(localized: "Wachbuch"), detail: detail) {
            SettingToggle(String(localized: "Wachbuch führen"),
                          note: String(localized: """
                              Zeichnet alle 10 Sekunden Auslastung, größte Verbraucher, Befunde und Systemereignisse auf, \
                              auch ohne offenes Fenster – ohne Helper und ohne Netzwerkmessung. Gespeichert nur auf \
                              diesem Mac, 7 Tage.
                              """),
                          isOn: $model.isEnabled, identifier: "recordsWatchbook")
            SettingToggle(String(localized: "Bei schweren Befunden benachrichtigen"), note: alertsNote,
                          isOn: $alertsSevereFindings, identifier: "alertsSevereFindings")
                .disabled(!model.isEnabled)
        }
    }

    private var detail: String {
        model.isEnabled ? String(localized: "Aufzeichnung an · 7 Tage") : String(localized: "Aufzeichnung aus")
    }

    private var alertsNote: String {
        model.isEnabled
            ? String(localized: "Dauerlast über 10 Minuten, ernster thermischer Zustand oder kritischer Speicherdruck – höchstens eine Mitteilung je Art und Stunde.")
            : String(localized: "Nur wirksam, solange das Wachbuch geführt wird.")
    }
}
