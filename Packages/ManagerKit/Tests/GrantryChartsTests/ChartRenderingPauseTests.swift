import Foundation
import SwiftUI
import Testing
@testable import GrantryCharts

/// Rendering-Pause (Spec 2026-11-06 §4, #322): verdecktes Fenster oder geschlossenes Popover → die Graphen stehen. Auch
/// laufend zeichnen sie nur mit einem neuen Messpunkt neu (`GraphTrack`, Leistungsbudget): Bis 2026.11.7 (1188) hing
/// das Bild von der Uhr ab und wurde mit der Bildwiederholrate neu gezeichnet.
@MainActor
@Suite struct ChartRenderingPauseTests {
    private static let size = CGSize(width: 360, height: 140)

    /// Laufband mit Werten bis eben in einem Panel der Instrumententafel.
    private static func graph(_ series: ChartSeries) -> some View {
        LiveGraph(series: series)
            .instrumentPanel(padding: 12)
            .instrumentBackground()
    }

    private static func liveSeries() -> ChartSeries {
        ChartSeries(values: (0..<61).map { 0.45 + 0.35 * sin(Double($0) / 4) }, spacing: 1, latest: .now)
    }

    @Test func pausedRenderingStopsAnimationButKeepsTheLook() {
        var environment = EnvironmentValues()
        #expect(environment.chartStyle.animates)
        environment.chartRenderingPaused = true
        let paused = environment.chartStyle
        #expect(!paused.animates)
        #expect(paused.glows)
        #expect(paused.lineWidth == InstrumentStroke.line)
        #expect(paused.paletteOverride == nil)
    }

    /// Ohne neuen Messpunkt bleibt auch ein laufender Graph pixelgleich – das Bild hängt nicht von der Uhr ab, es gibt
    /// also nichts im Bildtakt neu zu zeichnen.
    @Test func runningGraphStandsStillBetweenPoints() async throws {
        let series = Self.liveSeries()
        let first = try #require(ChartImage(Self.graph(series), size: Self.size, paused: false))
        try await Task.sleep(for: .milliseconds(400))
        let second = try #require(ChartImage(Self.graph(series), size: Self.size, paused: false))
        #expect(first.coverage > 0.05)
        #expect(first.difference(to: second) == 0)
    }

    /// Ein neuer Messpunkt verschiebt das Band.
    @Test func newPointMovesTheGraph() throws {
        let series = Self.liveSeries()
        var next = series
        next.values = Array(series.values.dropFirst()) + [0.9]
        next.latest = series.latest.addingTimeInterval(series.spacing)
        let first = try #require(ChartImage(Self.graph(series), size: Self.size, paused: false))
        let second = try #require(ChartImage(Self.graph(next), size: Self.size, paused: false))
        #expect(first.difference(to: second) > 0.001)
    }

    @Test func pausedGraphStandsStill() async throws {
        let series = Self.liveSeries()
        let first = try #require(ChartImage(Self.graph(series), size: Self.size, paused: true))
        try await Task.sleep(for: .milliseconds(400))
        let second = try #require(ChartImage(Self.graph(series), size: Self.size, paused: true))
        #expect(first.coverage > 0.05)
        // Verläufe werden mit ±1–2 Stufen gedithert; die Toleranz trennt das von echter Bewegung.
        #expect(first.difference(to: second) == 0)
    }
}
