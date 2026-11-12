import Foundation
import Testing
@testable import ManagerKit

/// Kurztexte des Menüleisten-Menüs im Lagebild (LB-5.4, #555): Kenndaten der Lagezeile, Köpfe der Panels „Hinweise“,
/// „Beobachtung“ und „Letzte Änderungen“.
@Suite struct MenuBarMenuTextsTests {
    private let scannedAt = TestData.date

    @Test func factsNameTheRunningScanTheLastScanOrNone() {
        #expect(MenuBarMenuTexts.facts(isScanning: true, scannedAt: scannedAt, now: scannedAt) == "Scan läuft")
        #expect(MenuBarMenuTexts.facts(isScanning: false, scannedAt: nil, now: scannedAt) == "kein Scan")
        let time = scannedAt.formatted(date: .omitted, time: .shortened)
        #expect(MenuBarMenuTexts.facts(isScanning: false, scannedAt: scannedAt, now: scannedAt.addingTimeInterval(60))
            == "Scan \(time)")
    }

    @Test func factsOfAnotherDayCarryTheDate() {
        let later = scannedAt.addingTimeInterval(3 * 86_400)
        let text = MenuBarMenuTexts.facts(isScanning: false, scannedAt: scannedAt, now: later)
        #expect(text.hasPrefix("Scan "))
        #expect(text != "Scan \(scannedAt.formatted(date: .omitted, time: .shortened))")
    }

    @Test func noticesDetailCountsOpenNotices() {
        #expect(MenuBarMenuTexts.notices(1) == "1 offen")
        #expect(MenuBarMenuTexts.notices(3) == "3 offen")
    }

    @Test func changesDetailNamesNewestAndUnread() {
        #expect(MenuBarMenuTexts.changes(count: 5, unread: 2) == "5 neueste · 2 ungelesen")
        #expect(MenuBarMenuTexts.changes(count: 3, unread: 0) == "3 neueste")
        #expect(MenuBarMenuTexts.changes(count: 0, unread: 0) == "")
    }

    @Test func observationDetailNamesToolDurationAndEntries() {
        let start = scannedAt
        #expect(MenuBarMenuTexts.observation(name: "Beispiel-Tool", startedAt: start,
                                             now: start.addingTimeInterval(12 * 60), addedCount: 2)
            == "„Beispiel-Tool“ seit 12 Min. · 2 neue Einträge")
        #expect(MenuBarMenuTexts.observation(name: "Beispiel-Tool", startedAt: start, now: start, addedCount: nil)
            == "„Beispiel-Tool“ seit unter 1 Min.")
    }
}
