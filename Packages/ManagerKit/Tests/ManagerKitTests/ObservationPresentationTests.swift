import Foundation
import Testing
@testable import ManagerKit

@Suite("Texte zur Beobachtung")
struct ObservationPresentationTests {
    @Test func statusLineNamesDurationAndNewEntries() {
        let start = TestData.date
        #expect(ObservationTexts.statusLine(name: "Cursor", startedAt: start, now: start.addingTimeInterval(12 * 60), addedCount: 4)
            == "Beobachtung „Cursor“ läuft seit 12 Min. – 4 neue Einträge")
        #expect(ObservationTexts.statusLine(name: "Cursor", startedAt: start, now: start, addedCount: nil)
            == "Beobachtung „Cursor“ läuft seit unter 1 Min.")
    }

    private static let durationCases: [(TimeInterval, String)] = [
        (30, "unter 1 Min."), (3_540, "59 Min."), (3_600, "1 Std."), (7_500, "2 Std. 5 Min."), (259_200, "3 Tagen"),
    ]

    @Test(arguments: durationCases)
    func durations(seconds: TimeInterval, text: String) {
        #expect(ObservationTexts.duration(from: TestData.date, to: TestData.date.addingTimeInterval(seconds)) == text)
    }

    @Test func entryCounts() {
        #expect(ObservationTexts.entries(0) == "keine neuen Einträge")
        #expect(ObservationTexts.entries(1) == "1 neuer Eintrag")
        #expect(ObservationTexts.entries(3) == "3 neue Einträge")
    }

    @Test func notesOnlyWhenSourcesAreAffected() {
        #expect(ObservationTexts.failedSourcesNote([]) == nil)
        #expect(ObservationTexts.firstDeliveredNote(["Hintergrundobjekte"])?.hasPrefix("Erst während der Beobachtung") == true)
    }

    @Test func menuBarShowsADotWhileObserving() {
        #expect(MenuBarBadge(unreadCount: 0, isObserving: true) == .dot)
        #expect(MenuBarBadge(unreadCount: 3, isObserving: true) == .count(3))
        #expect(MenuBarBadge(unreadCount: 0) == MenuBarBadge.none)
        #expect(MenuBarBadge.accessibilityLabel(unreadCount: 1, isObserving: true)
            == "Grantry, 1 ungelesene Änderung, Beobachtung läuft")
    }
}
