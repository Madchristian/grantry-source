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
        let metrics = DashboardMetrics.compute(snapshot: snapshot, flagged: .empty, events: [], now: now)
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
        let metrics = DashboardMetrics.compute(snapshot: snapshot, flagged: .empty, events: events, now: now)
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
        let metrics = DashboardMetrics.compute(snapshot: snapshot, flagged: .empty, events: events, now: now)
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
            snapshot: TestData.snapshot(grants: [grant]), flagged: .empty, events: events, now: now
        )
        #expect(metrics.newSince7Days == 1)
    }

    @Test func addedThenRemovedRecordDoesNotCount() {
        let grant = TestData.grant()
        let events = [
            TestData.historyEvent(.added, .grant(grant), at: now.addingTimeInterval(-2 * day)),
            TestData.historyEvent(.removed, .grant(grant), at: now.addingTimeInterval(-1 * day)),
        ]
        let metrics = DashboardMetrics.compute(snapshot: TestData.snapshot(), flagged: .empty, events: events, now: now)
        #expect(metrics.newSince7Days == 0)
    }

    @Test func appsWithAccessExcludesAppleComponents() {
        let snapshot = TestData.snapshot(grants: [
            TestData.grant(client: TestData.app("com.apple.Terminal", signing: SigningInfo(kind: .apple))),
            TestData.grant(client: TestData.app("com.thirdparty")),
        ])
        let metrics = DashboardMetrics.compute(snapshot: snapshot, flagged: .empty, events: [], now: now)
        #expect(metrics.appsWithAccess == 1)
    }

    @Test(arguments: [
        ([:], "Keine Auffälligkeiten gefunden", "Keine Auffälligkeiten gefunden"),
        ([.apps: (2, 0)], "Einträge mit Prüfbedarf", "Einträge mit Prüfbedarf"),
        ([.apps: (2, 1)], "Einträge mit Prüfbedarf · 1 Hinweis", "Einträge mit Prüfbedarf, dazu 1 Hinweis mit niedrigem Risiko"),
        ([.permissions: (0, 3)], "Keine Auffälligkeiten · 3 Hinweise", "Keine Auffälligkeiten, dazu 3 Hinweise mit niedrigem Risiko"),
        // Mehrere Bereiche mit auffälligen Einträgen: die Unterzeile nennt ihre Zahl (#275).
        ([.apps: (3, 0), .agents: (2, 1), .network: (1, 0)], "In 3 Bereichen · 1 Hinweis",
         "Einträge mit Prüfbedarf in 3 Bereichen, dazu 1 Hinweis mit niedrigem Risiko"),
    ] as [([FlaggedArea: (Int, Int)], String, String)])
    func flaggedCaptionNamesAreasAndHintsSeparately(counts: [FlaggedArea: (Int, Int)], caption: String, spoken: String) {
        let metrics = Self.metrics(counts)
        #expect(metrics.flaggedCaption == caption)
        #expect(metrics.flaggedAccessibilityCaption == spoken)
        #expect(metrics.hasFindings == !counts.isEmpty)
    }

    /// Bedienhinweis der Kachel „Auffällig“: nennt den Bereich, den sie öffnet – auffällige Einträge vor Hinweisen, sonst
    /// die Berechtigungen – und verweist bei mehreren Bereichen auf den Hinweis über der Liste.
    @Test(arguments: [
        ([:], "Zeigt die Berechtigungen."),
        ([.apps: (2, 0)], "Zeigt die auffälligen Einträge in „Apps“."),
        ([.permissions: (0, 1), .apps: (2, 0)], "Zeigt die auffälligen Einträge in „Apps“."),
        ([.apps: (3, 0), .agents: (2, 0)],
         "Zeigt die auffälligen Einträge in „Apps“. Ein Hinweis über der Liste führt zu den übrigen Bereichen."),
        ([.autostart: (0, 3)], "Zeigt die Einträge mit Hinweisen in „Autostart“."),
        ([.autostart: (0, 3), .agents: (0, 1)],
         "Zeigt die Einträge mit Hinweisen in „Autostart“. Ein Hinweis über der Liste führt zu den übrigen Bereichen."),
    ] as [([FlaggedArea: (Int, Int)], String)])
    func flaggedHintMatchesWhatTheTileOpens(counts: [FlaggedArea: (Int, Int)], hint: String) {
        #expect(Self.metrics(counts).flaggedHint == hint)
    }

    /// Kennzahlen mit `(auffällig, Hinweise)` je Bereich.
    private static func metrics(_ counts: [FlaggedArea: (Int, Int)]) -> DashboardMetrics {
        let flagged = FlaggedBreakdown(counts.mapValues { FlaggedBreakdown.Counts(flagged: $0.0, hints: $0.1) })
        return DashboardMetrics(appsWithAccess: 0, newSince7Days: 0, flagged: flagged, recentChanges: [])
    }

    @Test func recentChangesAreTheFiveNewest() {
        let grant = TestData.grant()
        let events = (0..<7).map { offset in
            TestData.historyEvent(.modified, .grant(grant), at: now.addingTimeInterval(-Double(offset) * 60))
        }
        let metrics = DashboardMetrics.compute(
            snapshot: TestData.snapshot(), flagged: .empty, events: events.reversed(), now: now
        )
        #expect(metrics.recentChanges.map(\.id) == Array(events.prefix(DashboardMetrics.recentChangesLimit)).map(\.id))
        #expect(DashboardMetrics.recentChangesLimit == 5)
    }

    @Test func emptyInputsYieldZeroes() {
        let metrics = DashboardMetrics.compute(snapshot: TestData.snapshot(), flagged: .empty, events: [], now: now)
        #expect(metrics == DashboardMetrics(appsWithAccess: 0, newSince7Days: 0, flagged: .empty, recentChanges: []))
    }
}
