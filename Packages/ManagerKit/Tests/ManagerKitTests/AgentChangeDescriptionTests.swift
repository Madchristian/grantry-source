import Foundation
import Testing
@testable import ManagerKit

@Suite struct AgentChangeDescriptionTests {
    private func event(_ kind: ChangeEvent.Kind, _ before: ChangeSubject?, _ after: ChangeSubject?) -> ChangeEvent {
        ChangeEvent(kind: kind, before: before, after: after, detectedAt: TestData.date)
    }

    @Test func addedServer() {
        let server = TestData.mcpServer(transport: .local(command: "npx", arguments: ["@modelcontextprotocol/server-filesystem", "~/"]))
        let description = ChangeDescription(event(.added, nil, .mcpServer(server)))
        #expect(description.title == "Neuer MCP-Server")
        #expect(description.body == "„filesystem“ in Claude Desktop: npx @modelcontextprotocol/server-filesystem '~/'")
    }

    @Test func modifiedServerShowsBeforeAndAfter() {
        let before = TestData.mcpServer(isEnabled: true)
        let after = TestData.mcpServer(transport: .local(command: "npx", arguments: ["pkg@2.0.0"]), isEnabled: false)
        let description = ChangeDescription(event(.modified, .mcpServer(before), .mcpServer(after)))
        #expect(description.title == "MCP-Server geändert")
        #expect(description.body == "„filesystem“ in Claude Desktop: npx -y pkg → npx pkg@2.0.0, deaktiviert")
    }

    /// Projekt-Server in `~/.claude.json` (kein `registryPath`): `nil` heißt „kein Schalter“, gilt also als aktiv.
    @Test(arguments: [
        (Bool?.some(false), Bool?.some(true), "aktiviert"),
        (true, false, "deaktiviert"),
        (nil, false, "deaktiviert"),
        (false, nil, "aktiviert"),
        (nil, true, "geändert"),
        (true, nil, "geändert"),
    ])
    func modifiedServerDescribesSwitch(before: Bool?, after: Bool?, expected: String) {
        let server = { (isEnabled: Bool?) in
            TestData.mcpServer(toolName: "Claude Code", configPath: "/Users/test/.claude.json",
                               scope: .project(path: "/Users/test/web"), isEnabled: isEnabled)
        }
        let description = ChangeDescription(event(.modified, .mcpServer(server(before)), .mcpServer(server(after))))
        #expect(description.body == "„filesystem“ in Claude Code (Projekt web): \(expected)")
    }

    /// Server aus einer Projektdatei `.mcp.json` (mit `registryPath`): `nil` heißt „Freigabe ausstehend“.
    @Test(arguments: [
        (Bool?.some(false), Bool?.some(true), "aktiviert"),
        (true, false, "deaktiviert"),
        (nil, true, "freigegeben"),
        (nil, false, "abgelehnt"),
        (true, nil, "Freigabe ausstehend"),
        (false, nil, "Freigabe ausstehend"),
    ])
    func modifiedProjectFileServerDescribesApproval(before: Bool?, after: Bool?, expected: String) {
        let server = { (isEnabled: Bool?) in
            TestData.mcpServer(toolName: "Claude Code", configPath: "/Users/test/web/.mcp.json",
                               scope: .project(path: "/Users/test/web"), isEnabled: isEnabled,
                               registryPath: "/Users/test/.claude.json")
        }
        let description = ChangeDescription(event(.modified, .mcpServer(server(before)), .mcpServer(server(after))))
        #expect(description.body == "„filesystem“ in Claude Code (Projekt web): \(expected)")
    }

    @Test func transportChangeWithEqualSummary() {
        let sse = TestData.mcpServer(transport: .remote(url: "https://x.example/mcp", kind: "sse"))
        let http = TestData.mcpServer(transport: .remote(url: "https://x.example/mcp", kind: "http"))
        #expect(ChangeDescription(event(.modified, .mcpServer(sse), .mcpServer(http))).body
            == "„filesystem“ in Claude Desktop: Verbindungsart sse → http")
        let long = String(repeating: "a", count: MCPServerEntry.summaryLength)
        let before = TestData.mcpServer(transport: .local(command: "npx", arguments: [long + "1"]))
        let after = TestData.mcpServer(transport: .local(command: "npx", arguments: [long + "2"]))
        #expect(ChangeDescription(event(.modified, .mcpServer(before), .mcpServer(after))).body
            == "„filesystem“ in Claude Desktop: Befehl geändert")
    }

    @Test func modifiedServerWithoutPreviousShowsSummary() {
        let description = ChangeDescription(event(.modified, nil, .mcpServer(TestData.mcpServer())))
        #expect(description.body == "„filesystem“ in Claude Desktop: npx -y pkg")
    }

    @Test func removedServerInProject() {
        let server = TestData.mcpServer(toolName: "Claude Code", scope: .project(path: "/Users/test/web"))
        let description = ChangeDescription(event(.removed, .mcpServer(server), nil))
        #expect(description.title == "MCP-Server entfernt")
        #expect(description.body == "„filesystem“ aus Claude Code (Projekt web) entfernt")
    }

    @Test func approval() {
        let description = ChangeDescription(event(.added, nil, .agentAutoApproval(TestData.autoApproval())))
        #expect(description.title == "Automatische Freigabe aktiv")
        #expect(description.body == "Claude Code: permissions.defaultMode = bypassPermissions – Werkzeugaufrufe laufen ohne Rückfrage")
    }

    @Test func modifiedAndRemovedApproval() {
        let before = TestData.autoApproval(value: "acceptEdits")
        let after = TestData.autoApproval()
        let modified = ChangeDescription(event(.modified, .agentAutoApproval(before), .agentAutoApproval(after)))
        #expect(modified.title == "Automatische Freigabe geändert")
        #expect(modified.body == "Claude Code: permissions.defaultMode acceptEdits → bypassPermissions")
        let removed = ChangeDescription(event(.removed, .agentAutoApproval(after), nil))
        #expect(removed.title == "Automatische Freigabe entfernt")
        #expect(removed.body == "Claude Code: permissions.defaultMode = bypassPermissions ist nicht mehr aktiv")
    }

    @Test func historyCategory() {
        let filter = HistoryFilter(category: .agents)
        #expect(HistoryFilter.Category.agents.displayName == "Agenten")
        #expect(filter.matches(TestData.historyEvent(.added, .mcpServer(TestData.mcpServer())), now: TestData.date))
        #expect(filter.matches(TestData.historyEvent(.added, .agentAutoApproval(TestData.autoApproval())), now: TestData.date))
        #expect(!filter.matches(TestData.historyEvent(.added, .installedApp(TestData.installedApp())), now: TestData.date))
        #expect(!HistoryFilter(category: .apps).matches(TestData.historyEvent(.added, .mcpServer(TestData.mcpServer())), now: TestData.date))
    }
}
