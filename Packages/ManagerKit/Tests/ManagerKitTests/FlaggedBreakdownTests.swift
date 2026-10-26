import Foundation
import Testing
@testable import ManagerKit

/// Kachel „Auffällig“ und Befund-Filter der Listen (#275): eine Aufschlüsselung je Bereich, deren Summe die Kachel zeigt,
/// und dieselbe Schwelle in Kachel und Filter.
@Suite struct FlaggedBreakdownTests {
    private let camera = TestData.grant("kTCCServiceCamera")
    private let microphone = TestData.grant("kTCCServiceMicrophone")
    private let item = TestData.item("com.example.agent")
    private let unsigned = TestData.installedApp("Unsigniert", bundleID: "com.example.unsigned")
    private let intel = TestData.installedApp("Intel", bundleID: "com.example.intel")
    private let changed = TestData.installedApp("Geändert", bundleID: "com.example.changed")
    private let server = TestData.mcpServer()
    private let approval = TestData.autoApproval()
    private let exposed = TestData.listener()
    private let loopback = TestData.listener("/opt/homebrew/bin/redis-server", port: 6379, addresses: ["127.0.0.1"])

    private var snapshot: Snapshot {
        var snapshot = TestData.appSnapshot([unsigned, intel, changed], grants: [camera, microphone], items: [item])
        snapshot.mcpServers = [server]
        snapshot.agentAutoApprovals = [approval]
        snapshot.networkListeners = [exposed, loopback]
        return snapshot
    }

    /// Auffällige Einträge in allen fünf Bereichen, dazu Hinweise in dreien.
    private var findings: [RiskFinding] {
        [
            finding(camera.id, .medium), finding(microphone.id, .low),
            finding(item.id, .high), finding(item.id, .low),
            finding(unsigned.id, .medium), finding(changed.id, .high), finding(intel.id, .low),
            finding(server.id, .medium), finding(approval.id, .low),
            finding(exposed.id, .medium),
        ]
    }

    private func finding(_ recordID: String, _ severity: RiskFinding.Severity) -> RiskFinding {
        RiskFinding(rule: .orphan, severity: severity, recordID: recordID, message: "")
    }

    private func make(_ findings: [RiskFinding]) -> PresentationSnapshot {
        .make(snapshot: snapshot, findings: findings, events: [], recentAdditions: [], now: TestData.date)
    }

    // MARK: - Aufschlüsselung

    @Test func sumOverAreasEqualsTheTileCounts() {
        let metrics = make(findings).metrics
        let breakdown = metrics.flagged
        let expected: [FlaggedArea: (flagged: Int, hints: Int)] = [
            .permissions: (1, 1), .autostart: (1, 0), .apps: (2, 1), .agents: (1, 1), .network: (1, 0),
        ]
        for (area, counts) in expected {
            #expect(breakdown.count(in: area, for: .flagged) == counts.flagged, "\(area)")
            #expect(breakdown.count(in: area, for: .withFindings) == counts.flagged + counts.hints, "\(area)")
        }
        #expect(metrics.flaggedCount == 6)
        #expect(metrics.hintCount == 3)
        #expect(FlaggedArea.allCases.map { breakdown.count(in: $0, for: .flagged) }.reduce(0, +) == metrics.flaggedCount)
        #expect(FlaggedArea.allCases.map { breakdown.count(in: $0, for: .withFindings) }.reduce(0, +)
            == metrics.flaggedCount + metrics.hintCount)
        #expect(breakdown.areas(for: .flagged) == FlaggedArea.allCases)
        #expect(breakdown.areas(for: .withFindings) == FlaggedArea.allCases)
    }

    /// Befunde zu Einträgen, die keine Liste zeigt – ein entfernter Eintrag oder ein nur lokal erreichbarer Lauscher, den
    /// „Von außen erreichbar“ ausblendet –, wären über die Kachel nicht erreichbar und zählen deshalb nicht.
    @Test func findingsWithoutVisibleRecordDoNotCount() {
        let invisible = [finding("/Applications/Entfernt.app", .high), finding(loopback.id, .medium), finding("weg", .low)]
        let metrics = make(findings + invisible).metrics
        #expect(metrics.flaggedCount == 6)
        #expect(metrics.hintCount == 3)
        #expect(make(invisible).metrics.flagged == .empty)
        #expect(!make(invisible).metrics.hasFindings)
        #expect(make(invisible).flaggedArea == .permissions)
    }

    @Test func tileOpensFlaggedEntriesBeforeHints() {
        let all = make(findings).metrics.flagged
        #expect(all.tileFilter == .flagged)
        #expect(all.tileArea == .permissions)
        let agentsAndNetwork = make([finding(server.id, .medium), finding(exposed.id, .high), finding(camera.id, .low)])
        #expect(agentsAndNetwork.metrics.flagged.tileFilter == .flagged)
        #expect(agentsAndNetwork.flaggedArea == .agents)
        let hintsOnly = make([finding(intel.id, .low), finding(approval.id, .low)])
        #expect(hintsOnly.metrics.flagged.tileFilter == .withFindings)
        #expect(hintsOnly.flaggedArea == .apps)
        #expect(make([]).metrics.flagged.tileFilter == .all)
        #expect(make([]).flaggedArea == .permissions)
    }

    // MARK: - Hinweis über der Liste

    @Test func noticeNamesTheOtherAreasWithTheSameThreshold() throws {
        let breakdown = make(findings).metrics.flagged
        let notice = try #require(breakdown.notice(in: .apps, filter: .flagged))
        #expect(notice.shown == 2)
        #expect(notice.total == 6)
        #expect(notice.others.map(\.area) == [.permissions, .autostart, .agents, .network])
        #expect(notice.others.map(\.label) == ["Berechtigungen (1)", "Autostart (1)", "Agenten (1)", "Netzwerk (1)"])
        #expect(notice.headline == "2 von 6 auffälligen Einträgen. Weitere:")
        #expect(notice.accessibilityLabel == "2 von 6 auffälligen Einträgen stehen hier, weitere in Berechtigungen (1), "
            + "Autostart (1), Agenten (1) und Netzwerk (1).")
        #expect(notice.others.first?.accessibilityLabel == "Berechtigungen: 1 Eintrag anzeigen")
        #expect(breakdown.notice(in: .apps, filter: .withFindings)?.headline == "3 von 9 Einträgen mit Befund. Weitere:")
    }

    @Test func noticeOnlyWithFilterAndFurtherAreas() {
        let breakdown = make(findings).metrics.flagged
        #expect(breakdown.notice(in: .apps, filter: .all) == nil)
        let appsOnly = make([finding(unsigned.id, .medium), finding(intel.id, .low)]).metrics.flagged
        #expect(appsOnly.notice(in: .apps, filter: .flagged) == nil)
        #expect(appsOnly.notice(in: .apps, filter: .withFindings) == nil)
        // Aus einem Bereich ohne solche Einträge führt der Hinweis zum einzigen mit.
        let single = appsOnly.notice(in: .agents, filter: .flagged)
        #expect(single?.headline == "0 von 1 auffälligem Eintrag. Weitere:")
        #expect(single?.accessibilityLabel == "0 von 1 auffälligem Eintrag stehen hier, weitere in Apps (1).")
    }

    // MARK: - Schwelle der Filter

    @Test(arguments: [
        (FindingFilter.all, RiskFinding.Severity?.none, true), (.all, .low, true),
        (.flagged, nil, false), (.flagged, .low, false), (.flagged, .medium, true), (.flagged, .high, true),
        (.withFindings, nil, false), (.withFindings, .low, true), (.withFindings, .high, true),
    ])
    func findingFilterUsesTheTileThreshold(filter: FindingFilter, severity: RiskFinding.Severity?, included: Bool) {
        #expect(filter.includes(severity) == included)
    }

    /// „Nur auffällige“ blendet reine Hinweise aus – wie die Kachel; „Auffällige und Hinweise“ nicht.
    @Test func inventoryFilterHidesHintsOnlyAtTheFlaggedThreshold() {
        let presentation = make(findings)
        let flagged = InventoryPresenter.filter(presentation.serviceGroups, findings: .flagged)
        #expect(flagged.flatMap(\.grants) == [camera])
        let withFindings = InventoryPresenter.filter(presentation.serviceGroups, findings: .withFindings)
        #expect(Set(withFindings.flatMap(\.grants)) == [camera, microphone])
        let sections = InventoryPresenter.filter(presentation.autostartSections, findings: .flagged)
        #expect(sections.flatMap(\.items) == [item])
        let appGroups = InventoryPresenter.filter(presentation.appGroups, findings: .flagged)
        #expect(appGroups.flatMap(\.grants) == [camera])
    }

    @Test func appFilterHidesHintsOnlyAtTheFlaggedThreshold() {
        let presentation = make(findings)
        func names(_ findings: FindingFilter) -> [String] {
            AppInventoryPresenter.rows(
                presentation.installedApps, details: [:], severity: presentation.highestSeverity(for:), query: "",
                filter: AppListFilter(findings: findings), now: TestData.date
            ).map(\.app.name)
        }
        #expect(names(.flagged) == ["Geändert", "Unsigniert"])
        #expect(names(.withFindings) == ["Geändert", "Intel", "Unsigniert"])
        #expect(names(.all) == ["Geändert", "Intel", "Unsigniert"])
        // Die Liste zeigt genau, was die Aufschlüsselung für „Apps“ zählt.
        #expect(names(.flagged).count == presentation.metrics.flagged.count(in: .apps, for: .flagged))
    }
}
