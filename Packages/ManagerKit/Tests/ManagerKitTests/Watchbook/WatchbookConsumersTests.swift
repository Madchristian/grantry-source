import Foundation
import Testing
@testable import ManagerKit

/// Größte Verbraucher an der Zeitmarke (TM-12.6): der nächste 10-s-Punkt, sonst die nächste Minute, nur innerhalb des
/// Suchfensters.
@Suite struct WatchbookConsumersTests {
    private typealias Fixtures = WatchbookFixtures
    private let start = WatchbookFixtures.dayStart.addingTimeInterval(36_000)

    @Test func nearestPointWithinTheWindow() throws {
        let points = Fixtures.points(from: start, count: 3)
        let found = try #require(WatchbookConsumers.nearest(to: start.addingTimeInterval(12), within: 15,
                                                            points: points, minutes: []))
        #expect(found.time == start.addingTimeInterval(10))
        #expect(found.cpu == points[1].cpuConsumers)
        #expect(found.memory == points[1].memoryConsumers)
    }

    @Test func nothingOutsideTheWindow() {
        let points = Fixtures.points(from: start, count: 1)
        #expect(WatchbookConsumers.nearest(to: start.addingTimeInterval(40), within: 15, points: points,
                                           minutes: []) == nil)
    }

    /// Ältere Tage haben nur Minutenwerte; ihre Mitte zählt.
    @Test func minuteWhenNoPointIsNear() throws {
        let minutes = WatchbookCompaction.minutes(from: Fixtures.points(from: start, count: 6))
        let found = try #require(WatchbookConsumers.nearest(to: start.addingTimeInterval(50), within: 60, points: [],
                                                            minutes: minutes))
        #expect(found.time == start.addingTimeInterval(30))
        #expect(found.cpu == minutes[0].cpuConsumers)
    }

    /// Ein Punkt ist genauer als eine Minute, auch wenn die Mitte der Minute näher liegt.
    @Test func pointBeatsMinute() throws {
        let minutes = WatchbookCompaction.minutes(from: Fixtures.points(from: start, count: 6))
        let point = Fixtures.point(at: start.addingTimeInterval(45), consumers: false)
        let found = try #require(WatchbookConsumers.nearest(to: start.addingTimeInterval(32), within: 60,
                                                            points: [point], minutes: minutes))
        #expect(found.time == point.time)
        #expect(found.cpu.isEmpty)
    }

    /// Halbe Spalte, mindestens eine Minute.
    @Test func windowFollowsTheColumn() {
        #expect(WatchbookConsumers.window(columnDuration: 3.6) == 60)
        #expect(WatchbookConsumers.window(columnDuration: 600) == 300)
    }

    /// Der Speicher liest geschriebene und noch gepufferte Punkte.
    @Test func storeReadsWrittenAndPendingPoints() throws {
        try Fixtures.withStore { store in
            let written = Fixtures.points(from: start, count: 3)
            _ = try store.append(points: written, events: [])
            #expect(store.consumers(near: start.addingTimeInterval(19), within: 60)?.time
                == start.addingTimeInterval(20))
            let pending = Fixtures.point(at: start.addingTimeInterval(30))
            #expect(store.consumers(near: start.addingTimeInterval(29), within: 60, pendingPoints: [pending])?.time
                == pending.time)
            #expect(store.consumers(near: start.addingTimeInterval(3_600), within: 60) == nil)
        }
    }
}
