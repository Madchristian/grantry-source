import Foundation
import Testing
@testable import ManagerKit

@Suite struct AgentPresentationTests {
    @Test func groupsFollowCatalogOrderAndSortEntries() {
        let snapshot = TestData.agentSnapshot([
            TestData.mcpServer("z", toolID: "codex", toolName: "Codex"),
            TestData.mcpServer("b", scope: .project(path: "/p")),
            TestData.mcpServer("a"),
            TestData.mcpServer("sys", scope: .system),
        ], approvals: [TestData.autoApproval()])
        let groups = AgentPresenter.groups(snapshot: snapshot)
        #expect(groups.map(\.id) == ["claudeDesktop", "claudeCode", "codex"])
        #expect(groups[0].servers.map(\.name) == ["a", "b", "sys"])
        #expect(groups[1].servers.isEmpty)
        #expect(groups[1].approvals.count == 1)
    }

    @Test func starterAccessOfDesktopApp() {
        let claude = TestData.grant("kTCCServiceSystemPolicyAllFiles", client: TestData.app("com.anthropic.claudefordesktop"))
        let other = TestData.grant(client: TestData.app("us.zoom.xos"))
        let access = AgentPresenter.starterAccess(toolID: "claudeDesktop", grants: [claude, other])
        #expect(access.kind == .app)
        #expect(access.grants == [claude])
    }

    @Test func starterAccessOfTerminalTools() {
        let terminal = TestData.grant("kTCCServiceSystemPolicyAllFiles", client: TestData.app("com.apple.Terminal"))
        let camera = TestData.grant("kTCCServiceCamera", client: TestData.app("com.apple.Terminal"))
        let access = AgentPresenter.starterAccess(toolID: "codex", grants: [terminal, camera])
        #expect(access.kind == .terminal)
        #expect(access.grants == [terminal])
    }

    @Test func packageTexts() {
        #expect(AgentPresenter.packageText(.npm(package: "@x/fs", version: nil)) == "npm-Paket @x/fs – ohne festgelegte Version")
        #expect(AgentPresenter.packageText(.npm(package: "fs", version: "1.0.0")) == "npm-Paket fs@1.0.0")
        #expect(AgentPresenter.packageText(.pypi(package: "f", version: "1.0")) == "PyPI-Paket f==1.0")
        #expect(AgentPresenter.packageText(.container(image: "mcp/f", reference: nil)) == "Container-Image mcp/f – ohne festgelegte Version")
        #expect(AgentPresenter.packageText(.command(name: "uv")) == "Befehl „uv“ aus dem PATH")
        #expect(AgentPresenter.packageText(.remote(host: "h")) == "Entfernter Server h")
    }

    @Test func scopeTextNamesEveryScope() {
        #expect(AgentPresenter.scopeText(.user, home: "/Users/test") == "global (Benutzer)")
        #expect(AgentPresenter.scopeText(.project(path: "/Users/test/web"), home: "/Users/test") == "Projekt ~/web")
        #expect(AgentPresenter.scopeText(.system, home: "/Users/test") == "System (verwaltet)")
    }

    @Test func detailMarksSecretNamesAndDescribesScope() {
        let server = TestData.mcpServer(scope: .project(path: "/Users/test/web"), environmentKeys: ["MODE", "API_KEY"],
                                        headerKeys: ["Authorization"], isEnabled: false)
        let detail = MCPServerDetail(entry: server, findings: [], starter: AgentStarterAccess(kind: .terminal, grants: []),
                                     home: "/Users/test")
        #expect(detail.environment == [NamedKey(name: "MODE", isSecret: false), NamedKey(name: "API_KEY", isSecret: true)])
        #expect(detail.headers == [NamedKey(name: "Authorization", isSecret: true)])
        #expect(detail.scopeText == "Projekt ~/web")
        #expect(detail.enabledText == "deaktiviert")
        #expect(detail.kindText == "lokal")
        #expect(detail.commandLine == "npx -y pkg")
    }

    @Test func presentationSnapshotExposesAgents() {
        let server = TestData.mcpServer(packageSource: .npm(package: "p", version: nil))
        let snapshot = TestData.agentSnapshot([server])
        let findings = RiskEvaluator.standard.evaluate(snapshot)
        let presentation = PresentationSnapshot.make(snapshot: snapshot, findings: findings, events: [], recentAdditions: [],
                                                     now: TestData.date)
        #expect(presentation.agents.groups.map(\.id) == ["claudeDesktop"])
        #expect(presentation.highestSeverity(for: server.id) == .low)
        #expect(presentation.flaggedArea == .agents)
        #expect(presentation.agentDetail(for: server).packageText == "npm-Paket p – ohne festgelegte Version")
    }

    @Test func starterAccessIgnoresDeniedGrantsAndUnknownTools() {
        let denied = TestData.grant("kTCCServiceSystemPolicyAllFiles", client: TestData.app("com.anthropic.claudefordesktop"),
                                    authValue: .denied)
        #expect(AgentPresenter.starterAccess(toolID: "claudeDesktop", grants: [denied]).grants.isEmpty)
        #expect(AgentPresenter.starterAccess(toolID: "unbekannt", grants: [denied]) == AgentStarterAccess(kind: .unknown, grants: []))
    }

    @Test func unknownToolsFollowCatalogToolsByDisplayName() {
        let snapshot = TestData.agentSnapshot([
            TestData.mcpServer("x", toolID: "aaa", toolName: "Zeta 10"),
            TestData.mcpServer("y", toolID: "zzz", toolName: "Zeta 2"),
            TestData.mcpServer("z", toolID: "gemini", toolName: "Gemini CLI"),
        ], approvals: [TestData.autoApproval(toolID: "mmm", toolName: "alpha")])
        let groups = AgentPresenter.groups(snapshot: snapshot)
        #expect(groups.map(\.id) == ["gemini", "mmm", "zzz", "aaa"])
        #expect(groups.map(\.name) == ["Gemini CLI", "alpha", "Zeta 2", "Zeta 10"])
    }

    @Test func serversSortByScopeThenNaturalNameThenID() {
        let snapshot = TestData.agentSnapshot([
            TestData.mcpServer("server10"),
            TestData.mcpServer("Server2"),
            TestData.mcpServer("a", scope: .system),
            TestData.mcpServer("b", configPath: "/z.json", scope: .project(path: "/p")),
            TestData.mcpServer("b", configPath: "/a.json", scope: .project(path: "/p")),
        ])
        let servers = AgentPresenter.groups(snapshot: snapshot)[0].servers
        #expect(servers.map(\.name) == ["Server2", "server10", "b", "b", "a"])
        #expect(servers[2].configPath == "/a.json")
    }

    @Test func approvalsSortByScopeThenSettingThenID() {
        let snapshot = TestData.agentSnapshot([], approvals: [
            TestData.autoApproval(scope: .project(path: "/p"), setting: "a"),
            TestData.autoApproval(setting: "permissions.defaultMode"),
            TestData.autoApproval(configPath: "/z.json", setting: "enableAllProjectMcpServers"),
            TestData.autoApproval(configPath: "/a.json", setting: "enableAllProjectMcpServers"),
            TestData.autoApproval(scope: .system, setting: "0"),
        ])
        let approvals = AgentPresenter.groups(snapshot: snapshot)[0].approvals
        #expect(approvals.map(\.setting) == ["enableAllProjectMcpServers", "enableAllProjectMcpServers",
                                              "permissions.defaultMode", "a", "0"])
        #expect(approvals[0].configPath == "/a.json")
    }

    @Test func appStarterWithSeveralBundleIDs() {
        let catalog = AgentToolCatalog(tools: [
            AgentToolDefinition(id: "x", displayName: "X", starter: .app(bundleIDs: ["com.x.a", "com.x.b"]), files: []),
        ])
        let first = TestData.grant("kTCCServiceCamera", client: TestData.app("com.x.a"))
        let second = TestData.grant("kTCCServiceMicrophone", client: TestData.app("com.x.b"))
        let other = TestData.grant(client: TestData.app("com.y"))
        let access = AgentPresenter.starterAccess(toolID: "x", grants: [second, other, first], catalog: catalog)
        #expect(access == AgentStarterAccess(kind: .app, grants: [first, second]))
    }

    @Test func limitedTerminalGrantCounts() {
        let limited = TestData.grant("kTCCServiceSystemPolicyAllFiles", client: TestData.app("com.googlecode.iterm2"),
                                     authValue: .limited)
        #expect(AgentPresenter.starterAccess(toolID: "claudeCode", grants: [limited]).grants == [limited])
    }

    @Test func enabledTextOfDetailFollowsEntry() {
        let entry = TestData.mcpServer(isEnabled: nil, registryPath: "/Users/test/.claude.json")
        #expect(MCPServerDetail(entry: entry, findings: [], starter: .unknown).enabledText == "Freigabe ausstehend")
    }

    @Test func namedKeyIsIdentifiedByName() {
        #expect(NamedKey(name: "API_KEY", isSecret: true).id == "API_KEY")
    }

    @Test func morePackageTexts() {
        #expect(AgentPresenter.packageText(.container(image: "mcp/f", reference: "1.2")) == "Container-Image mcp/f (1.2)")
        #expect(AgentPresenter.packageText(.localProgram(path: "/Users/test/bin/x"), home: "/Users/test")
            == "Lokales Programm ~/bin/x")
    }

    @Test func detailOfRemoteSystemServer() {
        let server = TestData.mcpServer(scope: .system, transport: .remote(url: "https://h/mcp", kind: "http"),
                                        packageSource: .remote(host: "h"))
        let detail = MCPServerDetail(entry: server, findings: [], starter: AgentStarterAccess(kind: .app, grants: []),
                                     home: "/Users/test")
        #expect(detail.kindText == "entfernt (http)")
        #expect(detail.url == "https://h/mcp")
        #expect(detail.commandLine == nil)
        #expect(detail.scopeText == "System (verwaltet)")
        #expect(detail.enabledText == nil)
        #expect(detail.configPathText == "~/Library/Application Support/Claude/claude_desktop_config.json")
        #expect(MCPServerDetail(entry: TestData.mcpServer(transport: .remote(url: "https://h", kind: nil)), findings: [],
                                starter: AgentStarterAccess(kind: .app, grants: [])).kindText == "entfernt")
    }

    /// Agenten kommen in der Kachel „Auffällig“ nach den Apps; automatische Freigaben zählen mit.
    @Test func flaggedAreaAndSeverityIncludeApprovals() {
        let approval = TestData.autoApproval()
        let app = TestData.installedApp("Tool", bundleID: "com.example.tool")
        var snapshot = TestData.agentSnapshot([], approvals: [approval])
        snapshot.installedApps = [app]
        func make(_ findings: [RiskFinding]) -> PresentationSnapshot {
            .make(snapshot: snapshot, findings: findings, events: [], recentAdditions: [], now: TestData.date)
        }
        let agentFinding = RiskFinding(rule: .autoApproval, severity: .medium, recordID: approval.id, message: "")
        let appFinding = RiskFinding(rule: .unsignedApp, severity: .medium, recordID: app.id, message: "")
        #expect(make([agentFinding]).flaggedArea == .agents)
        #expect(make([agentFinding]).highestSeverity == .medium)
        #expect(make([agentFinding, appFinding]).flaggedArea == .apps)
    }

    @Test func agentCoverageCollectsErrorsAndLimitationsOfTheAgentSource() {
        var snapshot = TestData.agentSnapshot([], errors: [SourceError(source: .agents, message: "Datei kaputt"),
                                                          SourceError(source: .apps, message: "fremd")])
        snapshot.sourceLimitations = [SourceLimitation(source: .agents, message: "zu groß")]
        let presentation = PresentationSnapshot.make(snapshot: snapshot, findings: [], events: [], recentAdditions: [],
                                                     now: TestData.date)
        #expect(presentation.coverage[.agents]?.gaps.map(\.message) == ["Datei kaputt", "zu groß"])
    }

    @Test func detailCarriesStarterAccessOfTheTool() {
        let fullDisk = TestData.grant("kTCCServiceSystemPolicyAllFiles", client: TestData.app("com.anthropic.claudefordesktop"))
        let server = TestData.mcpServer()
        let presentation = PresentationSnapshot.make(snapshot: TestData.agentSnapshot([server], grants: [fullDisk]), findings: [],
                                                     events: [], recentAdditions: [], now: TestData.date)
        #expect(presentation.agentDetail(for: server).starter == AgentStarterAccess(kind: .app, grants: [fullDisk]))
    }

    @Test func lookupOfAgentRecordsAndStarterOfApprovalOnlyTools() {
        let server = TestData.mcpServer()
        let approval = TestData.autoApproval(toolID: "codex", toolName: "Codex")
        let terminal = TestData.grant("kTCCServiceSystemPolicyAllFiles", client: TestData.app("com.apple.Terminal"))
        let presentation = PresentationSnapshot.make(
            snapshot: TestData.agentSnapshot([server], approvals: [approval], grants: [terminal]), findings: [], events: [],
            recentAdditions: [], now: TestData.date
        )
        #expect(presentation.agentServer(id: server.id) == server)
        #expect(presentation.agentApproval(id: approval.id) == approval)
        #expect(presentation.agentServer(id: approval.id) == nil)
        #expect(presentation.agentApproval(id: "fehlt") == nil)
        let codexServer = TestData.mcpServer(toolID: "codex", toolName: "Codex")
        #expect(presentation.agentDetail(for: codexServer).starter == AgentStarterAccess(kind: .terminal, grants: [terminal]))
        #expect(presentation.agentDetail(for: TestData.mcpServer(toolID: "gemini")).starter == .unknown)
    }
}
