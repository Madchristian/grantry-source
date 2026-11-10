import CoreGraphics
import Foundation
import Testing
@testable import GrantryCharts

@Suite struct ChartGeometryTests {
    private let latest = Date(timeIntervalSinceReferenceDate: 1_000)
    private let viewport = ChartViewport(window: 10, range: 0...1, size: CGSize(width: 100, height: 50))

    @Test func pointsFollowTimeAndValue() {
        let series = ChartSeries(values: [0, 1], spacing: 5, latest: latest)
        let segments = ChartGeometry.segments(for: series, at: latest, in: viewport)
        #expect(segments == [[CGPoint(x: 50, y: 50), CGPoint(x: 100, y: 0)]])
    }

    @Test func gapsSplitSegments() {
        let series = ChartSeries(values: [0.5, nil, 0.5], spacing: 1, latest: latest)
        #expect(ChartGeometry.segments(for: series, at: latest, in: viewport).map(\.count) == [1, 1])
    }

    @Test func valuesOutsideRangeAreClamped() {
        let series = ChartSeries(values: [2, -1], spacing: 1, latest: latest)
        #expect(ChartGeometry.segments(for: series, at: latest, in: viewport)[0].map(\.y) == [0, 50])
    }

    @Test func headInterpolatesAtEdge() {
        let head = ChartGeometry.head(of: [CGPoint(x: 80, y: 40), CGPoint(x: 120, y: 0)], atX: 100)
        #expect(head == CGPoint(x: 100, y: 20))
    }

    @Test func headIsLastPointInsideFrame() {
        #expect(ChartGeometry.head(of: [CGPoint(x: 10, y: 5), CGPoint(x: 60, y: 7)], atX: 100) == CGPoint(x: 60, y: 7))
        #expect(ChartGeometry.head(of: [CGPoint(x: 110, y: 5)], atX: 100) == nil)
    }

    @Test func nearestIndexFindsSampleUnderPointer() {
        let series = ChartSeries(values: [0.1, 0.2, 0.3], spacing: 1, latest: latest)
        #expect(ChartGeometry.nearestIndex(toX: 100, series: series, renderTime: latest, in: viewport) == 2)
        #expect(ChartGeometry.nearestIndex(toX: 81, series: series, renderTime: latest, in: viewport) == 0)
        #expect(ChartGeometry.nearestIndex(toX: 0, series: series, renderTime: latest, in: viewport) == nil)
    }
}
