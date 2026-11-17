import GrantryCharts
import ManagerKit
import SwiftUI

/// Kachel „Arbeitsspeicher“ des Übersichts-Baukastens (Spec 2026-11-09-uebersicht-baukasten § 2): 1 × 1 Ring mit dem
/// belegten Anteil, 2 × 1 Anteile als Spur mit kurzer Legende, 2 × 2 mit den Werten der Karte aus PR 623 (Größe je
/// Bestandteil und Swap als Tabelle, Druck, belegt von gesamt), 4 × 1 alles in einer Zeile.
struct OverviewMemoryTile: OverviewTile {
    static let kind = OverviewTileKind.memory

    let value: MenuBarOverview.Memory
    let span: OverviewTileSpan
    let open: () -> Void

    @Environment(\.self) private var environment

    static func value(from source: OverviewTileSource) -> MenuBarOverview.Memory? { source.overview.memory }

    var body: some View {
        let memory = value
        if span == .small {
            OverviewCard(title: String(localized: "Speicher"), spokenValue: memory.spokenValue, open: open) {
                TileRing(fraction: memory.usedShare, value: memory.value, hue: .memory)
            }
        } else {
            OverviewCard(title: Self.kind.title, detail: span == .banner ? memory.detail : "", value: memory.value,
                         spokenValue: memory.spokenValue, valueColor: environment.instrumentTextColor(.memory),
                         open: open) {
                parts
                switch span {
                case .large:
                    VStack(spacing: InstrumentSpacing.stack) {
                        ForEach(memory.parts) { part in
                            LegendValue(title: part.title, value: part.amount, hue: part.kind.hue, isSpread: true)
                        }
                        // Bündig mit den Bezeichnungen der Legende darüber, ohne deren Strich: Swap ist kein Teil der
                        // Spur.
                        FactRow(title: String(localized: "Swap"), value: memory.swap)
                            .padding(.leading, InstrumentSize.legendStroke.width + InstrumentSpacing.inline)
                    }
                    // Druck und Belegung unten in der Kachel, bündig mit dem Grafikspeicher der GPU daneben.
                    Spacer(minLength: 0)
                    // Abstand wie in der Karte aus PR 623 beiderseits eines `Spacer`.
                    FittingLine(spacing: 2 * InstrumentSpacing.group, stackedSpacing: InstrumentSpacing.stack,
                                isJustified: true) {
                        pressure
                        Text(verbatim: memory.detail).font(InstrumentFont.label.monospacedDigit())
                            .foregroundStyle(.instrumentSecondary).lineLimit(1)
                    }
                case .banner:
                    HStack(spacing: InstrumentSpacing.group) {
                        ForEach(memory.parts) { part in
                            LegendValue(title: part.shortTitle, value: part.amount, hue: part.kind.hue).fixedSize()
                        }
                        Spacer(minLength: 0)
                        pressure
                    }
                default:
                    HStack(spacing: InstrumentSpacing.item) {
                        ForEach(memory.parts) { part in
                            LegendItem(title: part.shortTitle, hue: part.kind.hue)
                        }
                    }
                }
            }
        }
    }

    /// Belegte Teile hintereinander; ihre Namen stehen in der Legende bzw. im Wert für VoiceOver.
    private var parts: some View {
        PartsSpur(parts: value.parts.map { ValueRing.Part(fraction: $0.share, hue: $0.kind.hue) }, label: "", value: "")
            .frame(height: InstrumentSize.spurList)
    }

    private var pressure: some View {
        StatusChip(String(localized: "Druck \(value.pressureText)"), tone: pressureTone, isSmall: true)
    }

    private var pressureTone: StatusTone {
        switch value.pressure {
        case .normal?: .positive
        case .warning?: .finding
        case .critical?: .critical
        case nil: .neutral
        }
    }
}
