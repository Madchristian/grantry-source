import GrantryCharts
import ManagerKit
import SwiftUI

/// Tab-Leiste des Task-Managers oben im Inhalt (#463): alle Tabs, rechts Takt und der Sprung zu „Autostart“. In der
/// Symbolleiste verschwanden die zehn Tabs samt Takt im Überlaufmenü; `InstrumentTabs` verdichtet und bricht um, damit
/// bis zur Mindestbreite des Fensters – mit und ohne Seitenleiste – jeder Tab direkt erreichbar bleibt.
struct TaskManagerTabBar: View {
    @Binding var tab: TaskManagerTab
    @Binding var interval: TaskManagerInterval
    let showAutostart: () -> Void

    var body: some View {
        InstrumentTabs(String(localized: "Ansicht"), selection: $tab,
                       options: TaskManagerTab.available.map { ($0, $0.title) }) {
            HStack(spacing: InstrumentSpacing.panel) {
                Picker("Takt", selection: $interval) {
                    ForEach(TaskManagerInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
                .pickerStyle(.menu)
                .help("Wie oft gemessen wird")
                Button("Autostart", systemImage: MainSection.autostart.systemImage, action: showAutostart)
                    .help("Autostart-Einträge anzeigen")
            }
        }
    }
}

/// Rahmen jedes Tabs: oben die Tab-Leiste, darunter die Zustandszeile (sofern der Tab kein eigenes Urteil zeigt) und der
/// Inhalt des Tabs. Leiste und Zustandszeile stehen fest; nur der Inhalt rollt, wenn er höher oder breiter ist, als das
/// Fenster erlaubt (#480) – so bleibt jeder Tab erreichbar.
struct TaskManagerPage<Bar: View, Status: View, Content: View>: View {
    let showsStatus: Bool
    @ViewBuilder let bar: Bar
    @ViewBuilder let status: Status
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            bar.padding([.horizontal, .top], InstrumentSpacing.page)
            if showsStatus {
                status.padding([.horizontal, .top], InstrumentSpacing.page)
            }
            // Nur senkrecht: Waagrecht rollt schon der Detailbereich (`MainWindowSplit`). Rollten beide Ebenen auch
            // waagrecht, nahm der innere Bildlauf das Scrollrad nicht an – Energie, Wachbuch und Benutzer blieben bei
            // 900 × 652 pt mit Seitenleiste unten abgeschnitten (Nachbewertung 2026.11.9/1531, Sollte 1, #507).
            FittingScrollView(axes: .vertical) { content }
        }
    }
}
