import GrantryCharts
import ManagerKit
import SwiftUI

/// Kachel „Kerne“ des Übersichts-Baukastens (Spec 2026-11-09-uebersicht-baukasten § 2): klein die Mittelwerte je Kernart
/// (2 × 1 als Spuren, 2 × 2 als Ringe, bei drei Kernklassen als Spuren). 4 × 1 wie die Karte aus PR 623: Ringe je Kern
/// nach Cluster („P0“, „P1“, „E“), die wachsen, bis die Reihe die Breite füllt, mit den Mittelwerten im Kopf, bei drei
/// Kernklassen (Super-, Leistungs-, Effizienzkerne, #589) nur mit Kürzel, damit sie in die Zeile passen. 4 × 2 darunter die
/// Mittelwerte als Ringe mit der Zahl der Kerne. Ohne `ViewThatFits` (#626): Die Wahl folgt aus der Zahl der Kernklassen,
/// die Anordnung der Ringe aus Breite und Höhe der Kachel (`CoreRingBoard`).
struct OverviewCoresTile: OverviewTile {
    static let kind = OverviewTileKind.cores

    let value: MenuBarOverview.Cores
    let span: OverviewTileSpan
    let open: () -> Void

    static func value(from source: OverviewTileSource) -> MenuBarOverview.Cores? { source.overview.cores }

    /// Mehr Kernklassen passen nicht ausgeschrieben in eine Zeile von 4 × 1 und nicht als Ringe in 2 × 2.
    private var hasManyClasses: Bool { value.averages.count > 2 }

    var body: some View {
        switch span {
        case .wide:
            OverviewCard(title: Self.kind.title, spokenValue: value.spokenSummary, open: open) {
                CoreAverageSpurs(averages: value.averages).fillsOverviewTile(alignment: .bottomLeading)
            }
        case .large:
            OverviewCard(title: Self.kind.title, spokenValue: value.spokenSummary, open: open) {
                Group {
                    if hasManyClasses {
                        CoreAverageSpurs(averages: value.averages, rowSpacing: InstrumentSpacing.cell)
                    } else {
                        CoreAverageRings(averages: value.averages)
                    }
                }
                .fillsOverviewTile(alignment: .center)
            }
        case .panel:
            OverviewCard(title: Self.kind.title, spokenValue: value.spokenSummary, open: open) {
                VStack(alignment: .leading, spacing: InstrumentSpacing.group) {
                    CoreRingBoard(groups: value.ringGroups).fillsOverviewTile()
                    CoreAverageRings(averages: value.averages)
                }
            }
        default:
            OverviewCard(title: Self.kind.title, spokenValue: value.spokenSummary, open: open) {
                CoreAverageLegend(averages: value.averages, isShort: hasManyClasses)
            } content: {
                CoreRingBoard(groups: value.ringGroups).fillsOverviewTile()
            }
        }
    }
}

/// Mittelwerte je Kernart als Legende im Kopf: ausgeschrieben mit Kürzel („Leistungskerne (P) 70 %“), passen sie nicht
/// nebeneinander, untereinander (`FittingLine`); kurz nur mit Kürzel („P 70 %“).
private struct CoreAverageLegend: View {
    let averages: [MenuBarOverview.CoreAverage]
    let isShort: Bool

    var body: some View {
        FittingLine(spacing: InstrumentSpacing.cell, stackedSpacing: InstrumentSpacing.inline) {
            ForEach(averages) { average in
                LegendValue(title: isShort ? average.tag ?? average.title : average.legendTitle, value: average.value,
                            hue: average.kind.hue)
            }
        }
    }
}

/// Mittelwert je Kernart als Spur mit Kürzel und Wert, untereinander; Kürzel und Werte stehen in Spalten.
private struct CoreAverageSpurs: View {
    let averages: [MenuBarOverview.CoreAverage]
    var rowSpacing = InstrumentSpacing.stack

    @Environment(\.self) private var environment

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: InstrumentSpacing.inline, verticalSpacing: rowSpacing) {
            ForEach(averages) { average in
                GridRow {
                    Text(verbatim: average.tag ?? average.title)
                        .font(InstrumentFont.micro.weight(.semibold))
                        .foregroundStyle(environment.instrumentTextColor(average.kind.hue))
                    Spur(fraction: average.load, color: environment.instrumentColor(average.kind.hue))
                        .frame(height: InstrumentSize.spurList)
                    Text(verbatim: average.value)
                        .font(InstrumentFont.numeric)
                        .gridColumnAlignment(.trailing)
                }
                .accessibilityReading(Text(verbatim: average.title), value: Text(verbatim: average.value))
            }
        }
    }
}

/// Mittelwert je Kernart als Wertring mit der Anzahl der Kerne darunter („12 P-Kerne“).
private struct CoreAverageRings: View {
    let averages: [MenuBarOverview.CoreAverage]

    var body: some View {
        HStack(spacing: InstrumentSpacing.bar) {
            ForEach(averages) { average in
                ValueRing(parts: [ValueRing.Part(fraction: average.load ?? 0, hue: average.kind.hue)],
                          value: average.value, caption: average.countText)
            }
        }
    }
}

extension MenuBarOverview.Cores {
    /// Gruppen der Kernringe für GrantryCharts; ohne Cluster-Kürzel das Kürzel der Kernart.
    var ringGroups: [CoreRingBoard.Group] {
        groups.map { group in
            CoreRingBoard.Group(tag: group.label ?? averages.first { $0.kind == group.kind }?.tag, hue: group.kind.hue,
                                rings: group.rings.map { ring in
                                    CoreRingBoard.Ring(id: ring.id, load: ring.load, label: ring.accessibilityLabel,
                                                       value: ring.accessibilityValue)
                                })
        }
    }
}

extension MenuBarOverview.CoreAverage {
    /// „Super-Kerne (S)“, „Leistungskerne (P)“: das Kürzel verbindet den Mittelwert mit den Gruppen darüber, auch ohne
    /// Farbe.
    var legendTitle: String {
        tag.map { "\(title) (\($0))" } ?? title
    }
}
