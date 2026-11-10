import Foundation
import Testing
@testable import GrantryCharts

@Suite struct SparklineTests {
    private static let latest = Date(timeIntervalSinceReferenceDate: 1_000)
    private static let size = CGSize(width: 120, height: 20)

    private static func viewport(_ series: ChartSeries, scale: ChartScale = .automatic(minimum: 0.05)) -> ChartViewport {
        Sparkline.viewport(for: series, scale: scale, window: 60, size: size)
    }

    @Test func newestValueSitsOnTheRightEdge() throws {
        let series = ChartSeries(values: Array(repeating: 0.5, count: 60), spacing: 1, latest: Self.latest)
        let points = try #require(Sparkline.segments(for: series, in: Self.viewport(series, scale: .fixed(0...1))).first)
        #expect(points.count == 60)
        #expect(points.last?.x == 120)
        #expect(points.first?.x == 2)
        #expect(points.allSatisfy { $0.y == 10 })
    }

    @Test func automaticScaleKeepsSmallLoadsSmall() {
        let quiet = ChartSeries(values: [0.001, 0.002], spacing: 1, latest: Self.latest)
        #expect(Self.viewport(quiet).range.upperBound == 0.05)
        let busy = ChartSeries(values: [0.3, 0.42], spacing: 1, latest: Self.latest)
        #expect(Self.viewport(busy).range.upperBound == 0.5)
    }

    @Test func gapsSplitTheCurveAndEmptySeriesDrawsNothing() {
        let series = ChartSeries(values: [0.1, nil, 0.2, 0.3], spacing: 1, latest: Self.latest)
        #expect(Sparkline.segments(for: series, in: Self.viewport(series)).map(\.count) == [1, 2])
        #expect(Sparkline.segments(for: .empty, in: Self.viewport(.empty)).isEmpty)
    }

    @Test func valuesAboveTheFixedRangeAreClamped() throws {
        let series = ChartSeries(values: [1.4], spacing: 1, latest: Self.latest)
        let point = try #require(Sparkline.segments(for: series, in: Self.viewport(series, scale: .fixed(0...1))).first?.first)
        #expect(point.y == 0)
    }

    /// Der Verlauf der Fläche beginnt wie in `GraphRenderer` an der höchsten Stelle der Kurve (#478).
    @Test func areaGradientStartsAtTheCrest() {
        let series = ChartSeries(values: [0.1, 0.25, nil, 0.2], spacing: 1, latest: Self.latest)
        #expect(Sparkline.crest(of: series, scale: .fixed(0...1)) == 0.75)
        #expect(Sparkline.crest(of: .empty, scale: .fixed(0...1)) == 1)
    }

    /// Die Fläche schließt an der Grundlinie, die Linie bleibt offen; Lücken trennen beide.
    @Test func curveClosesOnlyTheArea() {
        let series = ChartSeries(values: [0.5, 0.5, nil, 0.5, 0.5], spacing: 1, latest: Self.latest)
        let rect = CGRect(origin: .zero, size: Self.size)
        let area = SparklineCurve(series: series, scale: .fixed(0...1), window: 60, closesArea: true).path(in: rect)
        let line = SparklineCurve(series: series, scale: .fixed(0...1), window: 60, closesArea: false).path(in: rect)
        #expect(area.boundingRect.maxY == Self.size.height)
        #expect(line.boundingRect.maxY == 10)
        #expect(line.boundingRect.maxX == Self.size.width)
    }
}
