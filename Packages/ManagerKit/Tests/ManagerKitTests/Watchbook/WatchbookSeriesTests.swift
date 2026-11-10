import Foundation
import Testing
@testable import ManagerKit

@Suite struct WatchbookSeriesTests {
    private typealias Fixtures = WatchbookFixtures
    private let start = WatchbookFixtures.dayStart

    @Test func periodsCoverOneHourToSevenDays() {
        #expect(WatchbookPeriod.allCases.map(\.duration) == [3_600, 21_600, 86_400, 604_800])
    }

    /// Je Spalte Minimum, Maximum und Mittel der Punkte, die sie abdecken.
    @Test func columnsSummarizeTheirPoints() throws {
        let points = Fixtures.points(from: start.addingTimeInterval(10), count: 12) { [0.25, 0.75, 0.5][$0 % 3] }
        var builder = WatchbookSeriesBuilder(range: start..<start.addingTimeInterval(120), width: 2)
        builder.add(points)
        let series = builder.build(events: [], problems: [])
        let columns = series.statistics(of: .cpuTotal)
        #expect(columns.count == 2)
        // Erste Spalte (0–60 s): Die Punkte bei 10…60 s decken je die 10 s davor ab, der bei 60 s also nur sie.
        #expect(columns[0] == WatchbookStatistic(minimum: 0.25, maximum: 0.75, mean: 0.5))
        let second = try #require(columns[1])
        #expect(second.minimum == 0.25 && second.maximum == 0.75)
    }

    /// Lücken bleiben Lücken: Ruhezustand oder fehlende Werte ergeben leere Spalten, nie 0.
    @Test func gapsStayGaps() {
        let before = Fixtures.points(from: start.addingTimeInterval(10), count: 6)
        let after = Fixtures.points(from: start.addingTimeInterval(1_210), count: 6)
        var builder = WatchbookSeriesBuilder(range: start..<start.addingTimeInterval(1_800), width: 30)
        builder.add(before + after)
        let columns = builder.build(events: [], problems: []).statistics(of: .cpuTotal)
        #expect(columns[0] != nil)
        #expect(columns[1...19].allSatisfy { $0 == nil })
        #expect(columns[20] != nil)
        #expect(columns[21...].allSatisfy { $0 == nil })
    }

    @Test func unmeasuredMetricsStayEmptyWhereOthersAreMeasured() {
        var builder = WatchbookSeriesBuilder(range: start..<start.addingTimeInterval(60), width: 6)
        builder.add(Fixtures.points(from: start.addingTimeInterval(10), count: 6) { _ in nil })
        let series = builder.build(events: [], problems: [])
        #expect(series.statistics(of: .cpuTotal).allSatisfy { $0 == nil })
        #expect(series.statistics(of: .memoryUsed).allSatisfy { $0 != nil })
    }

    /// Dichte Punkte (volle Auflösung um einen Befund) decken nur die Zeit seit dem vorigen Punkt ab.
    @Test func densePointsCoverOnlyTheTimeSinceThePreviousOne() {
        let points = Fixtures.points(from: start.addingTimeInterval(1), count: 10, every: 1) { $0 == 9 ? 0.75 : 0.25 }
        var builder = WatchbookSeriesBuilder(range: start..<start.addingTimeInterval(10), width: 10)
        builder.add(points)
        let columns = builder.build(events: [], problems: []).statistics(of: .cpuTotal)
        #expect(columns.compactMap { $0?.maximum } == Array(repeating: 0.25, count: 9) + [0.75])
    }

    /// Minutenwerte tragen Mittel und Maximum bei; als Minimum gilt ihr Mittel.
    @Test func minutesContributeMeanAndMaximum() {
        let minutes = WatchbookCompaction.minutes(
            from: Fixtures.points(from: start, count: 6) { [0.25, 0.75][$0 % 2] }
                + Fixtures.points(from: start.addingTimeInterval(60), count: 6) { _ in 0.25 })
        var builder = WatchbookSeriesBuilder(range: start..<start.addingTimeInterval(180), width: 1)
        builder.add(minutes)
        let column = builder.build(events: [], problems: []).statistics(of: .cpuTotal)[0]
        #expect(column == WatchbookStatistic(minimum: 0.25, maximum: 0.75, mean: 0.375))
    }

    @Test func pointsOutsideTheRangeAreIgnored() {
        var builder = WatchbookSeriesBuilder(range: start..<start.addingTimeInterval(60), width: 1)
        builder.add(Fixtures.points(from: start.addingTimeInterval(80), count: 2))
        builder.add(Fixtures.points(from: start.addingTimeInterval(-100), count: 2))
        #expect(builder.build(events: [], problems: []).statistics(of: .cpuTotal) == [nil])
    }

    @Test func widthIsBounded() {
        #expect(WatchbookSeriesBuilder(range: start..<start.addingTimeInterval(60), width: 0).width == 1)
        #expect(WatchbookSeriesBuilder(range: start..<start.addingTimeInterval(60), width: 1_000_000).width
            == WatchbookSeriesBuilder.maximumWidth)
    }

    @Test func storeSeriesReadsPointsMinutesEventsAndPending() throws {
        try Fixtures.withStore { store in
            let day = WatchbookFixtures.day
            try store.append(points: Fixtures.points(from: start, count: 6),
                             events: [Fixtures.event(start: start, end: start.addingTimeInterval(30))])
            try store.maintain(now: day.end.addingTimeInterval(86_400))
            let today = day.end.addingTimeInterval(86_400)
            try store.append(points: Fixtures.points(from: today, count: 6), events: [])
            let pending = Fixtures.points(from: today.addingTimeInterval(60), count: 3)
            let late = Fixtures.event(.system, start: today.addingTimeInterval(65), end: today.addingTimeInterval(65))
            let now = today.addingTimeInterval(90)
            let series = store.series(.week, endingAt: now, width: 700, pendingPoints: pending, pendingEvents: [late])
            #expect(series.range == now.addingTimeInterval(-604_800)..<now)
            #expect(series.statistics(of: .cpuTotal).compactMap { $0 }.count >= 2)
            #expect(series.events.count == 2)
            #expect(series.events.last == late)
            let hour = store.series(.hour, endingAt: now, width: 360, pendingPoints: pending, pendingEvents: [])
            // 10-s-Spalten: Die Punkte ab heute decken 350…358 ab; die jüngsten 10 s sind noch nicht gemessen.
            let columns = hour.statistics(of: .cpuTotal)
            #expect(columns[350..<359].allSatisfy { $0 != nil })
            #expect(columns[359] == nil && columns[349] == nil)
            #expect(hour.events.isEmpty)
        }
    }
}
