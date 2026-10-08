import Foundation
import Testing
@testable import ManagerKit

@Suite struct PresentationSnapshotAppsTests {
    private let zoom = TestData.installedApp("Zoom", bundleID: "us.zoom.xos")
    private let alfred = TestData.installedApp("alfred 5", bundleID: "com.runningwithcrayons.Alfred")

    private func make(_ snapshot: Snapshot, findings: [RiskFinding] = []) -> PresentationSnapshot {
        PresentationSnapshot.make(snapshot: snapshot, findings: findings, events: [], recentAdditions: [], now: TestData.date)
    }

    @Test func listsAppsByNameWithLinksAndSeverity() {
        let grant = TestData.grant(client: zoom.identity)
        let item = TestData.item(owner: zoom.identity)
        let other = TestData.grant(client: TestData.app("com.other"))
        let low = RiskFinding(rule: .intelOnly, severity: .low, recordID: zoom.id, message: "x")
        let high = RiskFinding(rule: .teamIDChanged, severity: .high, recordID: zoom.id, message: "y")
        let presentation = make(TestData.appSnapshot([zoom, alfred], grants: [grant, other], items: [item]),
                                findings: [low, high])
        #expect(presentation.installedApps == [alfred, zoom])
        #expect(presentation.links(for: zoom) == AppLinks(grants: [grant], autostartItems: [item]))
        #expect(presentation.links(for: alfred) == AppLinks(grants: [], autostartItems: []))
        #expect(presentation.highestSeverity(for: zoom.id) == .high)
        #expect(presentation.highestSeverity(for: alfred.id) == nil)
        #expect(presentation.highestSeverity == .high)
    }

    @Test func linksIndexMatchesBundleIDOrPathLikeAppLinks() {
        let byPath = AppIdentity(bundleID: nil, path: zoom.path, displayName: "Zoom", signing: .unknown, presence: .present)
        let grants = [TestData.grant("kTCCServiceCamera", client: zoom.identity), TestData.grant("kTCCServiceMicrophone", client: byPath),
                      TestData.grant(client: alfred.identity)]
        let items = [TestData.item("b", owner: byPath), TestData.item("a", owner: zoom.identity), TestData.item("c")]
        let snapshot = TestData.appSnapshot([zoom, alfred], grants: grants, items: items)
        let presentation = make(snapshot)
        for app in [zoom, alfred] {
            #expect(presentation.links(for: app) == AppLinks.of(app, in: snapshot))
        }
    }

    @Test func detailUsesFindingsAndLinksOfTheApp() {
        let grant = TestData.grant(client: zoom.identity)
        let finding = RiskFinding(rule: .intelOnly, severity: .low, recordID: zoom.id, message: "x")
        let presentation = make(TestData.appSnapshot([zoom], grants: [grant]), findings: [finding])
        let detail = presentation.detail(for: zoom, details: nil, now: TestData.date)
        #expect(detail.findings == [finding])
        #expect(detail.grants == [grant])
    }

    @Test func appCoverageCollectsErrorsAndLimitationsOfTheAppSource() {
        var snapshot = TestData.appSnapshot([zoom], errors: [SourceError(source: .apps, message: "Ordner fehlt"),
                                                             SourceError(source: .launchd, message: "anders")])
        snapshot.sourceLimitations = [SourceLimitation(source: .apps, message: "2 Signaturen nicht geprüft"),
                                      SourceLimitation(source: .btm, message: "anders")]
        #expect(make(snapshot).coverage[.apps]?.gaps.map(\.message) == ["Ordner fehlt", "2 Signaturen nicht geprüft"])
    }

    @Test func newAppsCountAsRecentlyAdded() {
        let added = TestData.historyEvent(.added, .installedApp(zoom), at: TestData.date - TestData.day)
        let gone = TestData.historyEvent(.added, .installedApp(alfred), at: TestData.date - TestData.day)
        let metrics = DashboardMetrics.compute(snapshot: TestData.appSnapshot([zoom]), findings: [], events: [added, gone],
                                               now: TestData.date)
        #expect(metrics.newSince7Days == 1)
    }

    @Test func appFindingsCountAsFlagged() {
        let finding = RiskFinding(rule: .teamIDChanged, severity: .high, recordID: zoom.id, message: "x")
        let presentation = make(TestData.appSnapshot([zoom]), findings: [finding])
        #expect(presentation.metrics.flaggedCount == 1)
        #expect(presentation.flaggedArea == .apps)
    }
}
