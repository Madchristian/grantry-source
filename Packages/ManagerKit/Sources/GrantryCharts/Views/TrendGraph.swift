import SwiftUI

/// Verlauf über einen langen Zeitraum aus verdichteten Spalten, etwa die Leistungsaufnahme aus dem Wachbuch (Spec
/// 2026-11-08 §5.3, TM-14.5): bis zu drei Reihen (§3.4) auf gemeinsamer Skala, Achse links, Zeitachse unten. Spalten
/// ohne Messung bleiben leer – keine Linie, keine Ersatzlinie. Kein Laufband: Es zeichnet nur bei neuen Spalten, neuer
/// Größe oder Hover (§4.4).
public struct TrendGraph: View {
    /// Eine Reihe mit ihrer Messgrößenfarbe; die erste ist die Hauptreihe unter dem Fadenkreuz.
    public struct Line: Equatable, Sendable {
        public let series: ChartSeries
        public let hue: InstrumentHue

        public init(series: ChartSeries, hue: InstrumentHue) {
            self.series = series
            self.hue = hue
        }
    }

    let label: String
    let lines: [Line]
    let window: TimeInterval
    let minimum: Double
    let format: @Sendable (Double) -> String

    @Environment(\.self) private var environment

    /// - Parameters:
    ///   - label: Beschriftung für VoiceOver, etwa „Leistungsaufnahme, letzte 24 h“.
    ///   - minimum: kleinste Obergrenze der Skala (etwa 5 W), damit Rauschen nicht die ganze Höhe füllt.
    public init(_ label: String, lines: [Line], window: TimeInterval, minimum: Double,
                format: @escaping @Sendable (Double) -> String) {
        self.label = label
        self.lines = Array(lines.prefix(3))
        self.window = window
        self.minimum = minimum
        self.format = format
    }

    public var body: some View {
        let scale = Self.sharedScale(lines.map(\.series), minimum: minimum)
        let marks = scale.axisMarks(for: []).map { $0 == 0 ? "0" : format($0) }
        VStack(spacing: InstrumentSpacing.inline) {
            GraphAxes(leading: marks, frameColor: lines.first.map { environment.instrumentColor($0.hue) }) {
                graph(scale: scale)
            }
            HStack(spacing: InstrumentSpacing.item) {
                // So breit wie die Achsenbeschriftung, damit die Zeitachse unter der Zeichenfläche beginnt.
                ZStack { ForEach(marks.indices, id: \.self) { Text(verbatim: marks[$0]) } }
                    .font(InstrumentFont.micro.monospacedDigit())
                    .fixedSize()
                    .hidden()
                TimeAxisLabels(window: window)
            }
        }
    }

    @ViewBuilder
    private func graph(scale: ChartScale) -> some View {
        if let main = lines.first {
            LiveGraph(series: main.series,
                      overlays: lines.dropFirst().map {
                          LiveGraph.Overlay(series: $0.series, scale: scale, color: environment.instrumentColor($0.hue))
                      },
                      scale: scale, window: window, color: environment.instrumentColor(main.hue),
                      format: format, age: { Self.age($0) })
                .accessibilityLabel(Text(verbatim: label))
        }
    }

    /// Feste Skala von 0 bis zur runden Obergrenze über alle Reihen.
    public nonisolated static func sharedScale(_ series: [ChartSeries], minimum: Double) -> ChartScale {
        .fixed(0...ChartScale.automatic(minimum: minimum).upperBound(for: series.flatMap(\.values)))
    }

    /// „vor 14 min“, „vor 2 h 14 min“, ab zwei Tagen „vor 3 Tagen 5 h“ – ganze Minuten bzw. Stunden.
    nonisolated static func age(_ seconds: TimeInterval) -> String {
        let minutes = max(Int((seconds / 60).rounded(.down)), 0)
        let hours = minutes / 60, days = hours / 24
        if days >= 2 { return hours % 24 == 0 ? "vor \(days) Tagen" : "vor \(days) Tagen \(hours % 24) h" }
        if hours >= 1 { return minutes % 60 == 0 ? "vor \(hours) h" : "vor \(hours) h \(minutes % 60) min" }
        return "vor \(minutes) min"
    }
}
