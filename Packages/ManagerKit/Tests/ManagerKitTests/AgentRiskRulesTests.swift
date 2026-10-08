import Foundation
import Testing
@testable import ManagerKit

@Suite struct AgentRiskRulesTests {
    private func findings(_ rule: some RiskRule, _ servers: [MCPServerEntry], approvals: [AgentAutoApproval] = []) -> [RiskFinding] {
        rule.evaluate(TestData.agentSnapshot(servers, approvals: approvals))
    }

    private func cleartextServer(_ host: String) -> MCPServerEntry {
        TestData.mcpServer(host, transport: .remote(url: "http://\(host)/mcp", kind: nil))
    }

    @Test func unpinnedPackage() {
        let unpinned = TestData.mcpServer(packageSource: .npm(package: "@x/fs", version: nil))
        let pinned = TestData.mcpServer("p", packageSource: .npm(package: "@x/fs", version: "1.0.0"))
        let result = findings(UnpinnedPackageRule(), [unpinned, pinned])
        #expect(result.map(\.recordID) == [unpinned.id])
        #expect(result.first?.severity == .low)
        #expect(result.first?.message == "„filesystem“ (Claude Desktop) kann bei jedem Start eine neuere Version von @x/fs laden")
    }

    @Test func plaintextSecret() {
        let env = TestData.mcpServer(environmentKeys: ["MODE", "GITHUB_TOKEN"])
        let args = TestData.mcpServer("a", hasSecretInArguments: true)
        let clean = TestData.mcpServer("c", environmentKeys: ["MODE"])
        let result = findings(PlaintextSecretRule(home: "/Users/test"), [env, args, clean])
        #expect(result.map(\.recordID) == [env.id, args.id])
        #expect(result[0].message == "„filesystem“ (Claude Desktop): mögliches Geheimnis im Klartext in der Konfiguration (GITHUB_TOKEN)")
        #expect(result[1].message == "„a“ (Claude Desktop): mögliches Geheimnis im Klartext in der Konfiguration (Argumente)")
    }

    @Test func plaintextSecretInSharedFileOutsideHome() {
        let server = TestData.mcpServer(configPath: "/Library/Application Support/ClaudeCode/managed-mcp.json",
                                        environmentKeys: ["API_KEY"], configFileMode: 0o644)
        let message = findings(PlaintextSecretRule(home: "/Users/test"), [server]).first?.message
        #expect(message?.hasSuffix(" – Datei für andere lesbar") == true)
    }

    @Test func writableConfig() {
        let writable = TestData.mcpServer(configFileMode: 0o666)
        let result = findings(WritableAgentConfigRule(home: "/Users/test"), [writable, TestData.mcpServer("b")])
        #expect(result.map(\.severity) == [.medium])
        #expect(result.first?.recordID == writable.id)
        #expect(result.first?.message == "„filesystem“ (Claude Desktop): Konfigurationsdatei "
            + "~/Library/Application Support/Claude/claude_desktop_config.json ist für alle Benutzer beschreibbar")
    }

    @Test func writableConfigNamesTheProjectScope() {
        let server = TestData.mcpServer("web", toolID: "claudeCode", toolName: "Claude Code",
                                        configPath: "/work/web/.mcp.json", scope: .project(path: "/work/web"), configFileMode: 0o666)
        let message = findings(WritableAgentConfigRule(home: "/Users/test"), [server]).first?.message
        #expect(message == "„web“ (Claude Code (Projekt web)): Konfigurationsdatei /work/web/.mcp.json ist für alle Benutzer beschreibbar")
    }

    @Test func untrustedProgram() {
        let unsigned = TestData.mcpServer("u", packageSource: .localProgram(path: "/opt/x"),
                                          programSigning: SigningInfo(kind: .unsigned), programPresence: .present)
        let downloads = TestData.mcpServer("d", packageSource: .localProgram(path: "/Users/test/Downloads/s.js"),
                                           programPresence: .present)
        let signed = TestData.mcpServer("s", packageSource: .localProgram(path: "/opt/y"),
                                        programSigning: TestData.developerSigning, programPresence: .present)
        let tmp = TestData.mcpServer("t", packageSource: .localProgram(path: "/private/tmp/x"), programPresence: .present)
        let result = findings(UntrustedMCPProgramRule(home: "/Users/test"), [unsigned, downloads, signed, tmp])
        #expect(Set(result.map(\.recordID)) == [unsigned.id, downloads.id, tmp.id])
        #expect(result.allSatisfy { $0.severity == .medium })
    }

    @Test func adHocSignedProgramIsOnlyLowSeverity() {
        let homebrew = TestData.mcpServer("node", packageSource: .localProgram(path: "/opt/homebrew/bin/node"),
                                          programSigning: SigningInfo(kind: .adHoc), programPresence: .present)
        let result = findings(UntrustedMCPProgramRule(home: "/Users/test"), [homebrew])
        #expect(result.map(\.severity) == [.low])
        #expect(result.first?.message == "„node“ (Claude Desktop) startet /opt/homebrew/bin/node, das nur ad hoc signiert ist")
    }

    @Test func adHocSignedProgramInTemporaryFolderStaysMedium() {
        let server = TestData.mcpServer("x", packageSource: .localProgram(path: "/tmp/x"),
                                        programSigning: SigningInfo(kind: .adHoc), programPresence: .present)
        let result = findings(UntrustedMCPProgramRule(home: "/Users/test"), [server])
        #expect(result.map(\.severity) == [.medium])
        #expect(result.first?.message.hasSuffix("in einem temporären bzw. geteilten Ordner liegt") == true)
    }

    @Test func untrustedProgramOnlyWhenPresent() {
        let unknown = TestData.mcpServer("u", packageSource: .localProgram(path: "/tmp/x"),
                                         programSigning: SigningInfo(kind: .unsigned), programPresence: .unknown)
        #expect(findings(UntrustedMCPProgramRule(home: "/Users/test"), [unknown]).isEmpty)
    }

    @Test func untrustedProgramLocations() {
        func server(_ path: String) -> MCPServerEntry {
            TestData.mcpServer(path, packageSource: .localProgram(path: path), programPresence: .present)
        }
        let rule = UntrustedMCPProgramRule(home: "/Users/test")
        let flagged = ["/tmp/x", "/private/tmp/x", "/var/tmp/x", "/private/var/tmp/x", "/var/folders/ab/T/x",
                       "/private/var/folders/ab/T/x", "/Users/Shared/x", "/Users/test/Downloads/x",
                       "/Users/test/downloads/x", "/TMP/x", "/Users/test/Documents/../Downloads/x"].map(server)
        let clean = ["/tmp/../usr/local/bin/x", "/usr/local/bin/x", "/tmpfoo/x", "/Users/test/Downloads/../Documents/x",
                     "/Users/other/Downloads/x", "/Users/Shared"].map(server)
        #expect(Set(findings(rule, flagged).map(\.recordID)) == Set(flagged.map(\.id)))
        #expect(findings(rule, clean).isEmpty)
    }

    @Test func untrustedProgramHomeWithTrailingSlash() {
        let download = TestData.mcpServer("d", packageSource: .localProgram(path: "/Users/test/Downloads/s.js"), programPresence: .present)
        let result = findings(UntrustedMCPProgramRule(home: "/Users/test/"), [download])
        #expect(result.first?.message == "„d“ (Claude Desktop) startet ~/Downloads/s.js, das im Download-Ordner liegt")
    }

    @Test func cleartextRemote() {
        let remote = TestData.mcpServer("r", transport: .remote(url: "http://mcp.example.com/sse", kind: "sse"))
        let local = TestData.mcpServer("l", transport: .remote(url: "http://127.0.0.1:3000/mcp", kind: nil))
        let localhost = TestData.mcpServer("h", transport: .remote(url: "http://localhost:3000", kind: nil))
        let tls = TestData.mcpServer("t", transport: .remote(url: "https://x", kind: nil))
        let result = findings(CleartextRemoteRule(), [remote, local, localhost, tls])
        #expect(result.map(\.recordID) == [remote.id])
        #expect(result.first?.message == "„r“ (Claude Desktop) verbindet sich unverschlüsselt mit mcp.example.com")
    }

    @Test func activeAutoApproval() {
        let result = findings(ActiveAutoApprovalRule(), [], approvals: [TestData.autoApproval()])
        #expect(result.first?.severity == .low)
        #expect(result.first?.message == "Claude Code: Werkzeugaufrufe laufen ohne Rückfrage")
    }

    @Test func cleartextRemoteLoopbackRangeOnlyForIPAddresses() {
        let loopback = ["127.0.0.2:8080", "[::1]:3000", "0.0.0.0", "dev.localhost", "LOCALHOST."].map(cleartextServer)
        let foreign = ["127.example.com", "127.0.0.256", "127.0.0", "[::2]"].map(cleartextServer)
        let rule = CleartextRemoteRule()
        #expect(findings(rule, loopback).isEmpty)
        #expect(Set(findings(rule, foreign).map(\.recordID)) == Set(foreign.map(\.id)))
    }

    @Test func cleartextRemoteIPv6Forms() {
        let local = ["[::1]", "[0:0:0:0:0:0:0:1]", "[0000:0000:0000:0000:0000:0000:0000:0001]", "[::]", "[::ffff:127.0.0.1]",
                     "[::ffff:7f00:1]", "[::ffff:0.0.0.0]", "[::FFFF:127.1.2.3]:8080"].map(cleartextServer)
        let foreign = ["[2001:db8::1]", "[::ffff:10.0.0.1]", "[::ffff:8.8.8.8]", "[::2]", "[1::1]",
                       "[fe80::1]", "[::1:1]"].map(cleartextServer)
        let rule = CleartextRemoteRule()
        #expect(findings(rule, local).isEmpty)
        #expect(Set(findings(rule, foreign).map(\.recordID)) == Set(foreign.map(\.id)))
    }

    @Test func untrustedProgramIgnoresScriptsAndMissingPrograms() {
        let script = TestData.mcpServer("s", packageSource: .localProgram(path: "/opt/server.js"), programPresence: .present)
        let missing = TestData.mcpServer("m", packageSource: .localProgram(path: "/tmp/x"), programPresence: .missing)
        let npm = TestData.mcpServer("n", packageSource: .npm(package: "x", version: nil), programPresence: .present)
        #expect(findings(UntrustedMCPProgramRule(home: "/Users/test"), [script, missing, npm]).isEmpty)
    }

    @Test func untrustedProgramMessagesNameTheReason() {
        let rule = UntrustedMCPProgramRule(home: "/Users/test")
        let downloads = TestData.mcpServer("d", packageSource: .localProgram(path: "/Users/test/Downloads/s.js"), programPresence: .present)
        let temporary = TestData.mcpServer("t", packageSource: .localProgram(path: "/var/folders/ab/x"), programPresence: .present)
        let shared = TestData.mcpServer("h", packageSource: .localProgram(path: "/Users/Shared/x"), programPresence: .present)
        let adHoc = TestData.mcpServer("a", packageSource: .localProgram(path: "/opt/x"),
                                       programSigning: SigningInfo(kind: .adHoc), programPresence: .present)
        let unsigned = TestData.mcpServer("u", packageSource: .localProgram(path: "/opt/y"),
                                          programSigning: SigningInfo(kind: .unsigned), programPresence: .present)
        let messages = findings(rule, [downloads, temporary, shared, adHoc, unsigned]).map(\.message)
        #expect(messages.contains("„d“ (Claude Desktop) startet ~/Downloads/s.js, das im Download-Ordner liegt"))
        #expect(messages.contains("„t“ (Claude Desktop) startet /var/folders/ab/x, das in einem temporären bzw. geteilten Ordner liegt"))
        #expect(messages.contains("„h“ (Claude Desktop) startet /Users/Shared/x, das in einem temporären bzw. geteilten Ordner liegt"))
        #expect(messages.contains("„a“ (Claude Desktop) startet /opt/x, das nur ad hoc signiert ist"))
        #expect(messages.contains("„u“ (Claude Desktop) startet /opt/y, das nicht signiert ist"))
    }

    @Test func plaintextSecretFromHeaderNames() {
        let server = TestData.mcpServer("h", transport: .remote(url: "https://x", kind: nil), headerKeys: ["Authorization", "Accept"])
        let message = findings(PlaintextSecretRule(home: "/Users/test"), [server]).first?.message
        #expect(message == "„h“ (Claude Desktop): mögliches Geheimnis im Klartext in der Konfiguration (Authorization)")
    }

    @Test func plaintextSecretInSharedFileInsideHomeHasNoSuffix() {
        let server = TestData.mcpServer(environmentKeys: ["API_KEY"], configFileMode: 0o644)
        #expect(findings(PlaintextSecretRule(home: "/Users/test"), [server]).first?.message.hasSuffix("(API_KEY)") == true)
        #expect(findings(PlaintextSecretRule(home: "/Users/test/"), [server]).first?.message.hasSuffix("(API_KEY)") == true)
    }

    @Test func plaintextSecretNamesAndArgumentsTogether() {
        let local = TestData.mcpServer("l", environmentKeys: ["GITHUB_TOKEN"], hasSecretInArguments: true)
        let remote = TestData.mcpServer("r", transport: .remote(url: "https://x/?token=•••", kind: nil),
                                        headerKeys: ["Authorization"], hasSecretInArguments: true)
        let urlOnly = TestData.mcpServer("u", transport: .remote(url: "https://x/?token=•••", kind: nil), hasSecretInArguments: true)
        let messages = findings(PlaintextSecretRule(home: "/Users/test"), [local, remote, urlOnly]).map(\.message)
        #expect(messages == [
            "„l“ (Claude Desktop): mögliches Geheimnis im Klartext in der Konfiguration (GITHUB_TOKEN, Argumente)",
            "„r“ (Claude Desktop): mögliches Geheimnis im Klartext in der Konfiguration (Authorization, URL)",
            "„u“ (Claude Desktop): mögliches Geheimnis im Klartext in der Konfiguration (URL)",
        ])
    }

    @Test func unpinnedContainerAndPyPI() {
        let latest = TestData.mcpServer("c", packageSource: .container(image: "ghcr.io/x/y", reference: "latest"))
        let tagged = TestData.mcpServer("t", packageSource: .container(image: "ghcr.io/x/y", reference: "1.2"))
        let pypi = TestData.mcpServer("p", packageSource: .pypi(package: "mcp-server-git", version: nil))
        let result = findings(UnpinnedPackageRule(), [latest, tagged, pypi])
        #expect(Set(result.map(\.recordID)) == [latest.id, pypi.id])
        #expect(result.contains { $0.message == "„c“ (Claude Desktop) kann bei jedem Start eine neuere Version von ghcr.io/x/y laden" })
    }

    @Test func packageNameOnlyForPackages() {
        #expect(PackageSource.npm(package: "@x/fs", version: nil).packageName == "@x/fs")
        #expect(PackageSource.pypi(package: "p", version: "1").packageName == "p")
        #expect(PackageSource.container(image: "i", reference: nil).packageName == "i")
        #expect(PackageSource.localProgram(path: "/a").packageName == nil)
        #expect(PackageSource.command(name: "uv").packageName == nil)
        #expect(PackageSource.remote(host: "h").packageName == nil)
    }

    @Test func findingSubjectNamesServerAndLocation() {
        #expect(TestData.mcpServer().findingSubject == "„filesystem“ (Claude Desktop)")
        let project = TestData.mcpServer("web", toolName: "Claude Code", scope: .project(path: "/work/web"))
        #expect(project.findingSubject == "„web“ (Claude Code (Projekt web))")
    }

    @Test func messagesUseTheSubjectWithProjectScope() {
        let project = TestData.mcpServer(
            "web", toolName: "Claude Code", scope: .project(path: "/work/web"),
            transport: .remote(url: "http://mcp.example.com/sse", kind: nil), environmentKeys: ["API_KEY"],
            packageSource: .npm(package: "p", version: nil)
        )
        let subject = "„web“ (Claude Code (Projekt web))"
        #expect(findings(UnpinnedPackageRule(), [project]).first?.message == "\(subject) kann bei jedem Start eine neuere Version von p laden")
        #expect(findings(CleartextRemoteRule(), [project]).first?.message == "\(subject) verbindet sich unverschlüsselt mit mcp.example.com")
        #expect(findings(PlaintextSecretRule(home: "/Users/test"), [project]).first?.message.hasPrefix("\(subject): ") == true)
    }

    @Test func standardEvaluatorIncludesAgentRules() {
        let snapshot = TestData.agentSnapshot([TestData.mcpServer()], approvals: [TestData.autoApproval()])
        let rules = Set(RiskEvaluator.standard.evaluate(snapshot).map(\.rule))
        #expect(rules.isSuperset(of: [.unpinnedPackage, .autoApproval]))
    }
}
