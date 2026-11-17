import GrantryCharts
import ManagerKit
import SwiftUI

/// Kachel „Thermik“ des Übersichts-Baukastens (Spec 2026-11-09-uebersicht-baukasten § 2): Zustand laut macOS, ohne
/// Temperaturen. 1 × 1 Zustand und Energiesparmodus kurz, 2 × 1 dazu die Stufe als Spur.
struct OverviewThermalTile: OverviewTile {
    static let kind = OverviewTileKind.thermal

    let value: MenuBarOverview.Thermal
    let span: OverviewTileSpan
    let open: () -> Void

    @Environment(\.self) private var environment

    static func value(from source: OverviewTileSource) -> MenuBarOverview.Thermal? { source.overview.thermal }

    var body: some View {
        let thermal = value
        let tone = thermal.tone.statusTone
        if span == .small {
            OverviewCard(title: Self.kind.title, spokenValue: thermal.spokenValue, open: open) {
                OverviewFigure(value: thermal.shortValue, detail: thermal.lowPowerModeShort,
                               color: environment.statusTextColor(tone))
            }
        } else {
            OverviewCard(title: Self.kind.title, value: thermal.shortValue, spokenValue: thermal.spokenValue,
                         valueColor: environment.statusTextColor(tone), open: open) {
                Spur(fraction: thermal.level, color: environment.statusColor(tone))
                    .frame(height: InstrumentSize.spurList)
                    .accessibilityHidden(true)
                Text(verbatim: thermal.detail).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                    .lineLimit(1)
            }
        }
    }
}
