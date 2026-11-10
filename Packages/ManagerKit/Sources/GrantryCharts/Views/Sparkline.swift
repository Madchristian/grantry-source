import SwiftUI

/// Stiller Verlauf (§3.4) je Tabellenzeile, in Karten und Kern-Zellen: dieselbe monotone Kurve und Fläche wie die großen
/// Graphen (`GraphRenderer`), in der Farbe der Messgröße; optional Punktraster und Peilpunkt. Eine Tabelle zeigt Dutzende
/// davon; jede zeichnet nur neu, wenn ein Takt ankommt (Leistungsbudget Spec §4).
public struct Sparkline: View {
    let series: ChartSeries
    let window: TimeInterval
    let scale: ChartScale
    let color: Color
    let showsGrid: Bool
    let showsMarker: Bool

    @Environment(\.chartStyle) private var style

    public init(series: ChartSeries, window: TimeInterval = 60, scale: ChartScale = .automatic(minimum: 0.05),
                color: Color, showsGrid: Bool = false, showsMarker: Bool = false) {
        self.series = series
        self.window = window
        self.scale = scale
        self.color = color
        self.showsGrid = showsGrid
        self.showsMarker = showsMarker
    }

    public var body: some View {
        curves
        .renderProbe("Sparkline")
        .background(RoundedRectangle(cornerRadius: InstrumentRadius.graph, style: .continuous)
            .fill(.primary.opacity(InstrumentOpacity.subtle)))
        .clipShape(RoundedRectangle(cornerRadius: InstrumentRadius.graph, style: .continuous))
        .accessibilityReading(Text("Verlauf"), value: Text(accessibilityValue))
    }

    @ViewBuilder
    private var curves: some View {
        if showsGrid || showsMarker {
            Plot("Sparkline") { context, size in
                draw(in: &context, size: size)
            }
        } else {
            curve
        }
    }

    /// Ohne Raster und Peilpunkt – so in jeder Zeile von „Details“ – als zwei `Shape`s statt `Canvas`: Ein `Canvas` legt
    /// je Ansicht einen eigenen Grafikpuffer an, bei Dutzenden sichtbaren Zeilen rund 160 MB und messbar mehr CPU je Takt
    /// (Bewertung 2026.11.9, Mangel 2, #478).
    private var curve: some View {
        SparklineTrace(series: series, scale: scale, window: window, color: color)
    }

    private var accessibilityValue: String {
        guard let current = series.current else { return String(localized: "keine Messung") }
        let upper = scale.upperBound(for: series.values)
        return ChartAccessibility.value(current: current.formatted(.percent.precision(.fractionLength(0))),
                                        trend: ChartAccessibility.trend(of: series.values, tolerance: upper * 0.05))
    }

    private func draw(in context: inout PlotContext, size: CGSize) {
        let viewport = Self.viewport(for: series, scale: scale, window: window, size: size)
        var still = style
        still.lineWidth = min(style.lineWidth, InstrumentStroke.sparkline)
        let renderer = GraphRenderer(style: still, color: color)
        if showsGrid { renderer.drawGrid(in: &context, size: size, columns: 4) }
        renderer.drawSeries(Self.segments(for: series, in: viewport), in: &context, size: size, showsHead: showsMarker)
    }

    /// Ausschnitt: das Fenster endet am neuesten Wert, die Obergrenze folgt `scale` (automatisch: rund, mindestens
    /// `minimum`, damit Rauschen nahe 0 nicht wie Last aussieht).
    nonisolated static func viewport(for series: ChartSeries, scale: ChartScale, window: TimeInterval,
                                     size: CGSize) -> ChartViewport {
        let upper = max(scale.upperBound(for: series.values), scale.lowerBound + .ulpOfOne)
        return ChartViewport(window: window, range: scale.lowerBound...upper, size: size)
    }

    /// Höchster Wert als Anteil der Höhe von oben (1 = Grundlinie, ohne Wert): Dort beginnt der Verlauf der Fläche wie in
    /// `GraphRenderer`.
    nonisolated static func crest(of series: ChartSeries, scale: ChartScale) -> CGFloat {
        guard let peak = series.values.compactMap(\.self).max() else { return 1 }
        return ChartGeometry.y(for: peak, in: viewport(for: series, scale: scale, window: 1, size: CGSize(width: 1, height: 1)))
    }

    /// Punkte ohne Laufband: Der neueste Wert liegt am rechten Rand.
    nonisolated static func segments(for series: ChartSeries, in viewport: ChartViewport) -> [[CGPoint]] {
        ChartGeometry.segments(for: series, at: series.latest, in: viewport)
    }
}

/// Kurve und Fläche samt deren Verlauf wie `GraphRenderer`, aus zwei Formen.
struct SparklineTrace: View {
    let series: ChartSeries
    let scale: ChartScale
    let window: TimeInterval
    let color: Color

    @Environment(\.chartStyle) private var style

    var body: some View {
        ZStack {
            SparklineCurve(series: series, scale: scale, window: window, closesArea: true)
                .fill(LinearGradient(colors: [color.opacity(InstrumentOpacity.area), color.opacity(0)],
                                     startPoint: UnitPoint(x: 0, y: Sparkline.crest(of: series, scale: scale)),
                                     endPoint: UnitPoint(x: 0, y: 1)))
            SparklineCurve(series: series, scale: scale, window: window, closesArea: false)
                .stroke(color, style: StrokeStyle(lineWidth: min(style.lineWidth, InstrumentStroke.sparkline),
                                                  lineCap: .round, lineJoin: .round))
        }
    }
}

/// Stiller Verlauf zweier Reihen gespiegelt um die Mitte (Empfangen/Senden, Lesen/Schreiben) auf gemeinsamer Skala, wie
/// `MirrorGraph` ohne Raster, aber aus Formen: Ein `Canvas` legt einen eigenen Grafikpuffer an, im Popover der
/// Menüleiste kostete das rund 280 MB (Bewertung 2026.11.9/1510, Mangel 1).
public struct MirrorSparkline: View {
    let upper: ChartSeries
    let lower: ChartSeries
    let window: TimeInterval
    let minimum: Double
    let colors: (upper: Color, lower: Color)

    public init(upper: ChartSeries, lower: ChartSeries, window: TimeInterval = 60, minimum: Double = 1_000_000,
                colors: (upper: Color, lower: Color)) {
        self.upper = upper
        self.lower = lower
        self.window = window
        self.minimum = minimum
        self.colors = colors
    }

    public var body: some View {
        let scale = ChartScale.fixed(0...ChartScale.automatic(minimum: minimum).upperBound(for: upper.values + lower.values))
        VStack(spacing: 0) {
            SparklineTrace(series: upper, scale: scale, window: window, color: colors.upper)
            SparklineTrace(series: lower, scale: scale, window: window, color: colors.lower)
                .scaleEffect(x: 1, y: -1)
        }
        .renderProbe("MirrorSparkline")
        .background(RoundedRectangle(cornerRadius: InstrumentRadius.graph, style: .continuous)
            .fill(.primary.opacity(InstrumentOpacity.subtle)))
        .clipShape(RoundedRectangle(cornerRadius: InstrumentRadius.graph, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(Text("Durchsatz"))
    }
}

/// Linie oder Fläche (`closesArea`) einer Sparkline in der Größe ihres Rahmens.
struct SparklineCurve: Shape {
    let series: ChartSeries
    let scale: ChartScale
    let window: TimeInterval
    let closesArea: Bool

    func path(in rect: CGRect) -> Path {
        let viewport = Sparkline.viewport(for: series, scale: scale, window: window, size: rect.size)
        var path = Path()
        for points in Sparkline.segments(for: series, in: viewport) where !points.isEmpty {
            var segment = MonotoneCurve.path(through: points)
            if closesArea {
                segment.addLine(to: CGPoint(x: points[points.count - 1].x, y: rect.height))
                segment.addLine(to: CGPoint(x: points[0].x, y: rect.height))
                segment.closeSubpath()
            }
            path.addPath(segment)
        }
        return path
    }
}

#Preview("Sparklines") {
    let now = Date.now
    VStack(spacing: 8) {
        ForEach([0.01, 0.08, 0.35, 0.8], id: \.self) { level in
            Sparkline(series: ChartSeries(values: (0..<60).map { level * (1 + 0.5 * sin(Double($0) / 4)) }, spacing: 1,
                                          latest: now), color: .teal)
                .frame(width: 120, height: 20)
        }
    }
    .padding()
}
