import SwiftUI

/// Rahmen um einen Graphen mit Beschriftung links und optional rechts (oben, Mitte, unten), etwa „100 % · 50 % · 0 %“
/// und „20 W · 10 W · 0 W“. Die Beschriftung ist statischer Text neben der Zeichenfläche und zeichnet nur bei neuer
/// Skala neu, nicht mit dem Laufband. Der Rahmen nimmt die Farbe der Messgröße (`frameColor`), ohne sie neutral.
public struct GraphAxes<Graph: View>: View {
    let leading: [String]
    let trailing: [String]
    let leadingColor: Color?
    let trailingColor: Color?
    let frameColor: Color?
    let graph: Graph

    public init(leading: [String], trailing: [String] = [], leadingColor: Color? = nil, trailingColor: Color? = nil,
                frameColor: Color? = nil, @ViewBuilder graph: () -> Graph) {
        self.leading = leading
        self.trailing = trailing
        self.leadingColor = leadingColor
        self.trailingColor = trailingColor
        self.frameColor = frameColor
        self.graph = graph()
    }

    public var body: some View {
        HStack(spacing: InstrumentSpacing.item) {
            labels(leading, color: leadingColor, alignment: .trailing)
            graph.graphFrame(frameColor)
            if !trailing.isEmpty {
                labels(trailing, color: trailingColor, alignment: .leading)
            }
        }
    }

    private func labels(_ texts: [String], color: Color?, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            ForEach(Array(texts.enumerated()), id: \.offset) { index, text in
                if index > 0 { Spacer(minLength: 0) }
                Text(verbatim: text)
            }
        }
        .font(InstrumentFont.micro.monospacedDigit())
        .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.instrumentSecondary))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Feiner Rahmen um eine Zeichenfläche wie bei einem Messschreiber: in der Farbe der Messgröße, ohne sie neutral.
    public func graphFrame(_ color: Color? = nil, cornerRadius: CGFloat = InstrumentRadius.graph) -> some View {
        modifier(GraphFrameModifier(color: color, cornerRadius: cornerRadius))
    }
}

private struct GraphFrameModifier: ViewModifier {
    let color: Color?
    let cornerRadius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let increased = contrast == .increased
        let tinted = increased ? InstrumentOpacity.graphFrameIncreased : InstrumentOpacity.graphFrame
        let neutral = increased ? InstrumentOpacity.graphFrameNeutralIncreased : InstrumentOpacity.graphFrameNeutral
        content
            .clipShape(shape)
            .overlay(shape.strokeBorder(color.map { AnyShapeStyle($0.opacity(tinted)) }
                                            ?? AnyShapeStyle(.primary.opacity(neutral)),
                                        lineWidth: InstrumentStroke.border))
    }
}
