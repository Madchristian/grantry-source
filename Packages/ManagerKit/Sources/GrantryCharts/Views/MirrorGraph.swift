import SwiftUI

/// Zwei Reihen gespiegelt um die Mittellinie (Lesen/Schreiben, Empfangen/Senden; Spec §4) mit gemeinsamer Skala; rückt
/// wie `LiveGraph` je Messpunkt nach und zeichnet nicht im Bildtakt.
public struct MirrorGraph: View {
    let upper: ChartSeries
    let lower: ChartSeries
    let window: TimeInterval
    let minimum: Double
    /// Feste Farben oben/unten (`InstrumentHue`); ohne sie aus der Palette.
    let fixedColors: (upper: Color, lower: Color)?
    /// Punktraster und Mittellinie; Mini-Graphen zeigen beides nicht, damit eine Lücke ohne Messung leer bleibt wie bei
    /// den übrigen Graphen (Bewertung 2026.11.7, Mangel 7).
    let showsGrid: Bool

    @Environment(\.chartStyle) private var style

    /// Skala mit der Standard-Untergrenze von 1 MB/s, etwa für die Achsenbeschriftung.
    public nonisolated static let scale = ChartScale.automatic(minimum: 1_000_000)

    public init(upper: ChartSeries, lower: ChartSeries, window: TimeInterval = 60, minimum: Double = 1_000_000,
                colors: (upper: Color, lower: Color)? = nil, showsGrid: Bool = true) {
        self.upper = upper
        self.lower = lower
        self.window = window
        self.minimum = minimum
        fixedColors = colors
        self.showsGrid = showsGrid
    }

    private var target: Double { ChartScale.automatic(minimum: minimum).upperBound(for: upper.values + lower.values) }

    /// Farben der oberen und der unteren Reihe, etwa für eine Legende.
    public nonisolated static func colors(for style: ChartStyle) -> (upper: Color, lower: Color) {
        let palette = style.palette(.standard)
        return (palette.color(forLoad: 0.05), palette.color(forLoad: 0.8))
    }

    public var body: some View {
        Plot("MirrorGraph") { context, size in
            draw(in: &context, size: size)
        }
        .renderProbe("MirrorGraph")
        .accessibilityElement()
        .accessibilityLabel(Text("Durchsatz"))
    }

    private func draw(in context: inout PlotContext, size: CGSize) {
        let renderTime = upper.latest
        let maximum = target
        let half = CGSize(width: size.width, height: size.height / 2)
        let viewport = ChartViewport(window: window, range: 0...maximum, size: half)
        let colors = fixedColors ?? Self.colors(for: style)
        let top = GraphRenderer(style: style, color: colors.upper)
        let bottom = GraphRenderer(style: style, color: colors.lower)
        if showsGrid { top.drawGrid(in: &context, size: size, columns: 8, baseline: nil) }
        top.drawSeries(ChartGeometry.segments(for: upper, at: renderTime, in: viewport), in: &context, size: half)
        var mirrored = context
        mirrored.translateBy(x: 0, y: half.height)
        let downward = ChartGeometry.segments(for: lower, at: renderTime, in: viewport)
            .map { $0.map { CGPoint(x: $0.x, y: half.height - $0.y) } }
        bottom.drawSeries(downward, in: &mirrored, size: half, baseline: .top)
        guard showsGrid else { return }
        var axis = Path()
        axis.move(to: CGPoint(x: 0, y: half.height))
        axis.addLine(to: CGPoint(x: size.width, y: half.height))
        context.stroke(axis, with: .color(.primary.opacity(InstrumentOpacity.secondaryLine)), lineWidth: InstrumentStroke.base)
    }
}
