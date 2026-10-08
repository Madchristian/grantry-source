import Foundation
import Testing
@testable import ManagerKit

@Suite struct MCPServerEntryTests {
    @Test func identityIsKindToolFileScopeAndName() {
        let entry = TestData.mcpServer(scope: .project(path: "/Users/test/p"))
        #expect(entry.id == "mcp|claudeDesktop|/Users/test/Library/Application Support/Claude/claude_desktop_config.json|project:/Users/test/p|filesystem")
        #expect(TestData.mcpServer(scope: .system).id.hasSuffix("|system|filesystem"))
    }

    @Test func significantChangesAreTransportAndEnabledState() {
        let entry = TestData.mcpServer()
        #expect(entry.hasSignificantChanges(comparedTo: TestData.mcpServer(transport: .local(command: "npx", arguments: ["pkg@2.0.0"]))))
        #expect(entry.hasSignificantChanges(comparedTo: TestData.mcpServer(isEnabled: false)))
        #expect(!entry.hasSignificantChanges(comparedTo: TestData.mcpServer(environmentKeys: ["A"], programSigning: .unknown, configFileMode: 0o644)))
    }

    @Test func summaryJoinsCommandAndTruncates() {
        #expect(TestData.mcpServer().summary == "npx -y pkg")
        #expect(TestData.mcpServer(transport: .remote(url: "https://x.example/mcp", kind: "http")).summary == "https://x.example/mcp")
        let long = TestData.mcpServer(transport: .local(command: "npx", arguments: [String(repeating: "a", count: 200)]))
        #expect(long.summary.count == MCPServerEntry.summaryLength)
        #expect(long.summary.hasSuffix("…"))
    }

    @Test func remoteHostAndCleartext() {
        #expect(MCPTransport.remote(url: "http://user:•••@[::1]:8080/sse", kind: nil).remoteHost == "::1")
        #expect(MCPTransport.remote(url: "HTTP://api.example.com:80/x", kind: nil).remoteHost == "api.example.com")
        #expect(MCPTransport.remote(url: "http://a", kind: nil).usesCleartextHTTP)
        #expect(!MCPTransport.remote(url: "https://a", kind: nil).usesCleartextHTTP)
        #expect(MCPTransport.local(command: "x", arguments: []).remoteHost == nil)
    }

    @Test func locationDescription() {
        #expect(TestData.mcpServer().locationDescription == "Claude Desktop")
        #expect(TestData.mcpServer(scope: .project(path: "/Users/test/Projekte/web")).locationDescription == "Claude Desktop (Projekt web)")
        #expect(TestData.mcpServer(scope: .system).locationDescription == "Claude Desktop (verwaltet)")
    }

    @Test func approvalIdentityAndSignificance() {
        let approval = TestData.autoApproval()
        #expect(approval.id == "approval|claudeCode|/Users/test/.claude/settings.json|user|permissions.defaultMode")
        #expect(approval.hasSignificantChanges(comparedTo: TestData.autoApproval(value: "acceptEdits")))
        #expect(!approval.hasSignificantChanges(comparedTo: TestData.autoApproval(message: "anders")))
    }

    @Test func serverAndApprovalWithTheSameNameHaveDifferentIDs() {
        // Codex: `[mcp_servers.approval_policy]` und `approval_policy = "never"` in derselben Datei.
        let path = "/Users/test/.codex/config.toml"
        let server = TestData.mcpServer("approval_policy", toolID: "codex", toolName: "Codex", configPath: path)
        let approval = TestData.autoApproval(
            toolID: "codex", toolName: "Codex", configPath: path, setting: "approval_policy", value: "never"
        )
        #expect(server.id != approval.id)
        #expect(server.id.hasPrefix("mcp|codex|"))
        #expect(approval.id.hasPrefix("approval|codex|"))
        // Auch im Projekt-Bereich und in der Systemkonfiguration.
        for scope in [AgentScope.user, .project(path: "/Users/test/p"), .system] {
            let sameNameServer = TestData.mcpServer("x", toolID: "codex", configPath: path, scope: scope)
            let sameNameApproval = TestData.autoApproval(toolID: "codex", configPath: path, scope: scope, setting: "x")
            #expect(sameNameServer.id != sameNameApproval.id)
        }
    }

    @Test func roundTripsThroughJSON() throws {
        let entry = TestData.mcpServer(scope: .project(path: "/p"), programSigning: TestData.developerSigning)
        let data = try JSONEncoder().encode(entry)
        #expect(try JSONDecoder().decode(MCPServerEntry.self, from: data) == entry)
    }

    // MARK: Identität (kollisionsfrei)

    @Test func identityDoesNotCollideWhenComponentsContainSeparators() {
        let first = TestData.mcpServer("b|user|c", configPath: "a")
        let second = TestData.mcpServer("c", configPath: "a|user|b")
        #expect(first.id != second.id)
        #expect(TestData.autoApproval(configPath: "a", setting: "b|user|c").id
            != TestData.autoApproval(configPath: "a|user|b", setting: "c").id)
    }

    @Test func identityEscapesBackslashAndPipePerComponent() {
        #expect(RecordIdentity.join(["a", "b"]) == "a|b")
        #expect(RecordIdentity.join([#"a\"#, "b|c"]) == #"a\\|b\|c"#)
        // Ein Backslash vor dem Trenner darf diesen nicht „verschlucken“.
        #expect(RecordIdentity.join([#"a\"#, "b"]) != RecordIdentity.join(["a", #"\b"#]))
        #expect(RecordIdentity.join([#"a\|"#, "b"]) != RecordIdentity.join([#"a\"#, "|b"]))
    }

    @Test func identityOfProjectScopeEscapesThePath() {
        let entry = TestData.mcpServer(scope: .project(path: "/Users/test/a|b"))
        #expect(entry.id.hasSuffix(#"|project:/Users/test/a\|b|filesystem"#))
    }

    // MARK: Signifikanz

    @Test func derivedAndSideInformationIsNotSignificant() {
        let entry = TestData.mcpServer()
        #expect(!entry.hasSignificantChanges(comparedTo: TestData.mcpServer(headerKeys: ["Authorization"])))
        #expect(!entry.hasSignificantChanges(comparedTo: TestData.mcpServer(packageSource: .command(name: "npx"))))
        #expect(!entry.hasSignificantChanges(comparedTo: TestData.mcpServer(programPresence: .present)))
        #expect(!entry.hasSignificantChanges(comparedTo: TestData.mcpServer(hasSecretInArguments: true)))
        #expect(!entry.hasSignificantChanges(comparedTo: TestData.mcpServer(registryPath: "/Users/test/.claude.json")))
        #expect(!entry.hasSignificantChanges(comparedTo: TestData.mcpServer(toolName: "Anderer Name")))
    }

    @Test func switchingTheTransportKindIsSignificant() {
        let local = TestData.mcpServer()
        let remote = TestData.mcpServer(transport: .remote(url: "https://x.example/mcp", kind: nil))
        #expect(local.hasSignificantChanges(comparedTo: remote))
        #expect(remote.hasSignificantChanges(comparedTo: TestData.mcpServer(transport: .remote(url: "https://x.example/mcp", kind: "sse"))))
    }

    @Test func enabledStateDistinguishesNilFromTrue() {
        #expect(TestData.mcpServer(isEnabled: nil).hasSignificantChanges(comparedTo: TestData.mcpServer(isEnabled: true)))
        #expect(TestData.mcpServer(isEnabled: true).hasSignificantChanges(comparedTo: TestData.mcpServer(isEnabled: false)))
    }

    // MARK: Host einer entfernten URL

    @Test func remoteHostLowercasesIPv6AndHostnames() {
        #expect(MCPTransport.remote(url: "http://[FE80::1]:8080/x", kind: nil).remoteHost == "fe80::1")
        #expect(MCPTransport.remote(url: "https://API.Example.COM/x", kind: nil).remoteHost == "api.example.com")
    }

    @Test func remoteHostStripsTrailingDot() {
        #expect(MCPTransport.remote(url: "https://example.com./x", kind: nil).remoteHost == "example.com")
        #expect(MCPTransport.remote(url: "https://example.com.:443/x", kind: nil).remoteHost == "example.com")
        #expect(MCPTransport.remote(url: "https://./x", kind: nil).remoteHost == nil)
    }

    @Test func remoteHostIgnoresAtSignsOutsideTheAuthority() {
        // `@` im Passwort: Es gilt das letzte vor dem Pfad.
        #expect(MCPTransport.remote(url: "https://user:p@ss@host.example/x", kind: nil).remoteHost == "host.example")
        // `@` in Pfad, Query oder Fragment gehört nicht zur Autorität.
        #expect(MCPTransport.remote(url: "https://host.example/x?mail=a@b", kind: nil).remoteHost == "host.example")
        #expect(MCPTransport.remote(url: "https://host.example?mail=a@b", kind: nil).remoteHost == "host.example")
        #expect(MCPTransport.remote(url: "https://host.example#a@b", kind: nil).remoteHost == "host.example")
    }

    @Test func remoteHostIsNilWhenMissingOrMalformed() {
        #expect(MCPTransport.remote(url: "http:///path", kind: nil).remoteHost == nil)
        #expect(MCPTransport.remote(url: "http://:8080/x", kind: nil).remoteHost == nil)
        #expect(MCPTransport.remote(url: "http://user@/x", kind: nil).remoteHost == nil)
        #expect(MCPTransport.remote(url: "http://[::1/x", kind: nil).remoteHost == nil)
        #expect(MCPTransport.remote(url: "http://[]:80/x", kind: nil).remoteHost == nil)
        #expect(MCPTransport.remote(url: "kein-schema", kind: nil).remoteHost == nil)
        #expect(MCPTransport.remote(url: "", kind: nil).remoteHost == nil)
    }

    // MARK: Geltungsbereich

    @Test func scopeLabelNamesTheProjectFolder() {
        #expect(AgentScope.user.scopeLabel == nil)
        #expect(AgentScope.system.scopeLabel == "verwaltet")
        #expect(AgentScope.project(path: "/Users/test/Projekte/web").scopeLabel == "Projekt web")
        #expect(AgentScope.project(path: "/Users/test/Projekte/web/").scopeLabel == "Projekt web")
        #expect(AgentScope.project(path: "web").scopeLabel == "Projekt web")
    }

    @Test func scopeLabelFallsBackWithoutAFolderName() {
        #expect(AgentScope.project(path: "").scopeLabel == "Projekt")
        #expect(AgentScope.project(path: "/").scopeLabel == "Projekt")
        #expect(AgentScope.project(path: "//").scopeLabel == "Projekt")
    }

    @Test func displaySuffixIsDerivedFromTheLabel() {
        #expect(AgentScope.user.displaySuffix == "")
        #expect(AgentScope.system.displaySuffix == " (verwaltet)")
        #expect(AgentScope.project(path: "/p/web").displaySuffix == " (Projekt web)")
        #expect(AgentScope.project(path: "/").displaySuffix == " (Projekt)")
        #expect(TestData.mcpServer(scope: .project(path: "/")).locationDescription == "Claude Desktop (Projekt)")
    }

    // MARK: Zusammenfassung

    @Test func commandLineQuotesArgumentsWithWhitespace() {
        let local = MCPTransport.local(command: "/Applications/My App/bin/x", arguments: ["-y", "a b", "c\td", ""])
        #expect(local.commandLine == "'/Applications/My App/bin/x' -y 'a b' 'c\td' ''")
        #expect(MCPTransport.local(command: "npx", arguments: ["-y", "pkg"]).commandLine == "npx -y pkg")
        #expect(MCPTransport.remote(url: "https://x", kind: nil).commandLine == nil)
        #expect(TestData.mcpServer(transport: .local(command: "npx", arguments: ["a b"])).summary == "npx 'a b'")
    }

    @Test(arguments: [
        (nil, nil, nil), (nil, true, "aktiviert"), (nil, false, "deaktiviert"),
        ("/r", nil, "Freigabe ausstehend"), ("/r", true, "freigegeben"), ("/r", false, "abgelehnt"),
    ] as [(String?, Bool?, String?)])
    func enabledTextDependsOnRegistry(registryPath: String?, isEnabled: Bool?, text: String?) {
        #expect(TestData.mcpServer(isEnabled: isEnabled, registryPath: registryPath).enabledText == text)
    }

    @Test func summaryCollapsesWhitespaceRuns() {
        let entry = TestData.mcpServer(transport: .local(command: "npx", arguments: ["-y", "a\nb\t  c", "\r\nd"]))
        #expect(entry.summary == "npx -y 'a b c' ' d'")
        let remote = TestData.mcpServer(transport: .remote(url: "https://x.example/a\nb", kind: nil))
        #expect(remote.summary == "https://x.example/a b")
    }

    @Test func summaryCollapsesWhitespaceBeforeTruncating() {
        // 100 Zeichen, dann ein langer Whitespace-Lauf, dann 30 Zeichen: Zusammengefasst sind es mehr als die Höchstlänge.
        let argument = String(repeating: "a", count: 100) + String(repeating: "\n", count: 50) + String(repeating: "b", count: 30)
        let summary = TestData.mcpServer(transport: .local(command: "x", arguments: [argument])).summary
        #expect(summary.count == MCPServerEntry.summaryLength)
        #expect(summary.hasPrefix("x '" + String(repeating: "a", count: 100) + " b"))
        #expect(summary.hasSuffix("…"))
    }

    @Test func summaryOfExactlyMaximumLengthIsNotTruncated() {
        let exact = String(repeating: "a", count: MCPServerEntry.summaryLength - 2)   // plus „x “ = Höchstlänge
        let entry = TestData.mcpServer(transport: .local(command: "x", arguments: [exact]))
        #expect(entry.summary == "x " + exact)
        #expect(entry.summary.count == MCPServerEntry.summaryLength)
        #expect(!entry.summary.hasSuffix("…"))
        let longer = TestData.mcpServer(transport: .local(command: "x", arguments: [exact + "a"]))
        #expect(longer.summary.count == MCPServerEntry.summaryLength)
        #expect(longer.summary.hasSuffix("…"))
    }

    // MARK: Snapshot-Format – Labels sind Teil des Snapshot-Formats

    @Test func agentScopeDecodesFromFixedJSON() throws {
        #expect(try decode(AgentScope.self, #"{"user":{}}"#) == .user)
        #expect(try decode(AgentScope.self, #"{"system":{}}"#) == .system)
        #expect(try decode(AgentScope.self, #"{"project":{"path":"/Users/test/p"}}"#) == .project(path: "/Users/test/p"))
    }

    @Test func mcpTransportDecodesFromFixedJSON() throws {
        #expect(try decode(MCPTransport.self, #"{"local":{"command":"npx","arguments":["-y","pkg"]}}"#)
            == .local(command: "npx", arguments: ["-y", "pkg"]))
        #expect(try decode(MCPTransport.self, #"{"remote":{"url":"https://x.example/mcp","kind":"http"}}"#)
            == .remote(url: "https://x.example/mcp", kind: "http"))
        #expect(try decode(MCPTransport.self, #"{"remote":{"url":"https://x.example/mcp"}}"#)
            == .remote(url: "https://x.example/mcp", kind: nil))
    }

    @Test func agentScopeAndTransportEncodeToTheFixedFormat() throws {
        #expect(try encodedString(AgentScope.user) == #"{"user":{}}"#)
        #expect(try encodedString(AgentScope.system) == #"{"system":{}}"#)
        #expect(try encodedString(AgentScope.project(path: "/p")) == #"{"project":{"path":"/p"}}"#)
        #expect(try encodedString(MCPTransport.local(command: "npx", arguments: ["-y"]))
            == #"{"local":{"arguments":["-y"],"command":"npx"}}"#)
        #expect(try encodedString(MCPTransport.remote(url: "https://x.example", kind: "sse"))
            == #"{"remote":{"kind":"sse","url":"https://x.example"}}"#)
    }

    @Test func approvalRoundTripsThroughJSON() throws {
        for registryPath in [nil, "/Users/test/.claude.json"] {
            let approval = TestData.autoApproval(registryPath: registryPath, scope: .project(path: "/Users/test/p"))
            let data = try JSONEncoder().encode(approval)
            #expect(try JSONDecoder().decode(AgentAutoApproval.self, from: data) == approval)
        }
    }

    /// Ältere Snapshots kennen `registryPath` nicht.
    @Test func approvalWithoutRegistryPathDecodesAsNil() throws {
        let json = #"""
        {"toolID":"claudeCode","toolName":"Claude Code","configPath":"/p/.claude/settings.json",
         "scope":{"project":{"path":"/p"}},"setting":"permissions.defaultMode","value":"bypassPermissions",
         "message":"m","source":"agents"}
        """#
        let approval = try decode(AgentAutoApproval.self, json)
        #expect(approval.registryPath == nil)
        #expect(approval.configPath == "/p/.claude/settings.json")
    }

    @Test func approvalRegistryPathIsNotSignificant() {
        let approval = TestData.autoApproval(registryPath: "/h/.claude.json")
        #expect(!approval.hasSignificantChanges(comparedTo: TestData.autoApproval()))
        #expect(approval.id == TestData.autoApproval().id)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func encodedString(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
