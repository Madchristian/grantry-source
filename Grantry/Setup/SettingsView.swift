import GrantryCharts
import ManagerKit
import SwiftUI

/// Einstellungen (⌘,) in zwei Tabs (TM17, E4), nativ mit Tokens im Lagebild (LB-5.2, #553; Spec 2026-11-10 § 11
/// Entscheidung 3 und § 11.5): „Allgemein“ mit den Gruppen Darstellung, Einrichtung (Prüfzeilen, „Erneut prüfen“ im
/// Kopf), Updates, Netzwerk, Wachbuch, Prozesse und Lizenzen als Panels; „Menüleiste“ mit den Messanzeigen. Jeder
/// Bereich ist höchstens so hoch, dass das Fenster samt Bereichsleiste in den sichtbaren Bereich seines Bildschirms
/// passt, und scrollt sonst (#479, #525), auch nach Tab-, Bildschirm- oder Auflösungswechsel; das Fenster bleibt auf
/// dem Bildschirm (#486).
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
        VStack(spacing: InstrumentSpacing.panel) {
            DockSettingsSection(dockVisibility: dockVisibility)
            SetupChecklistView(model: prerequisites)
            UpdateSettingsSection()
            NetworkSettingsSection()
            WatchbookSettingsSection(model: watchbook)
            ProcessAlertSettingsSection()
            ThirdPartyLicensesSection()
        }
        .padding(InstrumentSpacing.page)
        .frame(width: SettingsLayout.width)
        .instrumentBackground()
    }
}

/// Maße des Einstellungsfensters: Breite wie bisher (Entwurf LB-5.1, Spec 2026-11-10 § 11 Entscheidung 3).
enum SettingsLayout {
    static let width: CGFloat = 560
}

/// Gruppe „Darstellung“: Dock-Symbol als Schalter (Spec 2026-11-10 § 11.5 b).
private struct DockSettingsSection: View {
    let dockVisibility: DockVisibilityModel

    var body: some View {
        SettingsPanel(String(localized: "Darstellung"), detail: String(localized: "Dock und Menüleiste")) {
            SettingToggle(String(localized: "Dock-Symbol anzeigen"),
                          note: String(localized: "Grantry bleibt über die Menüleiste erreichbar, auch ohne Dock-Symbol."),
                          isOn: Binding(get: { dockVisibility.showsDockIcon },
                                        set: { dockVisibility.setShowsDockIcon($0) }),
                          identifier: "showsDockIcon")
        }
    }
}
