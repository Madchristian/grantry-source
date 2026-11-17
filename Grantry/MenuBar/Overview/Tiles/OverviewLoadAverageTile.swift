import GrantryCharts
import ManagerKit
import SwiftUI

/// Kachel „Durchschnittslast“ des Übersichts-Baukastens (Spec 2026-11-09-uebersicht-baukasten § 2): 1 × 1 die letzte
/// Minute groß und fünf Minuten klein, 2 × 1 alle drei Zeitfenster nebeneinander.
struct OverviewLoadAverageTile: OverviewTile {
    static let kind = OverviewTileKind.loadAverage

    let value: MenuBarOverview.LoadAverageFigures
    let span: OverviewTileSpan
    let open: () -> Void

    static func value(from source: OverviewTileSource) -> MenuBarOverview.LoadAverageFigures? {
        source.overview.summary?.loadFigures
    }

    var body: some View {
        let load = value
        if span == .small {
            OverviewCard(title: String(localized: "Last"), spokenValue: load.spokenValue, open: open) {
                OverviewFigure(value: load.one, detail: String(localized: "5 min \(load.five)"))
            }
        } else {
            OverviewCard(title: Self.kind.title, spokenValue: load.spokenValue, open: open) {
                HStack(spacing: InstrumentSpacing.bar) {
                    OverviewFigure(value: load.one, detail: String(localized: "1 min"))
                    OverviewFigure(value: load.five, detail: String(localized: "5 min"))
                    OverviewFigure(value: load.fifteen, detail: String(localized: "15 min"))
                }
            }
        }
    }
}
