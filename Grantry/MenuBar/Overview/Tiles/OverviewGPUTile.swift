import GrantryCharts
import ManagerKit
import SwiftUI

/// Kachel „GPU“ des Übersichts-Baukastens (Spec 2026-11-09-uebersicht-baukasten § 2): 1 × 1 Ring mit Wert, 2 × 1 Wert,
/// Verlauf und Kennzahlen (Grafikspeicher, Takt), 2 × 2 wie die Karte aus PR 623 mit den Ringen Auslastung und Speicher,
/// dem belegten Grafikspeicher und dem Takt im Kopf, 4 × 1 langer Verlauf mit Kennzahlen rechts.
struct OverviewGPUTile: OverviewTile {
    struct Value {
        let gpu: MenuBarOverview.GPU
        /// Auslastung der letzten Minute; `nil` bei geschlossenem Popover.
        let history: ChartSeries?
    }

    static let kind = OverviewTileKind.gpu

    let value: Value
    let span: OverviewTileSpan
    let open: () -> Void

    @Environment(\.self) private var environment

    static func value(from source: OverviewTileSource) -> Value? {
        source.overview.gpu.map { gpu in
            Value(gpu: gpu, history: source.history?.series(.gpu, in: .oneMinute))
        }
    }

    var body: some View {
        let gpu = value.gpu
        switch span {
        case .small:
            OverviewCard(title: Self.kind.title, spokenValue: gpu.value, open: open) {
                TileRing(fraction: gpu.utilization, value: gpu.value, hue: .gpu)
            }
        case .large:
            OverviewCard(title: Self.kind.title, detail: gpu.clock ?? "", value: gpu.value,
                         valueColor: environment.instrumentTextColor(.gpu), open: open) {
                VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
                    HStack(spacing: InstrumentSpacing.panel) {
                        ForEach(gpu.rings) { ring in
                            ValueRing(parts: [ValueRing.Part(fraction: ring.fraction, hue: .gpu)], value: ring.value,
                                      caption: ring.caption)
                        }
                    }
                    // Unten in der Kachel wie in der Karte aus PR 623, statt mit freiem Streifen darunter.
                    if let memory = gpu.memory {
                        Spacer(minLength: 0)
                        FactRow(title: String(localized: "Speicher"), value: memory)
                    }
                }
                .fillsOverviewTile()
            }
        default:
            OverviewCard(title: Self.kind.title, value: gpu.value, valueColor: environment.instrumentTextColor(.gpu),
                         open: open) {
                content.fillsOverviewTile()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if span == .banner {
            HStack(alignment: .bottom, spacing: InstrumentSpacing.panel) {
                trace
                VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                    ForEach(facts, id: \.title) { fact in FactLine([fact]) }
                }
                .fixedSize()
            }
        } else {
            VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
                trace
                if !facts.isEmpty {
                    FactLine(facts)
                }
            }
        }
    }

    private var trace: some View {
        OverviewTileTrace(fraction: value.gpu.utilization, hue: .gpu, graph: value.history.map { history in
            Sparkline(series: history, scale: .fixed(0...1), color: environment.instrumentColor(.gpu))
        })
    }

    /// Grafikspeicher und Takt, je nur mit Messung.
    private var facts: [PanelFact] {
        var facts: [PanelFact] = []
        if let memory = value.gpu.memory {
            facts.append(PanelFact(String(localized: "Speicher"), memory))
        }
        if let clock = value.gpu.clock {
            facts.append(PanelFact(String(localized: "Takt"), clock))
        }
        return facts
    }
}
