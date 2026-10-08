import Foundation
import Testing
@testable import ManagerKit

@Suite struct DashboardMetricsTests {
    private let now = TestData.date
    private let day: TimeInterval = 24 * 60 * 60

    @Test func countsDistinctAppsWithGrantedAccess() {
        let zoom = TestData.app("us.zoom.xos")
        let snapshot = TestData.snapshot(grants: [
            TestData.grant("kTCCServiceCamera", client: zoom),
            TestData.grant("kTCCServiceMicrophone", client: zoom, authValue: .limited),
            TestData.grant(client: zoom, scope: .system),
            TestData.grant(client: TestData.app("com.denied"), authValue: .denied),
            TestData.grant(client: TestData.app("com.odd"), authValue: .unknown(5)),
            TestData.grant(client: TestData.app("com.other")),
        ])
        let metrics = DashboardMetrics.compute(snapshot: snapshot, findings: [], events: [], now: now)
        #expect(metrics.appsWithAccess == 2)
    }

    @Test func countsPresentRecordsAddedInTheLastSevenDays() {
        let grant = TestData.grant()
        let item = TestData.item()
        let old = TestData.grant(client: TestData.app("com.old"))
        let events = [
            TestData.historyEvent(.added, .grant(grant), at: now.addingTimeInterval(-1 * day)),
            TestData.historyEvent(.added, .autostartItem(item), at: now.addingTimeInterval(-6 * day)),
            TestData.historyEvent(.added, .grant(old), at: now.addingTimeInterval(-8 * day)),
            TestData.historyEvent(.modified, .autostartItem(item), at: now),
        ]
        let snapshot = TestData.snapshot(grants: [grant, old], items: [item])
        let metrics = DashboardMetrics.compute(snapshot: snapshot, findings: [], events: events, now: now)
        #expect(metrics.newSince7Days == 2)
    }

    @Test func countsRecentlyAddedAgentEntries() {
        let server = TestData.mcpServer()
        let approval = TestData.autoApproval()
        let events = [
            TestData.historyEvent(.added, .mcpServer(server), at: now.addingTimeInterval(-1 * day)),
            TestData.historyEvent(.added, .agentAutoApproval(approval), at: now.addingTimeInterval(-2 * day)),
        ]
        let snapshot = TestData.agentSnapshot([server], approvals: [approval])
        let metrics = DashboardMetrics.compute(snapshot: snapshot, findings: [], events: events, now: now)
        #expect(metrics.newSince7Days == 2)
    }

    @Test func reAddedRecordCountsOnce() {
        let grant = TestData.grant()
        let events = [
            TestData.historyEvent(.added, .grant(grant), at: now.addingTimeInterval(-3 * day)),
            TestData.historyEvent(.removed, .grant(grant), at: now.addingTimeInterval(-2 * day)),
            TestData.historyEvent(.added, .grant(grant), at: now.addingTimeInterval(-1 * day)),
        ]
        let metrics = DashboardMetrics.compute(
            snapshot: TestData.snapshot(grants: [grant]), findings: [], events: events, now: now
        )
        #expect(metrics.newSince7Days == 1)
    }

    @Test func addedThenRemovedRecordDoesNotCount() {
        let grant = TestData.grant()
        let events = [
            TestData.historyEvent(.added, .grant(grant), at: now.addingTimeInterval(-2 * day)),
            TestData.historyEvent(.removed, .grant(grant), at: now.addingTimeInterval(-1 * day)),
        ]
        let metrics = DashboardMetrics.compute(snapshot: TestData.snapshot(), findings: [], events: events, now: now)
        #expect(metrics.newSince7Days == 0)
    }

    @Test func appsWithAccessExcludesAppleComponents() {
        let snapshot = TestData.snapshot(grants: [
            TestData.grant(client: TestData.app("com.apple.Terminal", signing: SigningInfo(kind: .apple))),
            TestData.grant(client: TestData.app("com.thirdparty")),
        ])
        let metrics = DashboardMetrics.compute(snapshot: snapshot, findings: [], events: [], now: now)
        #expect(metrics.appsWithAccess == 1)
    }

    @Test func countsFlaggedRecordsOnce() {
        let findings = [
            RiskFinding(rule: .unsignedClient, severity: .high, recordID: "a", message: ""),
            RiskFinding(rule: .orphan, severity: .medium, recordID: "a", message: ""),
            RiskFinding(rule: .orphan, severity: .medium, recordID: "b", message: ""),
        ]
        let metrics = DashboardMetrics.compute(snapshot: TestData.snapshot(), findings: findings, events: [], now: now)
        #expect(metrics.flaggedCount == 2)
        #expect(metrics.hintCount == 0)
    }

    /// „Auffällig“ zählt nur mittel und hoch; Einträge, deren höchster Befund niedrig ist, sind Hinweise.
    @Test func lowFindingsCountAsHintsNotAsFlagged() {
        let findings = [
            RiskFinding(rule: .unsignedProgram, severity: .low, recordID: "a", message: ""),
            RiskFinding(rule: .orphan, severity: .medium, recordID: "a", message: ""),
            RiskFinding(rule: .unsignedProgram, severity: .low, recordID: "b", message: ""),
            RiskFinding(rule: .unsignedProgram, severity: .low, recordID: "c", message: ""),
            RiskFinding(rule: .sensitiveNonNotarized, severity: .low, recordID: "c", message: ""),
        ]
        let metrics = DashboardMetrics.compute(snapshot: TestData.snapshot(), findings: findings, events: [], now: now)
        #expect(metrics.flaggedCount == 1)
        #expect(metrics.hintCount == 2)
        #expect(metrics.hasFindings)
    }

    @Test(arguments: [
        (0, 0, "Keine Auffälligkeiten gefunden", "Keine Auffälligkeiten gefunden"),
        (2, 0, "Einträge mit Prüfbedarf", "Einträge mit Prüfbedarf"),
        (2, 1, "Einträge mit Prüfbedarf · 1 Hinweis", "Einträge mit Prüfbedarf, dazu 1 Hinweis mit niedrigem Risiko"),
        (0, 3, "Keine Auffälligkeiten · 3 Hinweise", "Keine Auffälligkeiten, dazu 3 Hinweise mit niedrigem Risiko"),
    ])
    func flaggedCaptionNamesHintsSeparately(flagged: Int, hints: Int, caption: String, spoken: String) {
        let metrics = DashboardMetrics(appsWithAccess: 0, newSince7Days: 0, flaggedCount: flagged, hintCount: hints, recentChanges: [])
        #expect(metrics.flaggedCaption == caption)
        #expect(metrics.flaggedAccessibilityCaption == spoken)
        #expect(metrics.hasFindings == (flagged + hints > 0))
    }

    /// Bedienhinweis der Kachel „Auffällig“: auffällige Einträge vor Hinweisen, sonst die Berechtigungen.
    @Test(arguments: [
        (0, 0, "Zeigt die Berechtigungen."),
        (2, 0, "Zeigt nur die auffälligen Einträge."),
        (2, 1, "Zeigt nur die auffälligen Einträge."),
        (0, 3, "Zeigt die Einträge mit Hinweisen."),
    ])
    func flaggedHintMatchesWhatTheTileOpens(flagged: Int, hints: Int, hint: String) {
        let metrics = DashboardMetrics(appsWithAccess: 0, newSince7Days: 0, flaggedCount: flagged, hintCount: hints, recentChanges: [])
        #expect(metrics.flaggedHint == hint)
    }

    @Test func recentChangesAreTheFiveNewest() {
        let grant = TestData.grant()
        let events = (0..<7).map { offset in
            TestData.historyEvent(.modified, .grant(grant), at: now.addingTimeInterval(-Double(offset) * 60))
        }
        let metrics = DashboardMetrics.compute(
            snapshot: TestData.snapshot(), findings: [], events: events.reversed(), now: now
        )
        #expect(metrics.recentChanges.map(\.id) == Array(events.prefix(DashboardMetrics.recentChangesLimit)).map(\.id))
        #expect(DashboardMetrics.recentChangesLimit == 5)
    }

    @Test func emptyInputsYieldZeroes() {
        let metrics = DashboardMetrics.compute(snapshot: TestData.snapshot(), findings: [], events: [], now: now)
        #expect(metrics == DashboardMetrics(appsWithAccess: 0, newSince7Days: 0, flaggedCount: 0, hintCount: 0, recentChanges: []))
    }
}
