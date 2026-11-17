import GrantryCharts
import ManagerKit
import SwiftUI

/// Kachel „Laufzeit“ des Übersichts-Baukastens (Spec 2026-11-09-uebersicht-baukasten § 2): Zeit seit dem Start des Macs
/// auf Minuten genau, damit die Kachel nicht jeden Takt neu zeichnet. 1 × 1 kurz („3 T 4 h“), 2 × 1 mit Minuten.
struct OverviewUptimeTile: OverviewTile {
    static let kind = OverviewTileKind.uptime

    let value: MenuBarOverview.UptimeFigures
    let span: OverviewTileSpan
    let open: () -> Void

    static func value(from source: OverviewTileSource) -> MenuBarOverview.UptimeFigures? {
        source.overview.summary?.uptimeFigures
    }

    var body: some View {
        OverviewCard(title: Self.kind.title, spokenValue: value.spokenValue, open: open) {
            if span == .small {
                OverviewFigure(value: value.short, detail: String(localized: "seit dem Start"))
            } else {
                OverviewFigure(value: value.detailed, detail: String(localized: "seit dem Start des Macs"))
            }
        }
    }
}
