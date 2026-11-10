import SwiftUI

/// Verlauf eines festen Zeitraums aus verdichteten Spalten (Wachbuch, TM-12.5): Mittel als Linie mit Fläche, darum die
/// Hülle aus Minimum und Maximum, Punktraster an den Marken der Zeitachse. Kein Laufband und keine Uhr – gezeichnet wird
/// nur bei neuen Spalten oder neuer Größe (§ 4.4 Regel 1). Lücken bleiben leer (§ 3.4).
public struct TimelineGraph: View {
    let values: [TimelineValue?]
    let upperBound: Double
    let color: Color
    let gridPositions: [Double]

    @Environment(\.chartStyle) private var style

    public init(values: [TimelineValue?], upperBound: Double, color: Color, gridPositions: [Double]) {
        self.values = values
        self.upperBound = upperBound
        self.color = color
        self.gridPositions = gridPositions
    }

    public var body: some View {
        Plot("TimelineGraph") { context, size in
            let renderer = GraphRenderer(style: style, color: color)
            renderer.drawGrid(in: &context, size: size, positions: gridPositions)
            TimelineGraphDrawing.draw(values, upperBound: upperBound, with: renderer, in: &context, size: size,
                                      showsHead: values.last.map { $0 != nil } ?? false)
        }
        .renderProbe("TimelineGraph")
        .accessibilityHidden(true)
    }
}

/// Zwei Reihen gespiegelt um die Mittellinie (oben empfangen bzw. lesen, unten gesendet bzw. schreiben) mit gemeinsamer
/// Skala, sonst wie `TimelineGraph`.
public struct TimelineMirrorGraph: View {
    let upper: [TimelineValue?]
    let lower: [TimelineValue?]
    let upperBound: Double
    let colors: (upper: Color, lower: Color)
    let gridPositions: [Double]

    @Environment(\.chartStyle) private var style

    public init(upper: [TimelineValue?], lower: [TimelineValue?], upperBound: Double,
                colors: (upper: Color, lower: Color), gridPositions: [Double]) {
        self.upper = upper
        self.lower = lower
        self.upperBound = upperBound
        self.colors = colors
        self.gridPositions = gridPositions
    }

    public var body: some View {
        Plot("TimelineMirrorGraph") { context, size in
            let half = CGSize(width: size.width, height: size.height / 2)
            let top = GraphRenderer(style: style, color: colors.upper)
            top.drawGrid(in: &context, size: size, positions: gridPositions, baseline: nil)
            TimelineGraphDrawing.draw(upper, upperBound: upperBound, with: top, in: &context, size: half,
                                      showsHead: false)
            var mirrored = context
            mirrored.translateBy(x: 0, y: size.height)
            mirrored.scaleBy(x: 1, y: -1)
            TimelineGraphDrawing.draw(lower, upperBound: upperBound, with: GraphRenderer(style: style, color: colors.lower),
                                      in: &mirrored, size: half, showsHead: false)
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: half.height))
            axis.addLine(to: CGPoint(x: size.width, y: half.height))
            context.stroke(axis, with: .color(.primary.opacity(InstrumentOpacity.secondaryLine)),
                           lineWidth: InstrumentStroke.base)
        }
        .renderProbe("TimelineMirrorGraph")
        .accessibilityHidden(true)
    }
}

/// Gemeinsames Zeichnen beider Graphen: erst die Hülle, dann Linie und Fläche des Mittels.
enum TimelineGraphDrawing {
    static func draw(_ values: [TimelineValue?], upperBound: Double, with renderer: GraphRenderer,
                     in context: inout PlotContext, size: CGSize, showsHead: Bool) {
        let geometry = WatchbookTimelineGeometry.self
        renderer.drawEnvelope(upper: geometry.segments(values.map { $0?.maximum }, size: size, upperBound: upperBound),
                              lower: geometry.segments(values.map { $0?.minimum }, size: size, upperBound: upperBound),
                              in: &context)
        renderer.drawSeries(geometry.segments(values.map { $0?.mean }, size: size, upperBound: upperBound),
                            in: &context, size: size, showsHead: showsHead)
    }
}
