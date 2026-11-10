import Foundation
import Testing
@testable import ManagerKit

/// Wachbuch an einem Zeitpunkt öffnen (Mitteilung zu einem schweren Befund, TM-12.8a).
@Suite struct WatchbookFocusTests {
    private let now = WatchbookFixtures.dayStart.addingTimeInterval(8 * 86_400)
    private var recordingSince: Date { now.addingTimeInterval(-10 * 86_400) }

    private func focus(ago age: TimeInterval, recordingSince: Date? = nil) -> WatchbookFocus? {
        WatchbookFocus(markerAt: now.addingTimeInterval(-age), now: now,
                       recordingSince: recordingSince ?? self.recordingSince)
    }

    /// Der kürzeste Zeitraum, in dem die Zeitmarke mit Abstand zum linken Rand liegt; die Marke bleibt der Zeitpunkt.
    @Test(arguments: [(TimeInterval(60), WatchbookPeriod.hour), (3_400, .sixHours), (5.5 * 3_600, .day),
                      (22 * 3_600, .week), (6 * 86_400, .week)])
    func choosesTheShortestPeriodShowingTheMarker(age: TimeInterval, period: WatchbookPeriod) throws {
        let focus = try #require(focus(ago: age))
        #expect(focus.period == period)
        #expect(focus.marker == now.addingTimeInterval(-age))
        #expect(age < focus.period.duration)
    }

    /// Kurz vor dem Ende der Aufbewahrung bleibt der 7-Tage-Zeitraum, auch ohne Abstand zum Rand.
    @Test func keepsTheWeekUntilTheEndOfRetention() {
        #expect(focus(ago: WatchbookStore.retention - 60)?.period == .week)
    }

    /// Älter als die Aufbewahrung, vor Beginn der Aufzeichnung (gelöscht) oder in der Zukunft: keine Zeitmarke.
    @Test func timesOutsideTheRecordingHaveNoFocus() {
        #expect(focus(ago: WatchbookStore.retention + 60) == nil)
        #expect(focus(ago: 3_600, recordingSince: now.addingTimeInterval(-1_800)) == nil)
        #expect(focus(ago: -60) == nil)
    }

    /// Unbekannter Beginn der Aufzeichnung schränkt nur die Aufbewahrung ein.
    @Test func unknownRecordingStartOnlyLimitsByRetention() {
        let focus = WatchbookFocus(markerAt: now.addingTimeInterval(-600), now: now, recordingSince: nil)
        #expect(focus?.period == .hour)
    }
}
