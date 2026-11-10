import SwiftUI

/// Gerüst des Hauptfensters: Seitenleiste mit den Bereichen links, rechts der Inhalt des gewählten Bereichs. Ist ein
/// Inhalt höher oder breiter als das Fenster, rollt er im Detailbereich (`FittingScrollView`, #480), statt das Fenster
/// zu vergrößern oder die Seitenleiste zu verschieben. Ohne
/// `AppModel`, damit die Prüfung der Fensteranordnung (`task_manager_snapshots.py --layout`, #480) genau dieses Gerüst
/// mit Beispielinhalten hostet.
struct MainWindowSplit<Detail: View>: View {
    @Binding var selection: MainSection
    let unreadCount: Int
    @ViewBuilder let detail: Detail

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, unreadCount: unreadCount)
                .navigationSplitViewColumnWidth(
                    min: WindowLayout.sidebarMin, ideal: WindowLayout.sidebarIdeal, max: WindowLayout.sidebarMax
                )
        } detail: {
            FittingScrollView { detail }
                .navigationSplitViewColumnWidth(min: WindowLayout.contentMin, ideal: WindowLayout.contentMin)
        }
    }
}

/// Sidebar mit den Bereichen; „Verlauf“ trägt die Zahl ungelesener Änderungen.
struct SidebarView: View {
    @Binding var selection: MainSection
    let unreadCount: Int

    var body: some View {
        List(selection: $selection) {
            ForEach(MainSection.allCases) { section in
                Label(section.title, systemImage: section.systemImage)
                    .badge(section == .history ? unreadCount : 0)
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
    }
}
