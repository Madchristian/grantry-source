import Foundation
import Testing
@testable import ManagerKit

@Suite struct InventoryPresenterTests {
    private let zoom = AppIdentity(
        bundleID: "us.zoom.xos", path: "/Applications/zoom.us.app", displayName: "Zoom",
        signing: SigningInfo(kind: .developerID, teamID: "T", isNotarized: true), presence: .present
    )
    private let docker = AppIdentity(
        bundleID: "com.docker.docker", path: "/Applications/Docker.app", displayName: "Docker",
        signing: SigningInfo(kind: .developerID, teamID: "D", isNotarized: true), presence: .present
    )
    private let alfred = AppIdentity(
        bundleID: "com.runningwithcrayons.Alfred", path: "/Applications/Alfred 5.app", displayName: "Alfred",
        signing: SigningInfo(kind: .developerID, teamID: "A", isNotarized: true), presence: .present
    )

    private func finding(_ recordID: String, _ severity: RiskFinding.Severity) -> RiskFinding {
        RiskFinding(rule: .orphan, severity: severity, recordID: recordID, message: "")
    }

    // MARK: - Nach App

    @Test func groupsGrantsAndOwnedItemsByApp() {
        let camera = TestData.grant("kTCCServiceCamera", client: zoom)
        let mic = TestData.grant("kTCCServiceMicrophone", client: zoom)
        let helper = TestData.item("com.docker.helper", kind: .launchDaemon, owner: docker)
        let orphanItem = TestData.item("com.nobody")
        let groups = InventoryPresenter.appGroups(
            snapshot: TestData.snapshot(grants: [mic, camera], items: [helper, orphanItem]), findings: []
        )
        #expect(groups.map(\.app.displayName) == ["Docker", "Zoom"])
        #expect(groups[0].grants.isEmpty)
        #expect(groups[0].autostartItems == [helper])
        // Innerhalb der Gruppe nach Dienstname: „Kamera“ vor „Mikrofon“.
        #expect(groups[1].grants == [camera, mic])
        #expect(groups[1].autostartItems.isEmpty)
        #expect(groups.allSatisfy { !$0.isFlagged })
    }

    @Test func flaggedAppsComeFirstByHighestSeverity() {
        let zoomGrant = TestData.grant(client: zoom)
        let alfredGrant = TestData.grant(client: alfred)
        let dockerGrant = TestData.grant(client: docker)
        let findings = [finding(zoomGrant.id, .low), finding(dockerGrant.id, .high), finding(dockerGrant.id, .low)]
        let groups = InventoryPresenter.appGroups(
            snapshot: TestData.snapshot(grants: [zoomGrant, alfredGrant, dockerGrant]), findings: findings
        )
        #expect(groups.map(\.app.displayName) == ["Docker", "Zoom", "Alfred"])
        #expect(groups.map(\.highestSeverity) == [.high, .low, nil])
        #expect(groups[0].severity(of: dockerGrant.id) == .high)
    }

    @Test func appIdentityGroupsAcrossScopes() {
        let user = TestData.grant(client: zoom, scope: .user)
        let system = TestData.grant(client: zoom, scope: .system)
        let groups = InventoryPresenter.appGroups(snapshot: TestData.snapshot(grants: [system, user]), findings: [])
        #expect(groups.count == 1)
        #expect(groups[0].id == "us.zoom.xos")
        #expect(groups[0].grants.count == 2)
    }

    // MARK: - Nach Berechtigung

    @Test func groupsGrantsByService() {
        let zoomCamera = TestData.grant("kTCCServiceCamera", client: zoom)
        let alfredCamera = TestData.grant("kTCCServiceCamera", client: alfred)
        let fda = TestData.grant("kTCCServiceSystemPolicyAllFiles", client: docker)
        let groups = InventoryPresenter.serviceGroups(
            snapshot: TestData.snapshot(grants: [zoomCamera, fda, alfredCamera]), findings: []
        )
        #expect(groups.map(\.service.displayName) == ["Festplattenvollzugriff", "Kamera"])
        #expect(groups.map(\.id) == ["kTCCServiceSystemPolicyAllFiles", "kTCCServiceCamera"])
        #expect(groups[1].grants == [alfredCamera, zoomCamera])
    }

    @Test func flaggedServicesComeFirst() {
        let camera = TestData.grant("kTCCServiceCamera", client: zoom)
        let mic = TestData.grant("kTCCServiceMicrophone", client: zoom)
        let groups = InventoryPresenter.serviceGroups(
            snapshot: TestData.snapshot(grants: [camera, mic]), findings: [finding(mic.id, .medium)]
        )
        #expect(groups.map(\.service.id) == ["kTCCServiceMicrophone", "kTCCServiceCamera"])
        #expect(groups[0].highestSeverity == .medium)
    }

    // MARK: - Autostart

    @Test func sectionsFollowKindOrderWithGermanTitles() {
        let daemon = TestData.item("b.daemon", kind: .launchDaemon, domain: .system)
        let agentB = TestData.item("b.agent")
        let agentA = TestData.item("a.agent")
        let login = TestData.item("Login", kind: .loginItem, source: .btm)
        let sections = InventoryPresenter.autostartSections(
            snapshot: TestData.snapshot(items: [daemon, agentB, login, agentA]), findings: [finding(agentB.id, .high)]
        )
        #expect(sections.map(\.kind) == [.loginItem, .launchAgent, .launchDaemon])
        #expect(sections.map(\.title) == ["Anmeldeobjekte", "LaunchAgents", "LaunchDaemons"])
        #expect(sections[1].items == [agentB, agentA])
        #expect(sections[1].highestSeverity == .high)
        #expect(AutostartKind.backgroundTask.sectionTitle == "Hintergrundobjekte")
    }

    // MARK: - Filter

    @Test func queryMatchesAppNameBundleIDServiceAndLabelIgnoringCaseAndDiacritics() {
        let camera = TestData.grant("kTCCServiceCamera", client: zoom)
        let fda = TestData.grant("kTCCServiceSystemPolicyAllFiles", client: alfred)
        let helper = TestData.item("com.docker.vmnetd", kind: .launchDaemon, owner: docker)
        let groups = InventoryPresenter.appGroups(
            snapshot: TestData.snapshot(grants: [camera, fda], items: [helper]), findings: []
        )
        #expect(InventoryPresenter.filter(groups, query: "zoom").map(\.id) == ["us.zoom.xos"])
        #expect(InventoryPresenter.filter(groups, query: "RUNNINGWITH").map(\.id) == ["com.runningwithcrayons.Alfred"])
        #expect(InventoryPresenter.filter(groups, query: "festplattenvollzugriff").map(\.id) == ["com.runningwithcrayons.Alfred"])
        #expect(InventoryPresenter.filter(groups, query: "Kamera").map(\.id) == ["us.zoom.xos"])
        #expect(InventoryPresenter.filter(groups, query: "vmnetd").map(\.id) == ["com.docker.docker"])
        #expect(InventoryPresenter.filter(groups, query: "  ").count == 3)
        #expect(InventoryPresenter.filter(groups, query: "xyz").isEmpty)
    }

    @Test func queryKeepsOnlyMatchingRecordsOfAGroup() {
        let camera = TestData.grant("kTCCServiceCamera", client: zoom)
        let mic = TestData.grant("kTCCServiceMicrophone", client: zoom)
        let groups = InventoryPresenter.appGroups(snapshot: TestData.snapshot(grants: [camera, mic]), findings: [])
        #expect(InventoryPresenter.filter(groups, query: "mikro").first?.grants == [mic])
        #expect(InventoryPresenter.filter(groups, query: "Zoom").first?.grants == [camera, mic])
    }

    @Test func stateFilterSeparatesAllowedAndDenied() {
        let allowed = TestData.grant("kTCCServiceCamera", client: zoom)
        let limited = TestData.grant("kTCCServicePhotos", client: zoom, authValue: .limited)
        let denied = TestData.grant("kTCCServiceMicrophone", client: zoom, authValue: .denied)
        let groups = InventoryPresenter.serviceGroups(
            snapshot: TestData.snapshot(grants: [allowed, limited, denied]), findings: []
        )
        let allowedIDs = InventoryPresenter.filter(groups, state: .allowed).flatMap(\.grants).map(\.id)
        #expect(Set(allowedIDs) == [allowed.id, limited.id])
        #expect(InventoryPresenter.filter(groups, state: .denied).flatMap(\.grants) == [denied])
    }

    @Test func stateFilterTreatsEnabledAutostartItemsAsAllowed() {
        let enabled = TestData.item("on")
        let disabled = TestData.item("off", isEnabled: false)
        let sections = InventoryPresenter.autostartSections(
            snapshot: TestData.snapshot(items: [enabled, disabled]), findings: []
        )
        #expect(InventoryPresenter.filter(sections, state: .allowed).flatMap(\.items) == [enabled])
        #expect(InventoryPresenter.filter(sections, state: .denied).flatMap(\.items) == [disabled])
    }

    @Test func scopeFilterUsesTCCScopeAndAutostartDomain() {
        let user = TestData.grant(client: zoom, scope: .user)
        let system = TestData.grant(client: zoom, scope: .system)
        let daemon = TestData.item("d", kind: .launchDaemon, domain: .system, owner: zoom)
        let groups = InventoryPresenter.appGroups(
            snapshot: TestData.snapshot(grants: [user, system], items: [daemon]), findings: []
        )
        let systemOnly = InventoryPresenter.filter(groups, scope: .system)
        #expect(systemOnly.first?.grants == [system])
        #expect(systemOnly.first?.autostartItems == [daemon])
        let userOnly = InventoryPresenter.filter(groups, scope: .user)
        #expect(userOnly.first?.grants == [user])
        #expect(userOnly.first?.autostartItems.isEmpty == true)
    }

    @Test func onlyFlaggedKeepsFlaggedRecordsAndResorts() {
        let zoomCamera = TestData.grant("kTCCServiceCamera", client: zoom)
        let zoomMic = TestData.grant("kTCCServiceMicrophone", client: zoom)
        let alfredCamera = TestData.grant("kTCCServiceCamera", client: alfred)
        let groups = InventoryPresenter.appGroups(
            snapshot: TestData.snapshot(grants: [zoomCamera, zoomMic, alfredCamera]),
            findings: [finding(zoomMic.id, .low)]
        )
        let flagged = InventoryPresenter.filter(groups, onlyFlagged: true)
        #expect(flagged.map(\.id) == ["us.zoom.xos"])
        #expect(flagged[0].grants == [zoomMic])
        #expect(flagged[0].highestSeverity == .low)
    }

    @Test func filteringRecomputesHighestSeverity() {
        let camera = TestData.grant("kTCCServiceCamera", client: zoom)
        let mic = TestData.grant("kTCCServiceMicrophone", client: zoom)
        let groups = InventoryPresenter.appGroups(
            snapshot: TestData.snapshot(grants: [camera, mic]), findings: [finding(mic.id, .high)]
        )
        let cameraOnly = InventoryPresenter.filter(groups, query: "Kamera")
        #expect(cameraOnly.first?.highestSeverity == nil)
    }

    @Test func filterTitlesAreGerman() {
        #expect(GrantStateFilter.allCases.map { $0.title(for: .permissions) } == ["Alle", "Erlaubt", "Verweigert"])
        #expect(GrantStateFilter.allCases.map { $0.title(for: .autostart) } == ["Alle", "Aktiviert", "Deaktiviert"])
        #expect(ScopeFilter.allCases.map(\.title) == ["Alle", "Benutzer", "System"])
    }

    @Test func presentationSnapshotBundlesAllViews() {
        let now = TestData.date
        let camera = TestData.grant("kTCCServiceCamera", client: zoom)
        let removedApp = TestData.app("com.gone", presence: .missing)
        let denied = TestData.grant(client: removedApp, authValue: .denied)
        let item = TestData.item("a.agent", owner: zoom)
        let snapshot = TestData.snapshot(grants: [camera, denied], items: [item])
        let findings = [finding(camera.id, .low)]
        let recent = TestData.historyEvent(.modified, .grant(camera), at: now)
        let addition = TestData.historyEvent(.added, .autostartItem(item), at: now.addingTimeInterval(-3 * 24 * 3600))

        let presentation = PresentationSnapshot.make(
            snapshot: snapshot, findings: findings, events: [recent], recentAdditions: [addition, recent], now: now
        )

        #expect(presentation.appGroups == InventoryPresenter.appGroups(snapshot: snapshot, findings: findings))
        #expect(presentation.serviceGroups == InventoryPresenter.serviceGroups(snapshot: snapshot, findings: findings))
        #expect(presentation.autostartSections == InventoryPresenter.autostartSections(snapshot: snapshot, findings: findings))
        #expect(presentation.cleanupHints == CleanupHints.evaluate(snapshot))
        #expect(presentation.badges.badges(for: item.id) == [.new])
        #expect(presentation.badges.badges(for: camera.id) == [.review(.low)])
        #expect(presentation.badges.badges(for: denied.id) == [.cleanup])
        #expect(presentation.metrics.newSince7Days == 1)
        // Der einzige Befund ist niedrig: ein Hinweis, nicht „auffällig“.
        #expect(presentation.metrics.flaggedCount == 0)
        #expect(presentation.metrics.hintCount == 1)
        // Doppelte Events (in `events` und `recentAdditions`) zählen einmal.
        #expect(presentation.metrics.recentChanges.map(\.id) == [recent.id, addition.id])
    }

    @Test func presentationSnapshotSummarizesFindings() {
        let camera = TestData.grant("kTCCServiceCamera", client: zoom)
        let item = TestData.item("a.agent")
        let snapshot = TestData.snapshot(grants: [camera], items: [item])
        func make(_ findings: [RiskFinding]) -> PresentationSnapshot {
            .make(snapshot: snapshot, findings: findings, events: [], recentAdditions: [], now: TestData.date)
        }

        #expect(make([]).highestSeverity == nil)
        #expect(make([finding(item.id, .high)]).highestSeverity == .high)
        #expect(make([finding(item.id, .low), finding(camera.id, .medium)]).highestSeverity == .medium)
    }

    /// Die Kachel „Auffällig“ öffnet den Bereich mit auffälligen Einträgen (mittel/hoch) – Berechtigungen zuerst; ein
    /// bloßer Hinweis bei den Berechtigungen lenkt nicht von einem auffälligen Autostart-Eintrag ab. Nur ohne
    /// auffällige Einträge zählen die Hinweise, ohne Befunde öffnet sie die Berechtigungen. Apps kommen nach Autostart.
    @Test(arguments: [
        ([], FlaggedArea.permissions),
        ([("item", RiskFinding.Severity.high)], .autostart),
        ([("item", .medium), ("camera", .low)], .autostart),
        ([("item", .low), ("camera", .medium)], .permissions),
        ([("item", .high), ("camera", .medium)], .permissions),
        ([("item", .low)], .autostart),
        ([("item", .low), ("camera", .low)], .permissions),
        ([("app", .high)], .apps),
        ([("app", .medium), ("item", .low)], .apps),
        ([("app", .low)], .apps),
        ([("app", .high), ("item", .medium)], .autostart),
        ([("app", .low), ("camera", .low)], .permissions),
    ] as [([(String, RiskFinding.Severity)], FlaggedArea)])
    func flaggedTileOpensTheAreaWithTheRelevantFindings(_ findings: [(String, RiskFinding.Severity)], area: FlaggedArea) {
        let camera = TestData.grant("kTCCServiceCamera", client: zoom)
        let item = TestData.item("a.agent")
        let app = TestData.installedApp("Tool", bundleID: "com.example.tool")
        let ids = ["camera": camera.id, "item": item.id, "app": app.id]
        let presentation = PresentationSnapshot.make(
            snapshot: TestData.appSnapshot([app], grants: [camera], items: [item]),
            findings: findings.map { finding(ids[$0.0]!, $0.1) }, events: [], recentAdditions: [], now: TestData.date
        )
        #expect(presentation.flaggedArea == area)
    }

    @Test func presentationSnapshotIndexesFindingsAndCleanupHints() {
        let camera = TestData.grant("kTCCServiceCamera", client: zoom)
        let denied = TestData.grant(client: TestData.app("com.gone", presence: .missing), authValue: .denied)
        let snapshot = TestData.snapshot(grants: [camera, denied])
        let low = finding(camera.id, .low)
        let high = RiskFinding(rule: .unsignedClient, severity: .high, recordID: camera.id, message: "hoch")
        let presentation = PresentationSnapshot.make(
            snapshot: snapshot, findings: [low, high], events: [], recentAdditions: [], now: TestData.date
        )

        #expect(presentation.findings(for: camera.id) == [high, low])
        #expect(presentation.findings(for: denied.id).isEmpty)
        #expect(presentation.cleanupHint(for: denied.id) == CleanupHints.evaluate(snapshot).first)
        #expect(presentation.cleanupHint(for: camera.id) == nil)
    }

    @Test func filteringKeepsRecordOrder() {
        let grants = (1...12).map { TestData.grant("kTCCServiceCamera", client: TestData.app("com.app\($0)")) }
        let groups = InventoryPresenter.serviceGroups(snapshot: TestData.snapshot(grants: grants), findings: [])
        let filtered = InventoryPresenter.filter(groups, query: "com.app")
        #expect(filtered.first?.grants.map(\.client.displayName) == groups.first?.grants.map(\.client.displayName))
        let names = groups.first?.grants.map(\.client.displayName) ?? []
        #expect(Array(names.prefix(3)) == ["com.app1", "com.app2", "com.app3"])
    }
}
