import CoreGraphics
import Testing
@testable import GrantryCharts

/// Geometrie der Wachbuch-Zeitleiste (TM-12.5): Spalten und Zeitmarke, Lücken, Marken-Gruppen und Thermik-Abschnitte.
@Suite struct WatchbookTimelineGeometryTests {
    private typealias Geometry = WatchbookTimelineGeometry

    @Test func columnsSitAtTheirCentres() {
        #expect(Geometry.x(ofColumn: 0, count: 4, width: 400) == 50)
        #expect(Geometry.x(ofColumn: 3, count: 4, width: 400) == 350)
    }

    @Test func clickPicksTheColumnUnderThePointerAndStaysInside() {
        #expect(Geometry.column(atX: 0, count: 4, width: 400) == 0)
        #expect(Geometry.column(atX: 99.9, count: 4, width: 400) == 0)
        #expect(Geometry.column(atX: 100, count: 4, width: 400) == 1)
        #expect(Geometry.column(atX: 399, count: 4, width: 400) == 3)
        #expect(Geometry.column(atX: -20, count: 4, width: 400) == 0)
        #expect(Geometry.column(atX: 900, count: 4, width: 400) == 3)
        #expect(Geometry.column(atX: 10, count: 0, width: 400) == nil)
    }

    @Test func arrowKeysMoveByTheStepAndStopAtTheEdges() {
        #expect(Geometry.moved(nil, by: -1, step: 5, count: 100) == 99)
        #expect(Geometry.moved(nil, by: 1, step: 5, count: 100) == 99)
        #expect(Geometry.moved(50, by: -1, step: 5, count: 100) == 45)
        #expect(Geometry.moved(2, by: -1, step: 5, count: 100) == 0)
        #expect(Geometry.moved(97, by: 1, step: 5, count: 100) == 99)
        #expect(Geometry.moved(nil, by: 1, step: 5, count: 0) == nil)
    }

    @Test func gapsSplitTheLineAndStayEmpty() {
        let values: [Double?] = [0.5, 0.5, nil, nil, 1, 0]
        let segments = Geometry.segments(values, size: CGSize(width: 60, height: 100), upperBound: 1)
        #expect(segments.count == 2)
        #expect(segments[0].map(\.x) == [5, 15])
        #expect(segments[0].map(\.y) == [50, 50])
        #expect(segments[1].map(\.x) == [45, 55])
        #expect(segments[1].map(\.y) == [0, 100])
    }

    @Test func valuesAboveTheScaleAreClipped() {
        let segments = Geometry.segments([2, -1], size: CGSize(width: 20, height: 10), upperBound: 1)
        #expect(segments.first?.map(\.y) == [0, 10])
    }

    @Test func nearbyMarksFormOneGroupWithTheirCount() {
        let marks = [mark("a", at: 0.10), mark("b", at: 0.11), mark("c", at: 0.5), mark("d", at: 0.505),
                     mark("e", at: 0.509)]
        let groups = Geometry.groups(marks, width: 1_000, spacing: 16)
        #expect(groups.map(\.marks.count) == [2, 3])
        #expect(groups.map(\.first.id) == ["a", "c"])
        #expect(groups[0].x == 100)
    }

    @Test func marksFarApartStaySeparate() {
        let groups = Geometry.groups([mark("a", at: 0.1), mark("b", at: 0.2)], width: 1_000, spacing: 16)
        #expect(groups.map(\.marks.count) == [1, 1])
    }

    @Test func thermalRunsJoinEqualTonesAndLeaveGaps() {
        let tones: [StatusTone?] = [.positive, .positive, nil, .finding, .finding, .positive]
        let runs = Geometry.runs(tones)
        #expect(runs.map(\.columns) == [0..<2, 3..<5, 5..<6])
        #expect(runs.map(\.tone) == [.positive, .finding, .positive])
    }

    private func mark(_ id: String, at position: Double) -> WatchbookMarkContent {
        WatchbookMarkContent(id: id, style: .change, start: position, end: position, symbol: "app", text: id)
    }
}
