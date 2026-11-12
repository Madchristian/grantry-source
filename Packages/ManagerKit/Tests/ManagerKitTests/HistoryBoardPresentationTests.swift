import Foundation
import Testing
@testable import ManagerKit

/// Zustandszeile des Verlaufs im Lagebild (LB-3.3, #545; Entwurf LB-3.1, #543): Urteil aus gelesenen und ungelesenen
/// Änderungen, Chips neu und wiederherstellbar, rechts Anzahl und Zeitraum bzw. Treffer des Filters.
@Suite struct HistoryVerdictTests {
    private func events(unreadAdded: Int = 0, unreadModified: Int = 0, read: Int = 0) -> [HistoryEvent] {
        Array(repeating: TestData.historyEvent(.added, .grant(TestData.grant()), isRead: false), count: unreadAdded)
            + Array(repeating: TestData.historyEvent(.modified, .grant(TestData.grant()), isRead: false),
                    count: unreadModified)
            + Array(repeating: TestData.historyEvent(.removed, .autostartItem(TestData.item()), isRead: true),
                    count: read)
    }

    @Test func unreadChangesWithNewAndRestorableChips() {
        let verdict = HistoryVerdict(events: events(unreadAdded: 2, unreadModified: 1, read: 39), hasMore: false,
                                     unreadCount: 3, restorableCount: 2)
        #expect(verdict.title == "3 Änderungen ungelesen")
        #expect(verdict.shield == .calm)
        #expect(verdict.chips == [.new(2), .restorable(2)])
        #expect(verdict.chips.map(\.text) == ["2 neu", "2 wiederherstellbar"])
        #expect(verdict.facts == "42 Änderungen · Gesamter Verlauf")
    }

    @Test func singularTexts() {
        let verdict = HistoryVerdict(events: events(unreadAdded: 1), hasMore: false, unreadCount: 1,
                                     restorableCount: 1)
        #expect(verdict.title == "1 Änderung ungelesen")
        #expect(verdict.facts == "1 Änderung · Gesamter Verlauf")
    }

    @Test func everythingReadKeepsRestorableChip() {
        let verdict = HistoryVerdict(events: events(read: 42), hasMore: false, unreadCount: 0, restorableCount: 2)
        #expect(verdict.title == "Alles gelesen")
        #expect(verdict.chips == [.restorable(2)])
    }

    /// Weitere Seiten liegen noch in der Ablage: die Zahl nennt nur die geladenen, nicht „alle“ Änderungen.
    @Test func morePagesSayLoaded() {
        let verdict = HistoryVerdict(events: events(read: 100), hasMore: true, unreadCount: 0, restorableCount: 0)
        #expect(verdict.facts == "100 geladen · Gesamter Verlauf")
    }

    /// Mit aktivem Filter rechts die Treffer unter den geladenen, keine Chips über den ganzen Verlauf.
    @Test func activeFilterShowsMatchesWithoutChips() {
        let verdict = HistoryVerdict(events: events(unreadAdded: 2, read: 40), hasMore: false, unreadCount: 2,
                                     restorableCount: 2, filter: HistoryFilter(category: .autostart, period: .week),
                                     matchingCount: 2)
        #expect(verdict.title == "2 Änderungen ungelesen")
        #expect(verdict.chips.isEmpty)
        #expect(verdict.facts == "2 von 42 passen")
    }

    @Test func noChangesSinceFirstScan() {
        let verdict = HistoryVerdict(events: [], hasMore: false, unreadCount: 0, restorableCount: 0)
        #expect(verdict.title == "Keine Änderungen")
        #expect(verdict.shield == .calm)
        #expect(verdict.chips.isEmpty)
        #expect(verdict.facts == "seit dem ersten Scan")
    }

    /// Fehlen Quellen, ist „keine Änderungen“ keine Entwarnung: Schildform offen und Chip (Spec § 11.3 c).
    @Test func noChangesWithMissingSourcesIsOpen() {
        let verdict = HistoryVerdict(events: [], hasMore: false, unreadCount: 0, restorableCount: 0, missingSources: 1)
        #expect(verdict.shield == .open)
        #expect(verdict.chips == [.missingSources(1)])
        #expect(verdict.chips.map(\.text) == ["1 Quelle fehlt"])
        #expect(HistoryVerdict.Chip.missingSources(3).text == "3 Quellen fehlen")
    }

    @Test func unreadableHistoryIsOpenWithErrorChip() {
        let verdict = HistoryVerdict(events: [], hasMore: false, unreadCount: 3, restorableCount: 0,
                                     loadError: "Die Ablage des Verlaufs ließ sich nicht öffnen.")
        #expect(verdict.title == "Verlauf nicht lesbar")
        #expect(verdict.shield == .open)
        #expect(verdict.chips == [.error])
        #expect(verdict.chips.map(\.text) == ["Fehler"])
        #expect(verdict.facts == "–")
    }

    /// Ein Fehler beim Lesen der Belege nimmt die geladenen Änderungen nicht weg; die Meldung steht darunter.
    @Test func loadErrorWithEventsKeepsTheVerdict() {
        let verdict = HistoryVerdict(events: events(read: 2), hasMore: false, unreadCount: 0, restorableCount: 0,
                                     loadError: "Belege nicht lesbar")
        #expect(verdict.title == "Alles gelesen")
    }

    @Test func firstLoadHasNoVerdict() {
        let verdict = HistoryVerdict(events: [], hasMore: false, unreadCount: 0, restorableCount: 0, isLoading: true)
        #expect(verdict.title == "Verlauf wird geladen")
        #expect(verdict.shield == .open)
        #expect(verdict.facts.isEmpty)
    }
}

/// Tagesgruppen der Änderungen: Heute, Gestern, dann Wochentag und Datum; neueste zuerst wie geladen.
@Suite struct HistoryDayTests {
    private let calendar = TestData.utcCalendar
    private let locale = Locale(identifier: "de_DE")

    @Test func groupsByDayWithRelativeTitles() {
        let now = TestData.date // 2026-09-21 14:13 UTC, ein Montag
        let today = TestData.historyEvent(.added, .grant(TestData.grant()), at: now.addingTimeInterval(-60))
        let today2 = TestData.historyEvent(.added, .grant(TestData.grant()), at: now.addingTimeInterval(-3_600))
        let yesterday = TestData.historyEvent(.added, .grant(TestData.grant()), at: now.addingTimeInterval(-TestData.day))
        let older = TestData.historyEvent(.added, .grant(TestData.grant()), at: now.addingTimeInterval(-3 * TestData.day))
        let days = HistoryDay.days(of: [today, today2, yesterday, older], now: now, calendar: calendar, locale: locale)
        #expect(days.map(\.title) == ["Heute", "Gestern", "Freitag, 18. Sept."])
        #expect(days.map(\.events) == [[today, today2], [yesterday], [older]])
        #expect(Set(days.map(\.id)).count == 3)
    }

    @Test func emptyEventsGiveNoDays() {
        #expect(HistoryDay.days(of: [], now: TestData.date, calendar: calendar, locale: locale).isEmpty)
    }
}

/// Zeile einer Änderung (Spec § 11.3 d): Name des Eintrags als Titel, darunter Bereich und Art.
@Suite struct ChangeHeadlineTests {
    private func headline(_ kind: ChangeEvent.Kind, _ before: ChangeSubject?, _ after: ChangeSubject?) -> ChangeHeadline {
        ChangeHeadline(ChangeEvent(kind: kind, before: before, after: after, detectedAt: TestData.date))
    }

    @Test func grantNamesServiceAndApp() {
        let grant = TestData.grant("kTCCServiceScreenCapture", client: TestData.app("Fernhilfe"))
        let added = headline(.added, nil, .grant(grant))
        #expect(added.name == "\(grant.serviceName) für Fernhilfe")
        #expect(added.detail == "Berechtigung · erlaubt")
        let denied = TestData.grant("kTCCServiceScreenCapture", client: TestData.app("Fernhilfe"), authValue: .denied)
        #expect(headline(.modified, .grant(grant), .grant(denied)).detail == "Berechtigung · erlaubt → verweigert")
    }

    @Test func autostartNamesLabelAndKindOrChange() {
        let item = TestData.item("com.example.updater")
        #expect(headline(.added, nil, .autostartItem(item)).name == "com.example.updater")
        #expect(headline(.added, nil, .autostartItem(item)).detail == "Autostart · LaunchAgent")
        #expect(headline(.removed, .autostartItem(item), nil).detail == "Autostart · LaunchAgent")
        let disabled = TestData.item("com.example.updater", isEnabled: false)
        #expect(headline(.modified, .autostartItem(item), .autostartItem(disabled)).detail == "Autostart · deaktiviert")
    }

    @Test func mcpServerNamesServerAndChange() {
        let before = TestData.mcpServer(isEnabled: true)
        let after = TestData.mcpServer(isEnabled: false)
        let modified = headline(.modified, .mcpServer(before), .mcpServer(after))
        #expect(modified.name == "filesystem")
        #expect(modified.detail == "Agenten · deaktiviert")
        #expect(headline(.added, nil, .mcpServer(after)).detail == "Agenten · Claude Desktop")
    }

    /// Andere Arten nennen den Bereich und den Titel der Meldung, damit nichts Neues erfunden wird.
    @Test func otherKindsFallBackToAreaAndTitle() {
        let item = TestData.item("com.example.updater")
        let description = ChangeDescription(ChangeEvent(kind: .added, before: nil, after: .autostartItem(item),
                                                        detectedAt: TestData.date))
        #expect(!description.title.isEmpty)
        #expect(ChangeHeadline.area(of: .autostartItem(item)) == "Autostart")
    }
}

/// Zeile eines Belegs unter „Wiederherstellbar“: Name, darunter was geschah und wo.
@Suite struct RestorableRowTextTests {
    @Test func autostartReceipt() {
        let receipt = RemovalReceipt(label: "com.example.updater", backupPath: "/tmp/x/LaunchAgents/u.plist",
                                     isPrivileged: false, wasEnabled: true, wasLoaded: true)
        let change = RestorableChange.autostart(ReceiptEntry(id: UUID(), receipt: receipt, label: "com.example.updater",
                                                             removedAt: TestData.date, eventID: nil))
        #expect(change.rowTitle == "com.example.updater")
        #expect(change.rowDetail == "Autostart entfernt · Benutzer")
    }

    @Test func agentChange() {
        let entry = TestData.mcpServer()
        let change = RestorableChange.agentConfig(AgentConfigChange(id: UUID(), kind: .setEnabled(false),
                                                                    server: entry.reference, changedAt: TestData.date,
                                                                    originalDigest: "a", resultDigest: "b"))
        #expect(change.rowTitle == "filesystem")
        #expect(change.rowDetail == "deaktiviert · Claude Desktop")
    }
}
