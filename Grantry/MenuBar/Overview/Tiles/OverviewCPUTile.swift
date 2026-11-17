import GrantryCharts
import ManagerKit
import SwiftUI

/// Kachel „CPU“ des Übersichts-Baukastens (Spec 2026-11-09-uebersicht-baukasten § 2): 1 × 1 Ring mit Wert, 2 × 1 Wert und
/// Verlauf, 2 × 2 Verlauf, Anteile und Takt. 4 × 1 wie die Karte aus PR 623: Takt, Benutzer und System im Kopf, darunter
/// der Verlauf über die ganze Breite; 4 × 2 dazu Kennzahlen.
struct OverviewCPUTile: OverviewTile {
    struct Value {
        let cpu: MenuBarOverview.CPU
        /// Gesamtlast und Systemanteil der letzten Minute; `nil` bei geschlossenem Popover.
        let history: (total: ChartSeries, system: ChartSeries)?
    }

    static let kind = OverviewTileKind.cpu

    let value: Value
    let span: OverviewTileSpan
    let open: () -> Void

    @Environment(\.self) private var environment

    static func value(from source: OverviewTileSource) -> Value? {
        source.overview.cpu.map { cpu in
            Value(cpu: cpu, history: source.history.map {
                ($0.series(.cpuTotal, in: .oneMinute), $0.series(.cpuSystem, in: .oneMinute))
            })
        }
    }

    var body: some View {
        let cpu = value.cpu
        switch span {
        case .small:
            OverviewCard(title: Self.kind.title, spokenValue: cpu.value, open: open) {
                TileRing(fraction: cpu.total, value: cpu.value, hue: .cpu)
            }
        case .banner, .panel:
            OverviewCard(title: Self.kind.title, detail: cpu.clock ?? "", value: cpu.value,
                         valueColor: environment.instrumentTextColor(.cpu), open: open) {
                HStack(spacing: InstrumentSpacing.cell) { shares }
            } content: {
                VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
                    trace
                    if span == .panel {
                        FactLine(facts)
                    }
                }
                .fillsOverviewTile()
            }
        default:
            OverviewCard(title: Self.kind.title, value: cpu.value, valueColor: environment.instrumentTextColor(.cpu),
                         open: open) {
                Group {
                    if span == .large {
                        VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
                            trace
                            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) { shares }
                            if let clock = cpu.clock {
                                FactLine([PanelFact(String(localized: "Takt"), clock)])
                            }
                        }
                    } else {
                        trace
                    }
                }
                .fillsOverviewTile()
            }
        }
    }

    private var trace: some View {
        OverviewTileTrace(fraction: value.cpu.total, hue: .cpu, graph: value.history.map { history in
            StackedSparkline(lower: history.system, total: history.total,
                             colors: (lower: CPUShare.system.hue, upper: CPUShare.user.hue))
        })
    }

    /// Benutzer und System; im Kopf nebeneinander, in 2 × 2 untereinander.
    @ViewBuilder
    private var shares: some View {
        LegendValue(title: String(localized: "Benutzer"), value: value.cpu.userText, hue: CPUShare.user.hue)
        LegendValue(title: String(localized: "System"), value: value.cpu.systemText, hue: CPUShare.system.hue)
    }

    /// Kennzahlen unter dem Verlauf (4 × 2): Leerlauf, Spitze nur mit Verlauf; der Takt steht im Kopf.
    private var facts: [PanelFact] {
        var facts = [PanelFact(String(localized: "Leerlauf"), value.cpu.idleText)]
        if let history = value.history {
            facts.append(PanelFact(String(localized: "Spitze 60 s"), MenuBarOverview.peakText(of: history.total.values)))
        }
        return facts
    }
}
