import GrantryCharts
import ManagerKit
import SwiftUI

/// Tafel der Übersicht in der Normalansicht (Spec 2026-11-09-uebersicht-baukasten § 4): die Kacheln der Anordnung im
/// Raster, jede in ihrer Größe. Bekommt die fertige Lage (`OverviewBoardLayout.placements()`), damit ein Takt nichts neu
/// anordnet; Kacheln stehen in Lesereihenfolge, so liest VoiceOver sie zeilenweise. Keine Animation – die gibt es nur
/// beim Ziehen im Bearbeitungsmodus (Teil A).
struct OverviewBoard: View {
    let placements: [OverviewTilePlacement]
    let source: OverviewTileSource
    let metrics: BoardGridMetrics
    let open: (OverviewTileKind) -> Void

    var body: some View {
        BoardGrid(metrics: metrics) {
            ForEach(OverviewGrid.readingOrder(placements)) { placement in
                OverviewTileContent(kind: placement.kind, span: placement.span, source: source) {
                    open(placement.kind)
                }
                .boardGridFrame(placement.boardGridFrame)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overviewBoard")
    }
}

extension OverviewTilePlacement {
    /// Lage im Raster von GrantryCharts, das keine ManagerKit-Typen kennt.
    var boardGridFrame: BoardGridFrame {
        BoardGridFrame(column: anchor.column, row: anchor.row, columns: span.columns, rows: span.rows)
    }
}

extension BoardGridCell {
    var overviewCell: OverviewGridCell { OverviewGridCell(column: column, row: row) }
}

// `TaskManagerPreviewData` gibt es nur im Debug-Build.
#if DEBUG
#Preview("Übersicht – Standard als Platzhalter") {
    OverviewBoard(placements: OverviewBoardLayout.standard(configured: Set(TaskManagerSource.allCases)).placements(),
                  source: OverviewTileSource(overview: MenuBarOverview(), history: nil),
                  metrics: BoardGridMetrics(width: 412)) { _ in }
        .padding()
}
#endif
