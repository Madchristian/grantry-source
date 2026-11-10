import SwiftUI

/// Säulen eines Verlaufs (App-Verlauf, Spec §6 Stufe 2) im Stil der Graphen (§3.4): Säule in der Farbe der Messgröße,
/// Deckkraft nach Höhe wie die Hitze der Tabellen (§2.6), Kante oben in voller Farbe. Abschnitte ohne Messung zeigen eine
/// gestrichelte Grundlinie statt einer Säule – „nicht gemessen“ ist nicht 0. Hover hebt eine Säule hervor und zeigt
/// ihren Text auf einer Fläche wie ein Panel (kein Material, kein Unschärfe-Filter).
public struct UsageBarChart: View {
    public struct Bar: Hashable, Sendable, Identifiable {
        public let id: Int
        public let value: Double
        /// Ob in diesem Abschnitt gemessen wurde.
        public let isMeasured: Bool
        /// Achsenbeschriftung; leer = keine.
        public let label: String
        /// Text für Hover und VoiceOver, z. B. „Mo: 1 h 12 min“.
        public let detail: String

        public init(id: Int, value: Double, isMeasured: Bool, label: String, detail: String) {
            self.id = id
            self.value = value
            self.isMeasured = isMeasured
            self.label = label
            self.detail = detail
        }
    }

    let bars: [Bar]
    let hue: InstrumentHue

    @Environment(\.chartStyle) private var style
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.self) private var environment
    @State private var hovered: Int?

    public init(bars: [Bar], hue: InstrumentHue = .cpu) {
        self.bars = bars
        self.hue = hue
    }

    public var body: some View {
        let layout = UsageBarLayout(values: bars.map(\.value))
        VStack(spacing: InstrumentSpacing.item) {
            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    grid(layout, height: proxy.size.height)
                    HStack(alignment: .bottom, spacing: spacing(for: proxy.size.width)) {
                        ForEach(Array(bars.enumerated()), id: \.element.id) { index, bar in
                            column(bar, fraction: layout.fractions[index], height: proxy.size.height)
                        }
                    }
                }
            }
            HStack(spacing: 0) {
                ForEach(bars) { bar in
                    Text(verbatim: bar.label)
                        .font(InstrumentFont.micro.monospacedDigit())
                        .foregroundStyle(.instrumentSecondary)
                        .fixedSize()
                        .frame(maxWidth: .infinity)
                }
            }
            // Die Säulen nennen ihre Beschriftung selbst.
            .accessibilityHidden(true)
        }
        // Die laufende Säule wächst mit jedem Takt; weich wechselt die Höhe erst über eine Zehntelstufe hinweg, etwa
        // beim Wechsel von Zeitraum oder Kennzahl.
        .animatesSteps(of: layout.fractions, when: style.animates)
        .renderProbe("UsageBarChart")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Verlauf"))
    }

    private func spacing(for width: CGFloat) -> CGFloat {
        bars.isEmpty ? 0 : min(InstrumentSpacing.group, max(InstrumentSpacing.stack, width / CGFloat(bars.count) * 0.25))
    }

    private func grid(_ layout: UsageBarLayout, height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            ForEach(layout.gridFractions, id: \.self) { fraction in
                Rectangle()
                    .fill(.primary.opacity(InstrumentOpacity.well))
                    .frame(height: InstrumentStroke.base)
                    .offset(y: -height * fraction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func column(_ bar: Bar, fraction: Double, height: CGFloat) -> some View {
        let color = environment.instrumentColor(hue)
        let isHovered = hovered == bar.id
        let shape = UnevenRoundedRectangle(topLeadingRadius: InstrumentRadius.graph, topTrailingRadius: InstrumentRadius.graph)
        return ZStack(alignment: .bottom) {
            Color.clear
            if bar.isMeasured {
                ZStack(alignment: .top) {
                    shape.fill(color.opacity(isHovered ? InstrumentOpacity.barHovered
                                                 : InstrumentOpacity.barBase + InstrumentOpacity.barRange * fraction))
                    Capsule().fill(color).frame(height: InstrumentStroke.focus)
                }
                .frame(height: max(height * fraction, bar.value > 0 ? 3 : 1))
            } else {
                Rectangle()
                    .stroke(style: StrokeStyle(lineWidth: InstrumentStroke.border, dash: [2, 3]))
                    .foregroundStyle(.instrumentSecondary)
                    .frame(height: InstrumentStroke.border)
            }
        }
        .overlay(alignment: .top) {
            if isHovered {
                Text(verbatim: bar.detail)
                    .font(InstrumentFont.label.monospacedDigit())
                    .padding(.horizontal, InstrumentSpacing.group)
                    .padding(.vertical, InstrumentSpacing.inline)
                    .background(Capsule().fill(InstrumentSurface.panel(colorScheme)))
                    .overlay(Capsule().strokeBorder(color, lineWidth: InstrumentStroke.border))
                    .fixedSize()
                    .offset(y: -InstrumentSpacing.group)
                    .zIndex(1)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? bar.id : (hovered == bar.id ? nil : hovered) }
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: bar.detail))
    }
}
