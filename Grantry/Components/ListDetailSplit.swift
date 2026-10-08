import SwiftUI

/// Spaltenbreiten des Hauptfensters: Sidebar (höchstens `sidebarMax`) + Liste (mindestens `listMin`) + Detail
/// (mindestens `detailMin`) passen in `windowMinWidth`.
enum WindowLayout {
    static let sidebarMin: CGFloat = 170
    static let sidebarIdeal: CGFloat = 190
    static let sidebarMax: CGFloat = 240
    static let listMin: CGFloat = 240
    static let listIdeal: CGFloat = 300
    static let listMax: CGFloat = 420
    static let detailMin: CGFloat = 320
    /// Mindestbreite der Detailspalte des Fensters (Liste, Trenner, Detail).
    static let contentMin: CGFloat = listMin + 1 + detailMin
    static let windowMinWidth: CGFloat = 900
    static let windowMinHeight: CGFloat = 600
}

/// Liste links, Detail rechts (Berechtigungen, Autostart); die Liste wächst mit dem Fenster bis `listMax`.
///
/// Bewusst kein `HSplitView`: Innerhalb der `NavigationSplitView` rechnete es seine Mindestbreite falsch, bei 900 pt
/// ragten Sidebar und Detail über den Fensterrand und die Detailspalte war nicht mehr zu sehen.
struct ListDetailSplit<ListContent: View, DetailContent: View>: View {
    @ViewBuilder let list: ListContent
    @ViewBuilder let detail: DetailContent

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(minWidth: WindowLayout.listMin, idealWidth: WindowLayout.listIdeal, maxWidth: WindowLayout.listMax,
                       maxHeight: .infinity)
            Divider()
            detail
                .frame(minWidth: WindowLayout.detailMin, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
