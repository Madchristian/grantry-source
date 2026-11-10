import CoreGraphics
import Testing
@testable import GrantryCharts

@Suite struct MonotoneCurveTests {
    private let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 50), CGPoint(x: 20, y: 52), CGPoint(x: 30, y: 0),
                          CGPoint(x: 40, y: 0), CGPoint(x: 50, y: 49)]

    @Test func controlPointsStayWithinNeighbourValues() {
        for (index, segment) in MonotoneCurve.controlPoints(for: points).enumerated() {
            let low = min(points[index].y, points[index + 1].y), high = max(points[index].y, points[index + 1].y)
            for control in [segment.control1, segment.control2] {
                #expect(control.y >= low - 1e-9 && control.y <= high + 1e-9, "Segment \(index) schwingt über")
            }
        }
    }

    @Test func curveEndsAtEveryPoint() {
        #expect(MonotoneCurve.controlPoints(for: points).map(\.end) == Array(points.dropFirst()))
    }

    @Test func extremaGetFlatTangents() {
        #expect(MonotoneCurve.tangents(for: points)[3] == 0)
    }

    @Test func singlePointAndEmptyInputAreSafe() {
        #expect(MonotoneCurve.path(through: []).isEmpty)
        #expect(MonotoneCurve.tangents(for: [CGPoint(x: 1, y: 1)]) == [0])
    }
}
