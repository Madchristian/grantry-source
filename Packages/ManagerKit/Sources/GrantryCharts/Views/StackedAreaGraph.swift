import SwiftUI

/// Gestapelte Flächen, z. B. Speicher aus App, zugeordnet, komprimiert und Cache (Spec §4); rückt wie `LiveGraph` je
/// Messpunkt nach und zeichnet nicht im Bildtakt.
public struct StackedAreaGraph: View {
    public struct Layer: Identifiable, Sendable {
        public let id: String
        public let series: ChartSeries
        public let color: Color

        public init(id: String, series: ChartSeries, color: Color) {
            self.id = id
            self.series = series
            self.color = color
        }
    }

    let layers: [Layer]
    let total: Double
    let window: TimeInterval

    @Environment(\.chartStyle) private var style

    public init(layers: [Layer], total: Double, window: TimeInterval = 60) {
        self.layers = layers
        self.total = total
        self.window = window
    }

    public var body: some View {
        Plot("StackedAreaGraph") { context, size in
            draw(in: &context, size: size)
        }
        .renderProbe("StackedAreaGraph")
        .accessibilityElement()
        .accessibilityLabel(Text("Speicherbelegung"))
    }

    /// Kumulierte Reihen: Ebene n enthält die Summe der Ebenen 0…n (Lücke, sobald eine fehlt).
    nonisolated static func stacked(_ layers: [ChartSeries]) -> [ChartSeries] {
        var running: [Double?] = []
        return layers.map { layer in
            running = running.isEmpty ? layer.values : zip(running, layer.values).map { sum, value in
                guard let sum, let value else { return nil }
                return sum + value
            }
            var result = layer
            result.values = running
            return result
        }
    }

    private func draw(in context: inout PlotContext, size: CGSize) {
        guard let reference = layers.first?.series else { return }
        let renderTime = reference.latest
        let viewport = ChartViewport(window: window, range: 0...max(total, 1), size: size)
        GraphRenderer(style: style, color: .primary)
            .drawGrid(in: &context, size: size)
        let stacked = Self.stacked(layers.map(\.series))
        for (layer, series) in zip(layers, stacked).reversed() {
            GraphRenderer(style: style, color: layer.color)
                .drawSeries(ChartGeometry.segments(for: series, at: renderTime, in: viewport), in: &context, size: size,
                            showsHead: false)
        }
    }
}
