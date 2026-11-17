import GrantryCharts
import ManagerKit
import SwiftUI

// Gemeinsame Teile der Ressourcen-Kacheln (Spec 2026-11-09-uebersicht-baukasten § 2, Teil C #502): großer Wert für
// 1 × 1, Raten mit Pfeil und Spiegelverlauf für Datenträger und Netz, Galerie aller Größen für Vorschau und Snapshot.

/// Großer Wert mit Zusatzzeile, der Inhalt einer 1 × 1-Kachel (Thermik, Akku, Last, Laufzeit, Datenträger).
struct OverviewFigure: View {
    let value: String
    var detail = ""
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: value)
                .font(InstrumentFont.value)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if !detail.isEmpty {
                Text(verbatim: detail).font(InstrumentFont.micro).foregroundStyle(.instrumentSecondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Rate mit Richtung („↓ 1,2 MB/s“) in der Farbe der Messgröße; schmal genug für 1 × 1, wo der Legendenstrich nicht
/// mehr passt. Die Richtung steht als Zeichen da, nicht nur als Farbe.
struct OverviewRateLine: View {
    let symbol: String
    let value: String
    let hue: InstrumentHue

    @Environment(\.self) private var environment

    var body: some View {
        Text(verbatim: "\(symbol) \(value)")
            .font(InstrumentFont.numeric)
            .foregroundStyle(environment.instrumentTextColor(hue))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// Zwei Raten der letzten Minute (Lesen/Schreiben, Empfangen/Gesendet) für den Spiegelverlauf.
struct OverviewRateHistory: Equatable {
    let upper: ChartSeries
    let lower: ChartSeries

    init?(_ history: ChartHistory?, upper: MetricKey, lower: MetricKey) {
        guard let history else { return nil }
        self.upper = history.series(upper, in: .oneMinute)
        self.lower = history.series(lower, in: .oneMinute)
    }
}

/// Wert einer Kachel mit Raten und ihrem Verlauf; ohne Verlauf (Popover zu) zeichnet die Kachel keinen Graphen.
struct OverviewRateReading<Base: Equatable>: Equatable {
    let base: Base
    let history: OverviewRateHistory?
}

/// Spiegelverlauf zweier Raten; füllt die Höhe, die ihm die Kachel lässt. Die Werte nennt die Legende daneben.
struct OverviewRateSparkline: View {
    let history: OverviewRateHistory
    let hues: (upper: InstrumentHue, lower: InstrumentHue)

    @Environment(\.self) private var environment

    var body: some View {
        MirrorSparkline(upper: history.upper, lower: history.lower,
                        colors: (environment.instrumentColor(hues.upper), environment.instrumentColor(hues.lower)))
            .frame(maxHeight: .infinity)
            .accessibilityHidden(true)
    }
}

// `TaskManagerPreviewData` gibt es nur im Debug-Build.
#if DEBUG
/// Ressourcen-Kacheln in jeder erlaubten Größe auf dem Raster der Tafel, über `OverviewTileContent` wie in der App;
/// für die Vorschau je Kachel und die Snapshot-Szene „baukasten-ressourcen“.
struct OverviewResourceTileGallery: View {
    static let resourceKinds: [OverviewTileKind] = [.memory, .disk, .network, .thermal, .battery, .loadAverage, .uptime]
    static let metrics = BoardGridMetrics(width: 412)

    var kinds = Self.resourceKinds
    var measuredAt = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Geordnet, damit jede Kachel ihre Größen nebeneinander zeigt. Die Kachel des Kits heißt wie das Protokoll der App,
    /// daher `.init`.
    var placements: [OverviewTilePlacement] {
        OverviewGrid(packing: .ordered).place(kinds.flatMap { kind in kind.allowedSpans.map { .init(kind, $0) } })
    }

    /// Höhe der Szene für alle Kacheln samt Rand.
    static var size: CGSize {
        let rows = OverviewGrid().rowCount(of: OverviewResourceTileGallery().placements)
        return CGSize(width: 440, height: metrics.height(rows: rows) + InstrumentSpacing.page * 2)
    }

    var body: some View {
        let sample = TaskManagerPreviewData.overviewSample(performance: 12, efficiency: 4, name: "Apple M4 Max")
        let overview = MenuBarOverviewPresentation.overview(for: sample.frame.snapshot, profile: sample.profile,
                                                            context: sample.context)
        let source = OverviewTileSource(overview: overview,
                                        history: ChartHistory(history: sample.frame.history, measuredAt: measuredAt))
        BoardGrid(metrics: Self.metrics) {
            ForEach(Array(placements.enumerated()), id: \.offset) { _, placement in
                OverviewTileContent(kind: placement.kind, span: placement.span, source: source) {}
                    .boardGridFrame(placement.boardGridFrame)
            }
        }
        .padding(InstrumentSpacing.page)
        .frame(width: 440, alignment: .topLeading)
    }
}

#Preview("Ressourcen – alle Größen") {
    ScrollView { OverviewResourceTileGallery() }
}
#endif
