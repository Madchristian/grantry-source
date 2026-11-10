import GrantryCharts
import ManagerKit
import SwiftUI

/// Einstellungen (⌘,) in zwei Tabs (TM17, E4): „Allgemein“ mit derselben Checkliste wie im Onboarding, ohne Nummern,
/// der Update-Prüfung, den Meldungen neuer Netzwerkdienste, dem Hinweis auf verwaiste Agenten-Prozesse und dem Wachbuch;
/// „Menüleiste“ mit den Messanzeigen. Jeder Bereich ist höchstens so hoch, dass das Fenster samt Bereichsleiste in den
/// sichtbaren Bereich seines Bildschirms passt, und scrollt sonst (#479, #525), auch nach Tab-, Bildschirm- oder
/// Auflösungswechsel; das Fenster bleibt auf dem Bildschirm (#486).
struct SettingsView: View {
    let prerequisites: PrerequisitesModel
    let dockVisibility: DockVisibilityModel
    let menuBarMeters: MenuBarMetersModel
    let taskManager: TaskManagerModel
    let watchbook: WatchbookModel

    var body: some View {
        TabView {
            Tab("Allgemein", systemImage: "gearshape") { ScreenCappedScroll { general } }
            Tab("Menüleiste", systemImage: "menubar.rectangle") {
                ScreenCappedScroll { MenuBarSettingsTab(meters: menuBarMeters, taskManager: taskManager) }
            }
        }
        .task { await prerequisites.refresh(showsProgress: false) }
    }

    private var general: some View {
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
            WatchbookSettingsSection(model: watchbook)
            Divider()
            ProcessAlertSettingsSection()
            Divider()
            HStack {
                Spacer()
                Button("Erneut prüfen") { Task { await prerequisites.refresh() } }
                    .disabled(prerequisites.isUpdatingPrerequisites)
            }
            .padding()
        }
        .frame(width: 560)
    }
}
