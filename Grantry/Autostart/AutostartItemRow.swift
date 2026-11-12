import GrantryCharts
import ManagerKit
import SwiftUI

// Symbol eines Autostart-Eintrags in Liste, Detail und Sprungzeilen (LB-2.3, #540). Den Zeileninhalt (Label, Besitzer
// bzw. Programm, Zustandschip, Badges, Befund-Punkt) bildet `AutostartBoardMapping.item(_:presentation:)`.

/// Symbol der Besitzer-App; ohne Besitzer das Symbol der Eintragsart im Kreis (`InstrumentRowIcon`).
struct AutostartItemIcon: View {
    let item: AutostartItem
    var size: CGFloat = InstrumentSize.rowIconTall

    var body: some View {
        if let owner = item.owner {
            AppIconView(app: owner, size: size)
        } else {
            InstrumentRowIcon(symbol: item.kind.systemImage, size: size)
        }
    }
}

extension AutostartKind {
    /// SF Symbol der Eintragsart.
    var systemImage: String {
        switch self {
        case .loginItem: "person.crop.circle.badge.checkmark"
        case .launchAgent: "gearshape"
        case .launchDaemon: "gearshape.2"
        case .backgroundTask: "square.stack.3d.down.right"
        }
    }
}
