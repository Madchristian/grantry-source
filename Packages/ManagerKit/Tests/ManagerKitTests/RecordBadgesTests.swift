import Foundation
import Testing
@testable import ManagerKit

@Suite struct RecordBadgesTests {
    private let now = TestData.date
    private let grant = TestData.grant()
    private let day: TimeInterval = 24 * 60 * 60

    private func added(_ grant: PermissionGrant, daysAgo: Double) -> HistoryEvent {
        TestData.historyEvent(.added, .grant(grant), at: now.addingTimeInterval(-daysAgo * day))
    }

    private func finding(_ severity: RiskFinding.Severity, rule: RiskFinding.Rule = .orphan) -> RiskFinding {
        RiskFinding(rule: rule, severity: severity, recordID: grant.id, message: "")
    }

    /// Der Schweregrad ist nicht nur an der Farbe erkennbar: eigenes Symbol und ausgesprochener Text.
    @Test func reviewSeverityHasSymbolAndSpokenLabel() {
        #expect(RecordBadge.review(.high).systemImage == "exclamationmark.octagon.fill")
        #expect(RecordBadge.review(.medium).systemImage == "exclamationmark.triangle.fill")
        #expect(RecordBadge.review(.low).systemImage == "info.circle.fill")
        #expect(Set([RiskFinding.Severity.low, .medium, .high].map { RecordBadge.review($0).systemImage }).count == 3)
        #expect(RecordBadge.review(.high).accessibilityLabel == "prüfen, Schweregrad hoch")
        #expect(RecordBadge.review(.medium).accessibilityLabel == "prüfen, Schweregrad mittel")
        #expect(RecordBadge.review(.low).accessibilityLabel == "prüfen, Schweregrad niedrig")
        #expect(RecordBadge.new.systemImage == nil && RecordBadge.new.accessibilityLabel == "neu")
        #expect(RecordBadge.cleanup.systemImage == nil && RecordBadge.cleanup.accessibilityLabel == "aufräumen")
    }

    @Test func noBadgesWithoutEvidence() {
        #expect(RecordBadges.badges(for: grant.id, findings: [], events: [], cleanupHints: [], now: now).isEmpty)
    }

    @Test func newWhenAddedWithinSevenDays() {
        let badges = RecordBadges.badges(
            for: grant.id, findings: [], events: [added(grant, daysAgo: 6.9)], cleanupHints: [], now: now
        )
        #expect(badges == [.new])
    }

    @Test func notNewWhenAddedEarlierOrOnlyModified() {
        let modified = TestData.historyEvent(.modified, .grant(grant), at: now)
        let badges = RecordBadges.badges(
            for: grant.id, findings: [], events: [added(grant, daysAgo: 7.1), modified], cleanupHints: [], now: now
        )
        #expect(badges.isEmpty)
    }

    @Test func notNewForOtherRecords() {
        let other = TestData.grant(client: TestData.app("com.other"))
        let badges = RecordBadges.badges(
            for: grant.id, findings: [], events: [added(other, daysAgo: 1)], cleanupHints: [], now: now
        )
        #expect(badges.isEmpty)
    }

    @Test func reviewCarriesHighestSeverity() {
        let findings = [finding(.low, rule: .sensitiveNonNotarized), finding(.high, rule: .unsignedClient)]
        let badges = RecordBadges.badges(for: grant.id, findings: findings, events: [], cleanupHints: [], now: now)
        #expect(badges == [.review(.high)])
    }

    @Test func allBadgesInFixedOrder() {
        let hint = CleanupHint(recordID: grant.id, message: "x")
        let badges = RecordBadges.badges(
            for: grant.id, findings: [finding(.medium)], events: [added(grant, daysAgo: 1)], cleanupHints: [hint],
            now: now
        )
        #expect(badges == [.new, .review(.medium), .cleanup])
    }

    @Test func precomputedIndexMatchesStaticFunction() {
        let index = RecordBadges(findings: [finding(.low)], events: [added(grant, daysAgo: 2)], cleanupHints: [], now: now)
        #expect(index.badges(for: grant.id) == [.new, .review(.low)])
        #expect(index.badges(for: "unbekannt").isEmpty)
    }

    @Test func titlesAndTones() {
        #expect(RecordBadge.new.title == "neu")
        #expect(RecordBadge.review(.low).title == "prüfen")
        #expect(RecordBadge.cleanup.title == "aufräumen")
        #expect(RecordBadge.review(.high).tone == .critical)
        #expect(RecordBadge.review(.medium).tone == .warning)
        #expect(RecordBadge.review(.low).tone == .warning)
        #expect(RecordBadge.new.tone == .neutral)
        #expect(RecordBadge.cleanup.tone == .neutral)
    }

    @Test func changeSubjectRecordIDMatchesRecordID() {
        let item = TestData.item()
        #expect(ChangeSubject.grant(grant).recordID == grant.id)
        #expect(ChangeSubject.autostartItem(item).recordID == item.id)
    }
}
