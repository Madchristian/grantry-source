import Testing
@testable import ManagerKit

@Suite struct SampleHistoryTests {
    @Test func seriesKeepsNewestValuesOldestFirst() {
        var series = MetricSeries(capacity: 3)
        for value in [1.0, 2, 3, 4] { series.append(value) }
        #expect(series.values == [2, 3, 4])
    }

    @Test func capacityCoversFifteenMinutes() {
        #expect(SampleHistory(interval: .seconds(1)).capacity == 900)
        #expect(SampleHistory(interval: .milliseconds(500)).capacity == 1800)
        #expect(SampleHistory(interval: .seconds(5)).capacity == 180)
    }

    @Test func oneMinuteWindowShowsLastSixtyValues() {
        var history = SampleHistory(interval: .seconds(1))
        for value in 0..<100 { history.record([.cpuTotal: Double(value)]) }
        #expect(history.points(for: .cpuTotal, in: .oneMinute) == (40..<100).map { Double($0) })
    }

    @Test func missingMetricLeavesGap() {
        var history = SampleHistory(interval: .seconds(1))
        history.record([.gpu: 0.5])
        history.record([:])
        history.record([.gpu: 0.7])
        #expect(history.points(for: .gpu, in: .oneMinute) == [0.5, nil, 0.7])
    }

    @Test func metricWithoutValuesForWholeSpanIsDropped() {
        var history = SampleHistory(interval: .seconds(5))
        let process = MetricKey.processCPU(ProcessKey(pid: 42, startTime: 1))
        history.record([process: 0.1])
        for _ in 0..<179 { history.record([:]) }
        #expect(history.series[process] != nil)
        history.record([:])
        #expect(history.series[process] == nil)
    }

    @Test func longerWindowsAverageIntoAtMostSixtyPoints() {
        var history = SampleHistory(interval: .seconds(1))
        for value in 0..<300 { history.record([.cpuTotal: Double(value)]) }
        let points = history.points(for: .cpuTotal, in: .fiveMinutes)
        #expect(points.count == 60)
        #expect(points.first == 2)
        #expect(points.last == 297)
    }

    @Test func bucketWithoutValuesIsGap() {
        var history = SampleHistory(interval: .seconds(1))
        history.record([.gpu: 1])
        for _ in 0..<9 { history.record([:]) }
        for _ in 0..<290 { history.record([.gpu: 1]) }
        #expect(history.points(for: .gpu, in: .fiveMinutes)[1] == nil)
    }

    @Test func pointsStayOnTaktGridWhileNewestBucketFills() {
        var history = SampleHistory(interval: .seconds(1))
        for value in 0..<7 { history.record([.cpuTotal: Double(value)]) }
        let partial = history.pointSeries(for: .cpuTotal, in: .fiveMinutes)
        #expect(partial.values == [2, 5.5])
        #expect(partial.spacing == .seconds(5))
        #expect(partial.latestOffset == .seconds(1))
        history.record([.cpuTotal: 7])
        let next = history.pointSeries(for: .cpuTotal, in: .fiveMinutes)
        #expect(next.values == [2, 6])
        #expect(next.latestOffset == .seconds(2))
    }

    @Test func halfSecondTaktPairsIntoOneSecondPoints() {
        var history = SampleHistory(interval: .milliseconds(500))
        for value in 0..<3 { history.record([.gpu: Double(value)]) }
        let points = history.pointSeries(for: .gpu, in: .oneMinute)
        #expect(points.values == [0.5, 2])
        #expect(points.spacing == .seconds(1))
        #expect(points.latestOffset == .zero)
    }

    @Test func metricStartingLaterUsesTheSameGrid() {
        var history = SampleHistory(interval: .seconds(1))
        for _ in 0..<4 { history.record([.cpuTotal: 0]) }
        history.record([.cpuTotal: 0, .gpu: 1])
        history.record([.cpuTotal: 0, .gpu: 3])
        #expect(history.points(for: .gpu, in: .fiveMinutes) == [1, 3])
    }

    @Test func unknownMetricHasNoPoints() {
        #expect(SampleHistory(interval: .seconds(1)).points(for: .memoryUsed, in: .oneMinute).isEmpty)
    }

    /// Mangel 7 der Bewertung 2026.11.7: Die Pause erscheint als Lücke, die Werte davor bleiben.
    @Test func gapKeepsEarlierValuesAndAddsMissingPoints() {
        var history = SampleHistory(interval: .seconds(1))
        history.record([.cpuTotal: 0.5])
        history.record([.cpuTotal: 0.6])
        history.recordGap(3)
        history.record([.cpuTotal: 0.7])
        #expect(history.points(for: .cpuTotal, in: .oneMinute) == [0.5, 0.6, nil, nil, nil, 0.7])
    }

    @Test func gapLongerThanTheSpanDropsEverything() {
        var history = SampleHistory(interval: .seconds(1))
        history.record([.cpuTotal: 0.5])
        history.recordGap(10_000)
        #expect(history.series.isEmpty)
    }
}
