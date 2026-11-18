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

    /// Blöcke (#663): über Blockgrenzen hinweg dieselben Werte wie ein einfacher Ringpuffer, auch mit Lücken und bei
    /// einer Kapazität, die kein Vielfaches der Blockgröße ist.
    @Test(arguments: [(1, 1), (3, 2), (5, 2), (7, 3), (9, 4), (12, 4), (60, 60)])
    func blocksKeepTheNewestValuesLikeARing(capacity: Int, blockSize: Int) {
        var series = MetricSeries(capacity: capacity, blockSize: blockSize)
        var ring: [Double?] = []
        for step in 0..<40 {
            let value: Double? = step % 7 == 3 ? nil : Double(step)
            series.append(value)
            ring = Array((ring + [value]).suffix(capacity))
            #expect(series.values == ring, "nach Wert \(step)")
            #expect(series.suffix(2) == Array(ring.suffix(2)))
        }
    }

    /// Ein Stand, den ein Frame noch hält, ändert sich nicht, wenn der Verlauf weiterläuft (Wertsemantik trotz
    /// geteilter Blöcke).
    @Test func heldHistoryKeepsItsValues() {
        var history = SampleHistory(interval: .seconds(1))
        for value in 0..<130 { history.record([.cpuTotal: Double(value)]) }
        let held = history
        for value in 130..<200 { history.record([.cpuTotal: Double(value)]) }
        #expect(held.points(for: .cpuTotal, in: .oneMinute) == (70..<130).map { Double($0) })
        #expect(history.points(for: .cpuTotal, in: .oneMinute) == (140..<200).map { Double($0) })
    }

    /// Ursache von #663: Jeder Takt kopierte alle Ringpuffer (je Prozess 900 Werte, 16 KB), weil der vorige Frame den
    /// Verlauf noch hielt; jeder weitere Halter (Bedienungshilfen, Ansichten) hielt eine ganze Kopie fest. Jetzt teilen
    /// sich alter und neuer Stand alle vollen Blöcke, ein Takt legt je Reihe höchstens den jüngsten Block neu an.
    @Test func recordingWhileAFrameHoldsTheHistorySharesFullBlocks() throws {
        var history = SampleHistory(interval: .seconds(1))
        let processes = (1...50).map { MetricKey.processCPU(ProcessKey(pid: Int32($0), startTime: 1)) }
        for tick in 0..<300 { history.record(Dictionary(uniqueKeysWithValues: processes.map { ($0, Double(tick)) })) }
        let held = history
        history.record(Dictionary(uniqueKeysWithValues: processes.map { ($0, 1) }))
        for key in processes {
            let before = try #require(held.series[key]).fullBlocks
            let after = try #require(history.series[key]).fullBlocks
            #expect(before.count == 5)
            #expect(after.prefix(before.count) == before[...])
        }
    }
}
