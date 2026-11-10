import Foundation
import Testing
@testable import ManagerKit

@Suite struct WatchbookJournalTests {
    private typealias Fixtures = WatchbookFixtures
    private let start = WatchbookFixtures.dayStart

    private func everything(in store: WatchbookStore) -> WatchbookRecords {
        store.records(in: Date(timeIntervalSince1970: 0)..<Date(timeIntervalSince1970: 4_000_000_000))
    }

    /// Gebündelt höchstens alle 60 s geschrieben (Spec §5.1).
    @Test func writesAtMostEveryMinute() throws {
        try Fixtures.withStore { store in
            let journal = WatchbookJournal(store: store)
            let points = Fixtures.points(from: start, count: 13)
            for point in points.prefix(6) { try journal.record(point, now: point.time) }
            #expect(!FileManager.default.fileExists(atPath: store.directory.path))
            #expect(journal.pendingPoints.count == 6)
            try journal.record(points[6], now: points[6].time)
            #expect(everything(in: store).points == Array(points.prefix(7)))
            #expect(journal.pendingPoints.isEmpty)
            for point in points[7..<12] { try journal.record(point, now: point.time) }
            #expect(everything(in: store).points.count == 7)
            try journal.record(points[12], now: points[12].time)
            #expect(everything(in: store).points == points)
        }
    }

    @Test func eventsAreBatchedLikePoints() throws {
        try Fixtures.withStore { store in
            let journal = WatchbookJournal(store: store)
            let event = Fixtures.event(start: start, end: nil)
            try journal.record(event, now: start)
            #expect(journal.pendingEvents == [event])
            try journal.record(event.ended(at: start.addingTimeInterval(30)), now: start.addingTimeInterval(30))
            try journal.record(Fixtures.point(at: start.addingTimeInterval(60)), now: start.addingTimeInterval(60))
            #expect(everything(in: store).events == [event.ended(at: start.addingTimeInterval(30))])
        }
    }

    /// Uhr zurückgestellt: Es wird weiter geschrieben, nichts geht verloren, und es entsteht keine weitere Datei.
    @Test func clockGoingBackKeepsWritingWithoutLosingPoints() throws {
        try Fixtures.withStore { store in
            let journal = WatchbookJournal(store: store)
            let before = Fixtures.points(from: start.addingTimeInterval(7_200), count: 7)
            for point in before { try journal.record(point, now: point.time) }
            let after = Fixtures.points(from: start.addingTimeInterval(3_600), count: 7)
            for point in after { try journal.record(point, now: point.time) }
            #expect(journal.pendingPoints.isEmpty)
            let records = everything(in: store)
            #expect(records.points == (after + before).sorted { $0.time < $1.time })
            #expect(try Fixtures.names(in: store) == [WatchbookFixtures.day.fileName])
        }
    }

    /// Uhr über Mitternacht in einen schon verdichteten Tag zurückgestellt: Die neuen Punkte werden mit den
    /// Minutenwerten des Tages zusammengeführt, nicht doppelt geführt.
    @Test func clockGoingBackIntoACompactedDayMergesItsMinutes() throws {
        try Fixtures.withStore { store in
            let journal = WatchbookJournal(store: store)
            let day = WatchbookFixtures.day
            let early = Fixtures.points(from: start, count: 6) { _ in 0.25 }
            try store.append(points: early, events: [])
            let later = day.end.addingTimeInterval(2 * 86_400)
            try journal.record(Fixtures.point(at: later), now: later)
            try journal.flush(now: later)
            #expect(everything(in: store).minutes.count == 1)
            let replayed = Fixtures.points(from: start.addingTimeInterval(5), count: 2) { _ in 0.625 }
            for point in replayed { try journal.record(point, now: later) }
            try journal.flush(now: later.addingTimeInterval(60))
            let minutes = everything(in: store).minutes
            #expect(minutes.count == 1)
            #expect(minutes.first?.count == 8)
            #expect(minutes.first?.maximum[.cpuTotal] == 0.625)
            #expect(everything(in: store).points.map(\.time) == [later])
        }
    }

    /// Zeitzonenwechsel und Sommerzeit: Die Tage sind UTC-Tage. Ein Flug von Berlin nach Los Angeles und das Ende der
    /// Sommerzeit ergeben je Tag genau eine Datei, ohne doppelte oder verlorene Punkte – obwohl dieselben Punkte nach
    /// Ortszeit über die Wechsel hinweg teils zweimal auf dasselbe Datum fielen.
    @Test func timeZoneChangesNeitherDuplicateNorLoseDays() throws {
        try Fixtures.withStore { store in
            let journal = WatchbookJournal(store: store)
            // 24. Oktober 2026, 00:00 UTC: einen Tag vor dem Ende der Sommerzeit in Berlin (25. Oktober, 01:00 UTC).
            let first = Date(timeIntervalSince1970: 1_792_800_000)
            let points = Fixtures.points(from: first, count: 2 * 144, every: 600)
            for point in points { try journal.record(point, now: point.time) }
            // Nach Ortszeit fiele der Abend in Los Angeles auf ein Datum, das in Berlin schon vergangen war.
            var berlin = Calendar(identifier: .gregorian), losAngeles = berlin
            berlin.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
            losAngeles.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
            let lastInBerlin = berlin.startOfDay(for: points[143].time)
            #expect(losAngeles.startOfDay(for: points[144].time) < lastInBerlin)
            try journal.flush(now: points[points.count - 1].time)
            let days = try Fixtures.names(in: store).compactMap(WatchbookDay.init(fileName:)).map(\.index)
            let firstDay = WatchbookDay(containing: first).index
            #expect(days == [firstDay, firstDay + 1])
            let read = everything(in: store).points
            #expect(read.count == points.count)
            #expect(Set(read.map(\.time)).count == points.count)
        }
    }

    @Test func firstWriteOfADayRunsTheMaintenance() throws {
        try Fixtures.withStore { store in
            let journal = WatchbookJournal(store: store)
            try store.append(points: Fixtures.points(from: start, count: 6), events: [])
            let twoDaysLater = WatchbookFixtures.day.end.addingTimeInterval(86_400 + 10)
            try journal.record(Fixtures.point(at: twoDaysLater), now: twoDaysLater)
            try journal.flush(now: twoDaysLater)
            #expect(everything(in: store).minutes.count == 1)
        }
    }

    /// „Wachbuch löschen“ verwirft auch, was noch nicht geschrieben ist.
    @Test func removeDropsPendingRecords() throws {
        try Fixtures.withStore { store in
            let journal = WatchbookJournal(store: store)
            let points = Fixtures.points(from: start, count: 8)
            for point in points.prefix(7) { try journal.record(point, now: point.time) }
            try journal.record(points[7], now: points[7].time)
            #expect(journal.pendingPoints.count == 1)
            try journal.remove()
            #expect(journal.pendingPoints.isEmpty && journal.pendingEvents.isEmpty)
            try journal.flush(now: points[7].time.addingTimeInterval(120))
            #expect(!FileManager.default.fileExists(atPath: store.directory.path))
        }
    }

    /// Die Ansicht sieht auch, was noch im Puffer liegt.
    @Test func seriesIncludesPendingRecords() throws {
        try Fixtures.withStore { store in
            let journal = WatchbookJournal(store: store)
            let point = Fixtures.point(at: start.addingTimeInterval(5))
            try journal.record(point, now: point.time)
            let series = journal.series(.hour, endingAt: start.addingTimeInterval(10), width: 360)
            #expect(series.statistics(of: .cpuTotal).compactMap { $0 }.isEmpty == false)
        }
    }

    /// Schlägt das Schreiben fehl, bleibt der Puffer für den nächsten Versuch – aber begrenzt.
    @Test func failedWritesKeepABoundedBuffer() throws {
        try Fixtures.withStore { store in
            try FileManager.default.createDirectory(at: store.directory.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("kein Ordner".utf8).write(to: store.directory)
            let journal = WatchbookJournal(store: store, maximumPending: 10)
            let points = Fixtures.points(from: start, count: 20)
            for point in points.prefix(19) { try? journal.record(point, now: start) }
            #expect(throws: (any Error).self) { try journal.flush(now: start) }
            #expect(journal.pendingPoints.count == 10)
            #expect(journal.pendingPoints.last == points[18])
        }
    }
}
