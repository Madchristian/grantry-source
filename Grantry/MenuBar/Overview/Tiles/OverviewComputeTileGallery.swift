import GrantryCharts
import ManagerKit
import SwiftUI

// `TaskManagerPreviewData` gibt es nur im Debug-Build.
#if DEBUG
/// Kacheln CPU, Kerne, Prozesse und GPU in allen erlaubten Größen auf dem Raster der Tafel, über den Verteiler
/// `OverviewTileContent` wie in der Übersicht: Vorschau und Snapshot-Szene „baukasten-rechenwerke“
/// (`scripts/performance/task_manager_snapshots.swift`). Eine Prozess-Kachel ohne Messung zeigt „nicht gemessen“; die
/// Kerne stehen zum Schluss noch einmal für einen Chip mit drei Kernklassen (Super-, Leistungs-, Effizienzkerne, #589).
struct OverviewComputeTileGallery: View {
    static let metrics = BoardGridMetrics(width: 412)
    static var size: CGSize {
        let rows = (tiles.map { $0.row + $0.span.rows }.max() ?? 0)
        return CGSize(width: 440, height: metrics.height(rows: rows) + InstrumentSpacing.page * 2)
    }

    /// Stand je Beispiel: M4 Max mit Takt, ohne Messung und ein Chip mit drei Kernklassen.
    enum Sample {
        case measured, unmeasured, threeClasses
    }

    let sources: [Sample: OverviewTileSource]

    init(measuredAt: Date = .now) {
        let sample = TaskManagerPreviewData.overviewSample(performance: 12, efficiency: 4, name: "Apple M4 Max")
        var context = sample.context
        context.sensors = SensorReading(
            clusters: [SensorReading.Cluster(name: "P0", frequencyMHz: 3_228, activeShare: 0.6),
                       SensorReading.Cluster(name: "P1", frequencyMHz: 3_228, activeShare: 0.4)],
            gpuFrequencyMHz: 1_180
        )
        let threeClasses = TaskManagerPreviewData.overviewSample(
            levels: [.init(name: "Super", type: "S", count: 4), .init(name: "Performance", type: "P", count: 6),
                     .init(name: "Efficiency", type: "E", count: 4)],
            name: "Apple-Chip mit drei Kernklassen")
        let source = { (sample: TaskManagerPreviewData.OverviewSample, context: MenuBarOverviewContext) in
            OverviewTileSource(overview: MenuBarOverviewPresentation.overview(for: sample.frame.snapshot,
                                                                              profile: sample.profile,
                                                                              context: context),
                               history: ChartHistory(history: sample.frame.history, measuredAt: measuredAt))
        }
        sources = [.measured: source(sample, context), .unmeasured: Self.unmeasured,
                   .threeClasses: source(threeClasses, threeClasses.context)]
    }

    /// Lage je Kachel: Spalte, Zeile, Art, Größe und welches Beispiel sie zeigt.
    struct Tile {
        let column: Int
        let row: Int
        let kind: OverviewTileKind
        let span: OverviewTileSpan
        let sample: Sample

        init(_ column: Int, _ row: Int, _ kind: OverviewTileKind, _ span: OverviewTileSpan,
             sample: Sample = .measured) {
            self.column = column
            self.row = row
            self.kind = kind
            self.span = span
            self.sample = sample
        }
    }

    static let tiles: [Tile] = [
        Tile(0, 0, .cpu, .small), Tile(1, 0, .cpu, .wide), Tile(3, 0, .gpu, .small),
        Tile(0, 1, .cpu, .large), Tile(2, 1, .gpu, .large),
        Tile(0, 3, .cpu, .banner),
        Tile(0, 4, .cpu, .panel),
        Tile(0, 6, .cores, .wide), Tile(2, 6, .gpu, .wide),
        Tile(0, 7, .cores, .large), Tile(2, 7, .processes, .large),
        Tile(0, 9, .cores, .banner),
        Tile(0, 10, .cores, .panel),
        Tile(0, 12, .processes, .wide), Tile(2, 12, .processes, .wide, sample: .unmeasured),
        Tile(0, 13, .processes, .banner),
        Tile(0, 14, .processes, .panel),
        Tile(0, 16, .gpu, .banner),
        Tile(0, 17, .cores, .wide, sample: .threeClasses), Tile(2, 17, .cores, .large, sample: .threeClasses),
        Tile(0, 19, .cores, .banner, sample: .threeClasses),
        Tile(0, 20, .cores, .panel, sample: .threeClasses),
    ]

    var body: some View {
        BoardGrid(metrics: Self.metrics) {
            ForEach(Self.tiles.indices, id: \.self) { index in
                let tile = Self.tiles[index]
                OverviewTileContent(kind: tile.kind, span: tile.span, source: sources[tile.sample] ?? Self.unmeasured) {}
                    .boardGridFrame(BoardGridFrame(column: tile.column, row: tile.row, columns: tile.span.columns,
                                                   rows: tile.span.rows))
            }
        }
        .padding(InstrumentSpacing.page)
        .frame(width: Self.size.width, alignment: .topLeading)
    }

    private static let unmeasured = OverviewTileSource(overview: MenuBarOverview(), history: nil)
}

#Preview("Rechenwerke in allen Größen") {
    ScrollView { OverviewComputeTileGallery() }
        .frame(height: 800)
        .instrumentBackground()
}
#endif
