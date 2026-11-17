import GrantryCharts
import ManagerKit
import SwiftUI

/// Kachel „Netz“ des Übersichts-Baukastens (Spec 2026-11-09-uebersicht-baukasten § 2): Schnittstelle der Standardroute.
/// 1 × 1 Empfangen und Senden untereinander, 2 × 1 nebeneinander mit dem Verlauf der letzten Minute darunter, 2 × 2 wie
/// die Karte aus PR 623 als Tabelle mit dem Verlauf darunter, der die Höhe füllt, 4 × 1 Verlauf mit Raten rechts.
struct OverviewNetworkTile: OverviewTile {
    static let kind = OverviewTileKind.network

    let value: OverviewRateReading<MenuBarOverview.Network>
    let span: OverviewTileSpan
    let open: () -> Void

    static func value(from source: OverviewTileSource) -> OverviewRateReading<MenuBarOverview.Network>? {
        source.overview.network.map { network in
            OverviewRateReading(base: network, history: OverviewRateHistory(
                source.history, upper: .received(network.interfaceName), lower: .sent(network.interfaceName)))
        }
    }

    var body: some View {
        let network = value.base
        OverviewCard(title: Self.kind.title, detail: span == .small ? "" : network.title,
                     spokenValue: network.spokenValue, open: open) {
            switch span {
            case .small:
                OverviewRateLine(symbol: "↓", value: network.received, hue: .received)
                OverviewRateLine(symbol: "↑", value: network.sent, hue: .sent)
            case .wide:
                HStack(spacing: InstrumentSpacing.bar) {
                    LegendValue(title: "↓", value: network.received, hue: .received)
                    LegendValue(title: "↑", value: network.sent, hue: .sent)
                }
                sparkline
            case .large:
                LegendPair(first: (String(localized: "↓ Empfangen"), network.received, .received),
                           second: (String(localized: "↑ Gesendet"), network.sent, .sent))
                sparkline
            default:
                HStack(alignment: .bottom, spacing: InstrumentSpacing.panel) {
                    sparkline
                    VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                        LegendValue(title: String(localized: "↓ Empfangen"), value: network.received, hue: .received)
                        LegendValue(title: String(localized: "↑ Gesendet"), value: network.sent, hue: .sent)
                    }
                    .fixedSize()
                }
            }
        }
    }

    @ViewBuilder private var sparkline: some View {
        if let history = value.history {
            OverviewRateSparkline(history: history, hues: (.received, .sent))
        }
    }
}
