import GrantryCharts
import ManagerKit
import SwiftUI

/// Zugang des Leistung-Tabs zum Wachbuch (TM-14.5): Verlauf, Stand der Einstellung „Wachbuch führen“ und Einschalten.
struct PowerHistoryAccess {
    let model: PowerHistoryModel
    let isWatchbookEnabled: Bool
    let enableWatchbook: () -> Void
}

/// Leistungsaufnahme über 1 h bis 7 Tage aus dem Wachbuch (Spec 2026-11-08 §5.3): Verlauf gesamt oder je Block mit
/// Zeitachse, Lücken bleiben leer und werden erklärt, darunter die Messfelder über den Zeitraum. Liest nur, solange der
/// Abschnitt sichtbar ist, und dann je neuer Spalte (`PowerHistoryModel.follow`) – kein eigener Bildtakt.
struct PowerHistorySection: View {
    let period: WatchbookPeriod
    let perBlock: Bool
    let access: PowerHistoryAccess

    /// Spalten des Graphen; 0 bis zur ersten Größe.
    @State private var columns = 0

    private struct Request: Hashable {
        let period: WatchbookPeriod
        let columns: Int
    }

    var body: some View {
        let page = access.model.page
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            graph(page)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: Int.self) { Self.columns(forWidth: $0.size.width) } action: { columns = $0 }
            if let page, page.hasValues, !page.isComplete {
                Label {
                    Text("Aus dem Wachbuch: gemessen, solange Leistung, Chip oder Übersicht offen war. Lücken bleiben leer.")
                } icon: { Image(systemName: "info.circle") }
                    .font(InstrumentFont.label)
                    .foregroundStyle(.instrumentSecondary)
            }
            StatGrid(stats: page?.stats ?? PowerHistoryPage.placeholderStats)
        }
        .task(id: Request(period: period, columns: columns)) {
            guard columns > 0 else { return }
            await access.model.follow(period, width: columns)
        }
    }

    @ViewBuilder
    private func graph(_ page: PowerHistoryPage?) -> some View {
        if let page, page.period == period, page.hasValues {
            TrendGraph(String(localized: "Leistungsaufnahme, \(period.title)"),
                       lines: (perBlock ? PowerPart.blocks : [.total]).map { part in
                           TrendGraph.Line(series: ChartSeries(values: page.values(part), spacing: page.spacing,
                                                               latest: page.end),
                                           hue: part.hue)
                       },
                       window: page.window, minimum: 5, format: GraphAxisLabels.watts)
        } else if !access.isWatchbookEnabled {
            GraphNotice(String(localized: "Längere Zeiträume liest Grantry aus dem Wachbuch. Es ist ausgeschaltet."),
                        actionTitle: String(localized: "Wachbuch einschalten"), action: access.enableWatchbook)
        } else if page?.period == period {
            GraphNotice(String(localized: """
                Im Zeitraum gibt es noch keine Leistungswerte. Das Wachbuch hält sie fest, solange Leistung, Chip oder \
                Übersicht geöffnet ist.
                """))
        } else {
            GraphNotice(String(localized: "Das Wachbuch wird gelesen …"))
        }
    }

    /// Höchstens eine Spalte je Punkt (Spec §4.4 Regel 5), auf 8 Punkte gerundet: Ein Ziehen am Fenster liest das
    /// Wachbuch nicht bei jedem Pixel neu.
    nonisolated static func columns(forWidth width: CGFloat) -> Int {
        max(Int(width / 8) * 8, 0)
    }
}
