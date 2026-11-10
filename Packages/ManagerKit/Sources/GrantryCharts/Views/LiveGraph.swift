import SwiftUI

/// Laufband-Graph einer Metrik (Spec §4): Mit jedem Messpunkt rückt der Verlauf um einen Punkt nach links, der neueste
/// Wert steht am rechten Rand; Hover zeigt Fadenkreuz mit Wert, Ziehen spult zurück und federt beim Loslassen zurück.
///
/// Gezeichnet wird nur, wenn sich Werte, Größe oder Hover ändern, nicht im Bildtakt (Leistungsbudget Spec §4: ≤ 3 % CPU
/// im Tab „Leistung“). Bis 2026.11.7 (1188) lief jeder Graph per `TimelineView` mit der Bildwiederholrate (gleitende
/// Zeit, Schimmer, pulsierende Spitze, weiche Skalenwechsel) und hielt den Tab bei 40–55 % CPU eines Kerns; auch ein
/// kurzes Gleiten je Messpunkt kostete noch das Doppelte des Budgets, weil SwiftUI dafür jedes Bild des ganzen Fensters
/// neu rendert (Harness auf Mac16,6: ohne Bewegung 3,0 %, vier Gleitstufen 4,9 %, weiches Gleiten 6,7 %).
public struct LiveGraph: View {
    /// Weitere Reihe im selben Graphen mit eigener Skala und Farbe, etwa Leistung (W) über der CPU-Auslastung. Gezeichnet
    /// in derselben `Plot`, also ohne eigenen Bildtakt.
    public struct Overlay: Equatable, Sendable {
        public let series: ChartSeries
        public let scale: ChartScale
        public let color: Color

        public init(series: ChartSeries, scale: ChartScale, color: Color) {
            self.series = series
            self.scale = scale
            self.color = color
        }
    }

    let series: ChartSeries
    let overlays: [Overlay]
    let scale: ChartScale
    let window: TimeInterval
    let palette: ChartPalette
    /// Feste Farbe der Messgröße (`InstrumentHue`); ohne sie folgt die Farbe der Last aus `palette`.
    let color: Color?
    let showsGrid: Bool
    let isInteractive: Bool
    let format: @Sendable (Double) -> String
    /// Alter des Werts unter dem Fadenkreuz; ohne Angabe „vor 12 s“.
    let age: (@Sendable (TimeInterval) -> String)?

    @Environment(\.chartStyle) private var style
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoverX: CGFloat?
    @State private var scrub = Scrub()
    /// Nach dem Loslassen federt die Ansicht zurück; nur solange zeichnet sie im Bildtakt.
    @State private var springsBack = false
    @State private var width: CGFloat = 1

    public init(series: ChartSeries, overlays: [Overlay] = [], scale: ChartScale = .fixed(0...1), window: TimeInterval = 60,
                palette: ChartPalette = .standard, color: Color? = nil, showsGrid: Bool = true, isInteractive: Bool = true,
                format: @escaping @Sendable (Double) -> String = { $0.formatted(.percent.precision(.fractionLength(0))) },
                age: (@Sendable (TimeInterval) -> String)? = nil) {
        self.series = series
        self.overlays = overlays
        self.scale = scale
        self.window = window
        self.palette = palette
        self.color = color
        self.showsGrid = showsGrid
        self.isInteractive = isInteractive
        self.format = format
        self.age = age
    }

    public var body: some View {
        TimelineView(.animation(paused: !springsBack)) { timeline in
            Plot("LiveGraph") { context, size in
                draw(in: &context, size: size, now: timeline.date)
            }
        }
        .renderProbe("LiveGraph")
        .task(id: springsBack) {
            guard springsBack else { return }
            try? await Task.sleep(for: Scrub.springDuration)
            guard !Task.isCancelled else { return }
            scrub = Scrub()
            springsBack = false
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onContinuousHover { phase in
            guard isInteractive else { return }
            if case .active(let location) = phase { hoverX = location.x } else { hoverX = nil }
        }
        .gesture(isInteractive ? scrubGesture : nil)
        .accessibilityReading(Text("Verlauf"), value: Text(accessibilityValue))
    }

    private var accessibilityValue: String {
        guard let current = series.current else { return String(localized: "keine Messung") }
        let upper = scale.upperBound(for: series.values)
        return ChartAccessibility.value(current: format(current),
                                        trend: ChartAccessibility.trend(of: series.values, tolerance: upper * 0.05))
    }

    private func draw(in context: inout PlotContext, size: CGSize, now: Date) {
        let renderTime = series.latest.addingTimeInterval(-scrub.offset(at: now))
        let upper = scale.upperBound(for: series.values)
        let viewport = ChartViewport(window: window, range: scale.lowerBound...max(upper, scale.lowerBound + .ulpOfOne),
                                     size: size)
        let current = series.current ?? 0
        let load = (current - viewport.range.lowerBound) / (viewport.range.upperBound - viewport.range.lowerBound)
        let lineColor = color ?? style.palette(palette).strokeColor(forLoad: load, in: colorScheme)
        let renderer = GraphRenderer(style: style, color: lineColor)
        if showsGrid { renderer.drawGrid(in: &context, size: size) }
        for overlay in overlays {
            let upper = max(overlay.scale.upperBound(for: overlay.series.values), overlay.scale.lowerBound + .ulpOfOne)
            let range = overlay.scale.lowerBound...upper
            GraphRenderer(style: style, color: overlay.color)
                .drawSeries(ChartGeometry.segments(for: overlay.series, at: renderTime,
                                                   in: ChartViewport(window: window, range: range, size: size)),
                            in: &context, size: size)
        }
        renderer.drawSeries(ChartGeometry.segments(for: series, at: renderTime, in: viewport), in: &context, size: size)
        if let hoverX { drawCrosshair(at: hoverX, in: &context, viewport: viewport, renderTime: renderTime) }
    }

    private func drawCrosshair(at x: CGFloat, in context: inout PlotContext, viewport: ChartViewport,
                               renderTime: Date) {
        guard let index = ChartGeometry.nearestIndex(toX: x, series: series, renderTime: renderTime, in: viewport),
              let value = series.values[index] else { return }
        let point = ChartGeometry.point(value: value, at: series.time(at: index), renderTime: renderTime, in: viewport)
        var line = Path()
        line.move(to: CGPoint(x: point.x, y: 0))
        line.addLine(to: CGPoint(x: point.x, y: viewport.size.height))
        context.stroke(line, with: .color(.primary.opacity(InstrumentOpacity.secondaryLine)),
                       style: StrokeStyle(lineWidth: InstrumentStroke.border, dash: [3, 3]))
        context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)), with: .color(.primary))
        let elapsed = series.latest.timeIntervalSince(series.time(at: index))
        let text = age.map { Text(verbatim: "\(format(value)) · \($0(elapsed))") }
            ?? Text("\(format(value)) · vor \(Int(elapsed.rounded())) s")
        let label = text.font(InstrumentFont.label.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, InstrumentSpacing.inline)
            .padding(.vertical, InstrumentSpacing.stack)
            .background(.black.opacity(InstrumentOpacity.tooltip),
                        in: RoundedRectangle(cornerRadius: InstrumentRadius.control, style: .continuous))
        // Rechts neben dem Fadenkreuz, in der rechten Hälfte links davon – so bleibt die Beschriftung im Graphen.
        let leftOfCrosshair = point.x > viewport.size.width / 2
        context.draw(label, at: CGPoint(x: point.x + (leftOfCrosshair ? -8 : 8), y: 6),
                     anchor: leftOfCrosshair ? .topTrailing : .topLeading)
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { drag in
                springsBack = false
                scrub.drag(by: drag.translation.width, width: width, window: window)
            }
            .onEnded { _ in
                scrub.release(at: .now)
                if style.animates { springsBack = true } else { scrub = Scrub() }
            }
    }
}

/// Zurückspulen per Ziehen; nach dem Loslassen federt die Ansicht exponentiell zur Gegenwart zurück.
struct Scrub: Equatable {
    /// Bis dahin ist der Rückversatz auf unter 0,3 % gefallen.
    static let springDuration = Duration.seconds(1)

    private var dragged: TimeInterval = 0
    private var releasedAt: Date?

    mutating func drag(by translation: CGFloat, width: CGFloat, window: TimeInterval) {
        releasedAt = nil
        dragged = max(0, Double(translation / max(width, 1)) * window)
    }

    mutating func release(at date: Date) { releasedAt = date }

    /// Rückversatz in Sekunden.
    func offset(at date: Date) -> TimeInterval {
        guard let releasedAt else { return dragged }
        return dragged * exp(-max(0, date.timeIntervalSince(releasedAt)) * 6)
    }
}
