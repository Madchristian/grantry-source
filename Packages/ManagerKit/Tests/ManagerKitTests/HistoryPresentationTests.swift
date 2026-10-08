import Foundation
import Testing
@testable import ManagerKit

@Suite struct HistoryFilterTests {
    private let now = TestData.date
    private let hour: TimeInterval = 60 * 60

    private func events() -> [HistoryEvent] {
        [
            TestData.historyEvent(.added, .grant(TestData.grant()), at: now.addingTimeInterval(-1 * hour)),
            TestData.historyEvent(.removed, .autostartItem(TestData.item("a")), at: now.addingTimeInterval(-30 * hour)),
            TestData.historyEvent(.modified, .grant(TestData.grant()), at: now.addingTimeInterval(-10 * 24 * hour)),
            TestData.historyEvent(.added, .autostartItem(TestData.item("b")), at: now.addingTimeInterval(-40 * 24 * hour)),
        ]
    }

    @Test func defaultFilterKeepsEverythingInOrder() {
        let events = events()
        #expect(HistoryFilter().apply(events, now: now) == events)
        #expect(!HistoryFilter().isActive)
    }

    @Test func filtersByCategory() {
        let events = events()
        #expect(HistoryFilter(category: .permissions).apply(events, now: now) == [events[0], events[2]])
        #expect(HistoryFilter(category: .autostart).apply(events, now: now) == [events[1], events[3]])
        #expect(HistoryFilter(category: .autostart).isActive)
    }

    @Test func filtersByKind() {
        let events = events()
        #expect(HistoryFilter(kind: .added).apply(events, now: now) == [events[0], events[3]])
        #expect(HistoryFilter(kind: .removed).apply(events, now: now) == [events[1]])
        #expect(HistoryFilter(kind: .modified).apply(events, now: now) == [events[2]])
    }

    @Test(arguments: [
        (HistoryFilter.Period.day, 1), (.week, 2), (.month, 3), (.all, 4),
    ])
    func filtersByPeriod(period: HistoryFilter.Period, count: Int) {
        #expect(HistoryFilter(period: period).apply(events(), now: now).count == count)
    }

    @Test func periodStartIsInclusive() {
        let event = TestData.historyEvent(.added, .grant(TestData.grant()), at: now.addingTimeInterval(-24 * hour))
        #expect(HistoryFilter(period: .day).matches(event, now: now))
    }

    @Test func combinesAllCriteria() {
        let filter = HistoryFilter(category: .autostart, kind: .removed, period: .week)
        let events = events()
        #expect(filter.apply(events, now: now) == [events[1]])
    }

    @Test func olderPagesOnlyMatterWhileInsideThePeriod() {
        let events = events()
        #expect(HistoryFilter(period: .week).canMatchEvents(olderThan: events[1], now: now))
        #expect(!HistoryFilter(period: .week).canMatchEvents(olderThan: events[2], now: now))
        #expect(HistoryFilter(period: .all).canMatchEvents(olderThan: events[3], now: now))
        #expect(HistoryFilter(period: .day).canMatchEvents(olderThan: nil, now: now))
    }

    @Test func namesAreGerman() {
        #expect(HistoryFilter.Category.permissions.displayName == "Berechtigungen")
        #expect(HistoryFilter.Period.month.displayName == "Letzte 30 Tage")
        #expect(ChangeEvent.Kind.removed.displayName == "Entfernt")
    }

    @Test func securityCategoryMatchesOnlySecurityEvents() {
        let check = TestData.securityCheck(TestData.firewallOn, state: .good)
        let event = TestData.historyEvent(.modified, .securityCheck(check), at: now)
        #expect(HistoryFilter(category: .security).matches(event, now: now))
        #expect(!HistoryFilter(category: .permissions).matches(event, now: now))
        #expect(!HistoryFilter(category: .autostart).matches(event, now: now))
        #expect(HistoryFilter(category: .security).apply(events(), now: now).isEmpty)
        #expect(HistoryFilter.Category.security.displayName == "Sicherheit")
        #expect(HistoryFilter.Category.allCases == [.all, .apps, .agents, .permissions, .autostart, .security, .network])
    }

    @Test func appsCategoryMatchesOnlyAppEvents() {
        let appEvent = TestData.historyEvent(.added, .installedApp(TestData.installedApp()), at: now)
        let grantEvent = TestData.historyEvent(.added, .grant(TestData.grant()), at: now)
        let filter = HistoryFilter(category: .apps)
        #expect(filter.matches(appEvent, now: now))
        #expect(!filter.matches(grantEvent, now: now))
        #expect(!HistoryFilter(category: .permissions).matches(appEvent, now: now))
        #expect(HistoryFilter.Category.apps.displayName == "Apps")
    }

    @Test func networkCategoryMatchesOnlyListenerEvents() {
        let listenerEvent = TestData.historyEvent(.added, .networkListener(TestData.listener()), at: now)
        let filter = HistoryFilter(category: .network)
        #expect(filter.matches(listenerEvent, now: now))
        #expect(filter.apply(events(), now: now).isEmpty)
        #expect(!HistoryFilter(category: .apps).matches(listenerEvent, now: now))
        #expect(HistoryFilter.Category.network.displayName == "Netzwerk")
    }
}

@Suite struct RestoreMatchingTests {
    private let removedAt = TestData.date

    private func agent(_ label: String, plistPath: String? = nil, domain: AutostartDomain = .user) -> AutostartItem {
        var item = TestData.item(label, domain: domain)
        item.plistPath = plistPath ?? "/Users/test/Library/LaunchAgents/\(label).plist"
        return item
    }

    private func removal(_ item: AutostartItem, after seconds: TimeInterval = 5) -> HistoryEvent {
        TestData.historyEvent(.removed, .autostartItem(item), at: removedAt.addingTimeInterval(seconds))
    }

    private func entry(
        _ label: String, backup: String? = nil, privileged: Bool = false, at date: Date? = nil, eventID: UUID? = nil
    ) -> ReceiptEntry {
        let receipt = RemovalReceipt(
            label: label,
            backupPath: backup ?? "/Users/test/Library/Application Support/Grantry/Backups/20260926-120000-000/LaunchAgents/\(label).plist",
            isPrivileged: privileged, wasEnabled: true, wasLoaded: true
        )
        return ReceiptEntry(id: UUID(), receipt: receipt, label: label, removedAt: date ?? removedAt, eventID: eventID)
    }

    @Test func matchesByLabelLocationAndTime() {
        let event = removal(agent("com.example.a"))
        let receipt = entry("com.example.a")
        #expect(RestoreMatching.receiptsByEvent(events: [event], receipts: [receipt]) == [event.id: receipt])
    }

    @Test func matchesSystemDaemonsOnlyWithPrivilegedReceipts() {
        let daemon = agent("com.example.d", plistPath: "/Library/LaunchDaemons/com.example.d.plist", domain: .system)
        let event = removal(daemon)
        let backup = "/Library/Application Support/Grantry/Backups/20260926-120000-000/LaunchDaemons/com.example.d.plist"
        let privileged = entry("com.example.d", backup: backup, privileged: true)
        #expect(RestoreMatching.receiptsByEvent(events: [event], receipts: [privileged]) == [event.id: privileged])
        let unprivileged = entry("com.example.d", backup: backup, privileged: false)
        #expect(RestoreMatching.receiptsByEvent(events: [event], receipts: [unprivileged]).isEmpty)
    }

    @Test func rejectsOtherLabelOtherLocationOrDistantTime() {
        let event = removal(agent("com.example.a"))
        let wrongLabel = entry("com.example.b", backup: "/x/20260926-120000-000/LaunchAgents/com.example.a.plist")
        let wrongDirectory = entry("com.example.a", backup: "/x/20260926-120000-000/LaunchDaemons/com.example.a.plist")
        let wrongFile = entry("com.example.a", backup: "/x/20260926-120000-000/LaunchAgents/other.plist")
        let tooEarly = entry("com.example.a", at: removedAt.addingTimeInterval(-RestoreMatching.defaultTolerance - 60))
        for receipt in [wrongLabel, wrongDirectory, wrongFile, tooEarly] {
            #expect(RestoreMatching.receiptsByEvent(events: [event], receipts: [receipt]).isEmpty)
        }
    }

    @Test func ignoresEventsThatAreNotLaunchdRemovals() {
        let item = agent("com.example.a")
        var btm = item
        btm.source = .btm
        let receipt = entry("com.example.a")
        let events = [
            TestData.historyEvent(.added, .autostartItem(item), at: removedAt),
            TestData.historyEvent(.modified, .autostartItem(item), at: removedAt),
            removal(btm),
            TestData.historyEvent(.removed, .grant(TestData.grant()), at: removedAt),
        ]
        #expect(RestoreMatching.receiptsByEvent(events: events, receipts: [receipt]).isEmpty)
    }

    @Test func prefersTheClosestEventAndAssignsEachEventOnce() {
        let item = agent("com.example.a")
        let early = removal(item, after: -120)
        let late = removal(item, after: 300)
        let first = entry("com.example.a", at: removedAt)
        let second = entry("com.example.a", at: removedAt.addingTimeInterval(290))
        let matches = RestoreMatching.receiptsByEvent(events: [late, early], receipts: [first, second])
        #expect(matches == [late.id: second, early.id: first])
    }

    @Test func explicitEventIDWins() {
        let item = agent("com.example.a")
        let event = removal(item)
        let other = removal(item, after: 600)
        let linked = entry("com.example.a", at: removedAt.addingTimeInterval(590), eventID: event.id)
        let unlinked = entry("com.example.a", at: removedAt)
        let matches = RestoreMatching.receiptsByEvent(events: [event, other], receipts: [unlinked, linked])
        #expect(matches[event.id] == linked)
        #expect(matches[other.id] == unlinked)
    }

    /// Autostart-Belege unter `unmatchedRestorables` (ohne Agenten-Änderungen).
    private func unmatched(
        _ receipts: [ReceiptEntry], matches: [HistoryEvent.ID: RestorableChange], filter: HistoryFilter
    ) -> [ReceiptEntry] {
        RestoreMatching.unmatchedRestorables(receipts: receipts, changes: [], matches: matches, filter: filter, now: removedAt)
            .compactMap { if case .autostart(let entry) = $0 { entry } else { nil } }
    }

    @Test func unmatchedReceiptsAreThoseWithoutAnyLoadedEvent() {
        let event = removal(agent("com.example.a"))
        let matched = entry("com.example.a")
        let older = entry("com.example.x", at: removedAt.addingTimeInterval(-3600))
        let newer = entry("com.example.y", at: removedAt.addingTimeInterval(3600))
        let matches = RestoreMatching.restorablesByEvent(events: [event], receipts: [older, matched, newer], changes: [])
        #expect(unmatched([older, matched, newer], matches: matches, filter: HistoryFilter()) == [newer, older])
    }

    /// Ist nur das Ereignis ausgefiltert, erscheint sein Beleg nicht doppelt unter „Wiederherstellbar“.
    @Test func receiptOfAFilteredEventIsNoOrphan() {
        let event = removal(agent("com.example.a"))
        let matched = entry("com.example.a")
        let matches = RestoreMatching.restorablesByEvent(events: [event], receipts: [matched], changes: [])
        let onlyAdditions = HistoryFilter(kind: .added)
        #expect(unmatched([matched], matches: matches, filter: onlyAdditions).isEmpty)
    }

    /// Belege sind entfernte Autostart-Einträge: Sie folgen Art-, Änderungs- und Zeitraumfilter.
    @Test func orphansFollowTheFilter() {
        let orphan = entry("com.example.x", at: removedAt.addingTimeInterval(-2 * 24 * 3600))
        func unmatched(_ filter: HistoryFilter) -> [ReceiptEntry] {
            self.unmatched([orphan], matches: [:], filter: filter)
        }
        #expect(unmatched(HistoryFilter()) == [orphan])
        #expect(unmatched(HistoryFilter(category: .autostart, kind: .removed)) == [orphan])
        #expect(unmatched(HistoryFilter(category: .permissions)).isEmpty)
        #expect(unmatched(HistoryFilter(category: .security)).isEmpty)
        #expect(unmatched(HistoryFilter(kind: .modified)).isEmpty)
        #expect(unmatched(HistoryFilter(period: .day)).isEmpty)
        #expect(unmatched(HistoryFilter(period: .week)) == [orphan])
    }

    @Test func restorePresentation() {
        let receipt = entry("com.example.a")
        #expect(ActionOutcomePresentation.restore(receipt, outcome: .done).text == "„com.example.a“ wurde wiederhergestellt.")
    }
}
