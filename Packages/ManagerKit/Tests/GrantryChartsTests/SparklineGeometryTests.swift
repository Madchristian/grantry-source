import CoreGraphics
import Testing
@testable import GrantryCharts

@Suite struct SparklineGeometryTests {
    private let rect = CGRect(x: 0, y: 0, width: 40, height: 10)

    @Test func shortHistoryIsRightAligned() {
        #expect(SparklineGeometry.segments([0, 1], capacity: 5, in: rect)
            == [[CGPoint(x: 30, y: 10), CGPoint(x: 40, y: 0)]])
    }

    @Test func gapsSplitTheCurve() {
        let segments = SparklineGeometry.segments([0.5, 0.5, nil, 0.5], capacity: 4, in: rect)
        #expect(segments.map(\.count) == [2, 1])
    }

    @Test func valuesAreClampedToTheRect() {
        let points = SparklineGeometry.segments([-1, 2, .nan], capacity: 3, in: rect).flatMap { $0 }
        #expect(points.map(\.y) == [10, 0])
    }

    @Test func areaReachesTheBottom() {
        let area = SparklineGeometry.area([0.5, 0.5], capacity: 2, in: rect)
        #expect(area.boundingRect == CGRect(x: 0, y: 5, width: 40, height: 5))
    }

    @Test func noValuesDrawNothing() {
        #expect(SparklineGeometry.line([nil, nil], capacity: 2, in: rect).isEmpty)
        #expect(SparklineGeometry.area([], capacity: 30, in: rect).isEmpty)
    }
}
