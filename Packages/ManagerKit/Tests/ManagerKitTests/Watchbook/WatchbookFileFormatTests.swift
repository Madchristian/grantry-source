import Foundation
import Testing
@testable import ManagerKit

@Suite struct WatchbookFileFormatTests {
    private let day = WatchbookFixtures.day

    private func decode(_ text: String) -> WatchbookDayContents {
        WatchbookFileFormat.decode(Array(text.utf8), of: day)
    }

    @Test func pointsMinutesAndEventsRoundTrip() {
        let points = WatchbookFixtures.points(from: day.start.addingTimeInterval(36_000.5), count: 3)
        // Je Minute ein Punkt: Die Mittel liegen so schon auf dem Raster der Datei.
        let minutes = WatchbookCompaction.minutes(from: WatchbookFixtures.points(from: day.start, count: 3, every: 60))
        let event = WatchbookFixtures.event(start: day.start.addingTimeInterval(600), end: nil)
        let bytes = WatchbookFileFormat.encode(points: points, minutes: minutes, events: [event], of: day)
        let contents = WatchbookFileFormat.decode(bytes, of: day)
        #expect(contents.points == points)
        #expect(contents.minutes == minutes)
        #expect(contents.events == [event])
        #expect(contents.brokenLineCount == 0)
        #expect(contents.isOwnFormat)
    }

    @Test func unmeasuredValuesStayEmptyAfterReading() {
        var point = WatchbookFixtures.point(at: day.start, cpu: nil, memory: nil, received: nil, consumers: false)
        point.values[.power] = nil
        let contents = WatchbookFileFormat.decode(
            WatchbookFileFormat.encode(points: [point], minutes: [], events: [], of: day), of: day)
        #expect(contents.points == [point])
        #expect(contents.points.first?.values[.cpuTotal] == nil)
    }

    /// Werte werden auf das Raster der Datei gerundet (0,1 % CPU, 1 MiB Speicher, 100 B/s, 0,1 W).
    @Test func valuesAreRoundedToTheFileResolution() {
        var values = WatchbookValues()
        values[.cpuTotal] = 0.12345
        values[.memoryUsed] = 1_048_576 * 3 + 10
        values[.diskRead] = 149
        values[.power] = 4.56
        let point = WatchbookPoint(time: day.start, values: values, cpuConsumers: [], memoryConsumers: [])
        let read = WatchbookFileFormat.decode(
            WatchbookFileFormat.encode(points: [point], minutes: [], events: [], of: day), of: day).points[0].values
        #expect(read[.cpuTotal] == 0.123)
        #expect(read[.memoryUsed] == 3_145_728.0)
        #expect(read[.diskRead] == 100)
        #expect(read[.power] == 4.6)
    }

    /// Namen stehen je Schreibblock einmal in der Namenstabelle, nicht in jeder Zeile.
    @Test func namesAreWrittenOncePerBatch() {
        let points = WatchbookFixtures.points(from: day.start, count: 50)
        let text = String(decoding: WatchbookFileFormat.encode(points: points, minutes: [], events: [], of: day),
                          as: UTF8.self)
        #expect(text.components(separatedBy: "Xcode").count - 1 == 1)
        #expect(text.hasPrefix("W\t1\n"))
    }

    /// Jeder Block hat seine eigene Namenstabelle: Ein weiterer angehängter Block liest sich unabhängig.
    @Test func appendedBatchesKeepTheirOwnNames() {
        var first = WatchbookFixtures.point(at: day.start)
        first.cpuConsumers = [WatchbookConsumer(subject: .program("Erster"), value: 0.1)]
        var second = WatchbookFixtures.point(at: day.start.addingTimeInterval(10))
        second.cpuConsumers = [WatchbookConsumer(subject: .program("Zweiter"), value: 0.2)]
        let bytes = WatchbookFileFormat.encode(points: [first], minutes: [], events: [], of: day)
            + WatchbookFileFormat.encode(points: [second], minutes: [], events: [], of: day)
        #expect(WatchbookFileFormat.decode(bytes, of: day).points == [first, second])
    }

    /// Eine abgerissene Zeile (Abbruch beim Anhängen) kostet nur sich selbst.
    @Test func brokenLinesAreSkippedAndCounted() {
        let good = WatchbookFileFormat.encode(points: WatchbookFixtures.points(from: day.start, count: 2), minutes: [],
                                              events: [], of: day)
        let text = String(decoding: good, as: UTF8.self) + "P\t20\t1,2,3\nX\tunbekannt\nP\t30\t25"
        let contents = decode(text)
        #expect(contents.points.count == 2)
        #expect(contents.brokenLineCount == 3)
        #expect(contents.isOwnFormat)
    }

    @Test func pointsOutsideTheDayAreBroken() {
        let good = String(decoding: WatchbookFileFormat.encode(points: [], minutes: [], events: [], of: day),
                          as: UTF8.self)
        let values = String(repeating: ",", count: WatchbookMetric.allCases.count - 1)
        let contents = decode(good + "P\t86400\t\(values)\t\t\n")
        #expect(contents.points.isEmpty && contents.brokenLineCount == 1)
    }

    /// Ohne Kopfzeile ist eine Datei fremd; eine leere (abgebrochen vor dem ersten Block) nicht.
    @Test func fileWithoutHeaderIsForeign() {
        #expect(!decode("kein Wachbuch\n").isOwnFormat)
        #expect(!decode("Wunderbar\n").isOwnFormat)
        #expect(decode("").isOwnFormat)
    }

    /// Eine Datei einer neueren Fassung gilt nicht als eigene – sie darf weder ergänzt noch verdichtet werden.
    @Test func fileOfAnotherVersionIsForeign() {
        #expect(!decode("W\t2\nP\t0\n").isOwnFormat)
        let own = String(decoding: WatchbookFileFormat.encode(points: WatchbookFixtures.points(from: day.start,
                                                                                               count: 1),
                                                              minutes: [], events: [], of: day), as: UTF8.self)
        let mixed = decode(own + "W\t2\nP\t10\tzukunft\n")
        #expect(!mixed.isOwnFormat)
        #expect(mixed.points.count == 1)
        #expect(mixed.brokenLineCount == 0)
    }

    /// Spätere Zeilen eines Ereignisses (etwa das Ende eines Befunds) ersetzen frühere.
    @Test func laterEventLinesReplaceEarlierOnes() {
        let start = day.start.addingTimeInterval(100)
        let begun = WatchbookFixtures.event(start: start, end: nil)
        let ended = begun.ended(at: start.addingTimeInterval(300))
        let other = WatchbookFixtures.event(.system, start: start.addingTimeInterval(5),
                                            end: start.addingTimeInterval(5))
        let bytes = WatchbookFileFormat.encode(points: [], minutes: [], events: [begun, other], of: day)
            + WatchbookFileFormat.encode(points: [], minutes: [], events: [ended], of: day)
        #expect(WatchbookFileFormat.decode(bytes, of: day).events == [ended, other])
    }

    @Test func eventSubjectsRoundTrip() {
        let start = day.start
        let events: [WatchbookEvent] = [nil, .otherAccounts, .systemProcess("kernel_task"), .program("a:b")].map {
            WatchbookEvent(kind: .finding, type: "x", start: start, end: start, tone: .critical, subject: $0,
                           summary: "")
        }
        let read = WatchbookFileFormat.decode(
            WatchbookFileFormat.encode(points: [], minutes: [], events: events, of: day), of: day).events
        #expect(read == events)
    }

    /// PID und Startzeit des Verursachers (TM-12.6) als optionales letztes Feld; Zeilen ohne es lesen sich wie bisher.
    @Test func eventProcessRoundTripsAndOlderLinesStayReadable() {
        let start = day.start
        let key = ProcessKey(pid: 4_242, startTime: 1_794_009_600_123_456)
        let withProcess = WatchbookEvent(kind: .finding, type: "load.process", start: start, end: nil, tone: .finding,
                                         subject: .program("swift-frontend"), process: key, summary: "Prozesslast")
        let without = WatchbookFixtures.event(start: start, end: start)
        let read = WatchbookFileFormat.decode(
            WatchbookFileFormat.encode(points: [], minutes: [], events: [withProcess, without], of: day), of: day)
        #expect(read.events == [withProcess, without])
        #expect(read.events.first?.process == key)
        #expect(read.brokenLineCount == 0)
        let id = UUID().uuidString
        let older = decode("W\t1\nE\t\(id)\tfinding\tload.system\t17940096000\t\t\t\tGrund\n")
        #expect(older.events.count == 1)
        #expect(older.events.first?.process == nil)
    }

    @Test func malformedEventProcessIsBroken() {
        let id = UUID().uuidString
        for field in ["4242", "x:1", "4242:", "-1:5", "1:2:3"] {
            let contents = decode("W\t1\nE\t\(id)\tfinding\tload.process\t17940096000\t\t\t\tGrund\t\(field)\n")
            #expect(contents.events.isEmpty, "\(field)")
            #expect(contents.brokenLineCount == 1, "\(field)")
        }
    }

    /// Nur Ereignisse zu lesen überspringt die Messwerte.
    @Test func eventsOnlyDecodingSkipsMeasurements() {
        let event = WatchbookFixtures.event(start: day.start, end: day.start)
        let bytes = WatchbookFileFormat.encode(points: WatchbookFixtures.points(from: day.start, count: 3),
                                               minutes: [], events: [event], of: day)
        let contents = WatchbookFileFormat.decode(bytes, of: day, eventsOnly: true)
        #expect(contents.points.isEmpty && contents.events == [event])
    }
}

@Suite struct WatchbookCompactionTests {
    private let start = WatchbookFixtures.dayStart

    @Test func minutesKeepMeanAndMaximumOfMeasuredValues() throws {
        let points = WatchbookFixtures.points(from: start, count: 6) { [0.25, 0.75, nil, 0.5, 0.25, 0.25][$0] }
        let minutes = WatchbookCompaction.minutes(from: points)
        let minute = try #require(minutes.first)
        #expect(minutes.count == 1)
        #expect(minute.start == start)
        #expect(minute.count == 6)
        #expect(minute.mean[.cpuTotal] == 0.4)
        #expect(minute.maximum[.cpuTotal] == 0.75)
        #expect(minute.mean[.memoryUsed] == 8_589_934_592)
    }

    @Test func minuteWithoutAnyValueOfAMetricStaysEmpty() throws {
        let points = WatchbookFixtures.points(from: start, count: 3) { _ in nil }
        let minute = try #require(WatchbookCompaction.minutes(from: points).first)
        #expect(minute.mean[.cpuTotal] == nil && minute.maximum[.cpuTotal] == nil)
    }

    /// Lücken bleiben Lücken: Minuten ohne Punkt entstehen nicht.
    @Test func minutesWithoutPointsAreNotCreated() {
        let points = WatchbookFixtures.points(from: start, count: 1)
            + WatchbookFixtures.points(from: start.addingTimeInterval(600), count: 1)
        #expect(WatchbookCompaction.minutes(from: points).map(\.start) == [start, start.addingTimeInterval(600)])
    }

    /// Unsortierte Punkte (Uhr zurückgestellt) landen in ihrer Minute.
    @Test func unorderedPointsLandInTheirMinute() {
        let points = WatchbookFixtures.points(from: start.addingTimeInterval(120), count: 2)
            + WatchbookFixtures.points(from: start, count: 2)
        #expect(WatchbookCompaction.minutes(from: points).map(\.start) == [start, start.addingTimeInterval(120)])
    }

    @Test func consumersOfAMinuteAreTheLargestPeaks() throws {
        var first = WatchbookFixtures.point(at: start)
        first.cpuConsumers = [WatchbookConsumer(subject: .program("A"), value: 0.1),
                              WatchbookConsumer(subject: .program("B"), value: 0.05)]
        var second = WatchbookFixtures.point(at: start.addingTimeInterval(10))
        second.cpuConsumers = [WatchbookConsumer(subject: .program("C"), value: 0.3),
                               WatchbookConsumer(subject: .program("A"), value: 0.2),
                               WatchbookConsumer(subject: .otherAccounts, value: 0.01)]
        let minute = try #require(WatchbookCompaction.minutes(from: [first, second]).first)
        #expect(minute.cpuConsumers == [WatchbookConsumer(subject: .program("C"), value: 0.3),
                                        WatchbookConsumer(subject: .program("A"), value: 0.2),
                                        WatchbookConsumer(subject: .program("B"), value: 0.05)])
    }

    /// Kommen nach der Verdichtung noch Punkte derselben Minute hinzu (Uhr zurückgestellt), zählen beide Teile
    /// nach ihrer Zahl an Punkten.
    @Test func mergingMinutesWeighsByPointCount() throws {
        let earlier = WatchbookCompaction.minutes(from: WatchbookFixtures.points(from: start, count: 3) { _ in 0.25 })
        let later = WatchbookFixtures.points(from: start.addingTimeInterval(5), count: 1) { _ in 0.625 }
        let merged = try #require(WatchbookCompaction.minutes(from: later, merging: earlier).first)
        #expect(merged.count == 4)
        #expect(merged.mean[.cpuTotal] == 0.34375)
        #expect(merged.maximum[.cpuTotal] == 0.625)
    }
}
