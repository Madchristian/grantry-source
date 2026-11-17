import GrantryCharts
import ManagerKit
import SwiftUI

/// Kachel „Akku“ des Übersichts-Baukastens (Spec 2026-11-09-uebersicht-baukasten § 2), nur am Mac mit Akku
/// (`OverviewTileKind.isAvailable`). 1 × 1 Ladestand mit Spur, 2 × 1 dazu der Zustand.
struct OverviewBatteryTile: OverviewTile {
    static let kind = OverviewTileKind.battery

    let value: MenuBarOverview.Battery
    let span: OverviewTileSpan
    let open: () -> Void

    @Environment(\.self) private var environment

    static func value(from source: OverviewTileSource) -> MenuBarOverview.Battery? { source.overview.battery }

    var body: some View {
        let battery = value
        let color = environment.instrumentTextColor(.battery)
        if span == .small {
            OverviewCard(title: Self.kind.title, spokenValue: battery.spokenValue, open: open) {
                OverviewFigure(value: battery.value, color: color)
                charge
            }
        } else {
            OverviewCard(title: Self.kind.title, detail: battery.state, value: battery.value,
                         spokenValue: battery.spokenValue, valueColor: color, open: open) {
                charge
            }
        }
    }

    private var charge: some View {
        Spur(fraction: value.charge, color: environment.instrumentColor(.battery))
            .frame(height: span == .small ? InstrumentSize.spurCard : InstrumentSize.spurList)
            .accessibilityHidden(true)
    }
}
