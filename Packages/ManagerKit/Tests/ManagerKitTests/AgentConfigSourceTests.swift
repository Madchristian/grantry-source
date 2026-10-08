import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct AgentConfigSourceTests {
    private func write(_ text: String, to relative: String, in home: URL) throws {
        let url = home.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Nur Benutzerdateien – die verwaltete Systemdatei unter `/Library` darf der Test nicht vom echten Mac lesen.
    private func source(home: URL, inspector: any SigningInspecting = RecordingSigningInspector(result: .unknown)) -> AgentConfigSource {
        AgentConfigSource(catalog: TestData.userCatalog, home: home.path, inspector: inspector)
    }

    @Test func collectsServersAndApprovalsFromFixtureHome() async throws {
        try await ScratchDirectory.with { home in
            try write(#"{"mcpServers": {"fs": {"command": "npx", "args": ["-y", "pkg"]}}}"#,
                      to: "Library/Application Support/Claude/claude_desktop_config.json", in: home)
            try write("approval_policy = \"never\"\n[mcp_servers.c]\ncommand = \"c\"\n", to: ".codex/config.toml", in: home)
            try write(#"{"permissions": {"defaultMode": "bypassPermissions"}, "env": {"TOKEN": "GEHEIM"}}"#,
                      to: ".claude/settings.json", in: home)
            let contribution = try await source(home: home).collect()
            #expect(Set(contribution.agents.mcpServers.map(\.name)) == ["fs", "c"])
            #expect(Set(contribution.agents.agentAutoApprovals.map(\.setting)) == ["approval_policy", "permissions.defaultMode"])
            #expect(contribution.limitations.isEmpty)
            #expect(contribution.agents.incompleteFiles.isEmpty)
        }
    }

    @Test func readsRegisteredProjectFilesOnly() async throws {
        try await ScratchDirectory.with { home in
            let project = home.appending(path: "Projekte/web").path
            try write(#"{"projects": {"\#(project)": {"enabledMcpjsonServers": ["p"]}}}"#, to: ".claude.json", in: home)
            try write(#"{"mcpServers": {"p": {"command": "p"}}}"#, to: "Projekte/web/.mcp.json", in: home)
            try write(#"{"mcpServers": {"x": {"command": "x"}}}"#, to: "Projekte/fremd/.mcp.json", in: home)
            let contribution = try await source(home: home).collect()
            #expect(contribution.agents.mcpServers.map(\.name) == ["p"])
            #expect(contribution.agents.mcpServers.first?.configPath == project + "/.mcp.json")
            #expect(contribution.agents.mcpServers.first?.registryPath == home.appending(path: ".claude.json").path)
            #expect(contribution.agents.mcpServers.first?.isEnabled == true)
        }
    }

    /// Server namens `env`/`headers` in `~/.claude.json` (global und im Projektobjekt) und in `.mcp.json` werden erfasst;
    /// geschwärzte Werte erscheinen nirgends.
    @Test func serversNamedLikeRedactedKeysAreCollected() async throws {
        try await ScratchDirectory.with { home in
            let project = home.appending(path: "Projekte/web").path
            try write(#"""
            {"mcpServers": {"env": {"command": "/tmp/x", "env": {"K": "GEHEIM"}}},
             "projects": {"\#(project)": {"mcpServers": {"headers": {"url": "https://mcp.example.com/sse"}},
                                          "enabledMcpjsonServers": ["env"]}}}
            """#, to: ".claude.json", in: home)
            try write(#"{"mcpServers": {"env": {"command": "/tmp/y", "env": {"L": "GEHEIM"}}}}"#,
                      to: "Projekte/web/.mcp.json", in: home)
            let contribution = try await source(home: home).collect()
            let servers = contribution.agents.mcpServers
            #expect(servers.map(\.name) == ["env", "headers", "env"])
            #expect(servers.map(\.environmentKeys) == [["K"], [], ["L"]])
            #expect(servers.last?.isEnabled == true)
            #expect(contribution.limitations.isEmpty)
            #expect(!String(describing: contribution).contains("GEHEIM"))
        }
    }

    /// `claude` im Home gestartet: Das Home steht als Projekt in `~/.claude.json`, `<home>/.claude/settings.json` ist
    /// die Benutzerdatei – ihre Freigabe zählt genau einmal (Benutzer), auch über einen Symlink aufs Home.
    @Test func projectInHomeDoesNotReadUserSettingsTwice() async throws {
        try await ScratchDirectory.with { home in
            try FileManager.default.createSymbolicLink(at: home.appending(path: "verweis"), withDestinationURL: home)
            try write(#"{"projects": {"\#(home.path)": {}, "\#(home.appending(path: "verweis").path)": {}}}"#,
                      to: ".claude.json", in: home)
            try write(#"{"permissions": {"defaultMode": "bypassPermissions"}}"#, to: ".claude/settings.json", in: home)
            let contribution = try await source(home: home).collect()
            let approvals = contribution.agents.agentAutoApprovals
            #expect(approvals.map(\.setting) == ["permissions.defaultMode"])
            #expect(approvals.first?.scope == .user)
            #expect(contribution.limitations.isEmpty)
            #expect(contribution.agents.incompleteFiles.isEmpty)
        }
    }

    @Test func projectSettingsApproveProjectFileServers() async throws {
        try await ScratchDirectory.with { home in
            let project = home.appending(path: "Projekte/web").path
            try write(#"{"projects": {"\#(project)": {}}}"#, to: ".claude.json", in: home)
            try write(#"{"mcpServers": {"p": {"command": "p"}, "q": {"command": "q"}}}"#, to: "Projekte/web/.mcp.json", in: home)
            try write(#"{"enabledMcpjsonServers": ["p"]}"#, to: "Projekte/web/.claude/settings.local.json", in: home)
            try write(#"{"permissions": {"defaultMode": "bypassPermissions"}}"#, to: "Projekte/web/.claude/settings.json", in: home)
            let contribution = try await source(home: home).collect()
            #expect(contribution.agents.mcpServers.map(\.name) == ["p", "q"])
            #expect(contribution.agents.mcpServers.map(\.isEnabled) == [true, nil])
            let approval = try #require(contribution.agents.agentAutoApprovals.first)
            #expect(contribution.agents.agentAutoApprovals.count == 1)
            #expect(approval.setting == "permissions.defaultMode")
            #expect(approval.scope == .project(path: project))
            #expect(approval.configPath == project + "/.claude/settings.json")
            #expect(approval.registryPath == home.appending(path: ".claude.json").path)
            #expect(contribution.limitations.isEmpty)
            #expect(contribution.agents.incompleteFiles.isEmpty)
        }
    }

    @Test func globalEnableAllApprovesProjectFileServers() async throws {
        try await ScratchDirectory.with { home in
            let project = home.appending(path: "Projekte/web").path
            try write(#"{"projects": {"\#(project)": {}}}"#, to: ".claude.json", in: home)
            try write(#"{"mcpServers": {"p": {"command": "p"}}}"#, to: "Projekte/web/.mcp.json", in: home)
            try write(#"{"enableAllProjectMcpServers": true}"#, to: ".claude/settings.json", in: home)
            let contribution = try await source(home: home).collect()
            #expect(contribution.agents.mcpServers.map(\.isEnabled) == [true])
            #expect(contribution.agents.agentAutoApprovals.map(\.setting) == ["enableAllProjectMcpServers"])
        }
    }

    @Test func globalRejectionBeatsProjectApproval() async throws {
        try await ScratchDirectory.with { home in
            let project = home.appending(path: "Projekte/web").path
            try write(#"{"projects": {"\#(project)": {"enabledMcpjsonServers": ["x", "y"]}}}"#, to: ".claude.json", in: home)
            try write(#"{"mcpServers": {"x": {"command": "x"}, "y": {"command": "y"}}}"#, to: "Projekte/web/.mcp.json", in: home)
            try write(#"{"enabledMcpjsonServers": ["x"]}"#, to: "Projekte/web/.claude/settings.local.json", in: home)
            try write(#"{"disabledMcpjsonServers": ["x"]}"#, to: ".claude/settings.json", in: home)
            let contribution = try await source(home: home).collect()
            #expect(contribution.agents.mcpServers.map(\.name) == ["x", "y"])
            #expect(contribution.agents.mcpServers.map(\.isEnabled) == [false, true])
        }
    }

    @Test func brokenFileBecomesLimitationAndGap() async throws {
        try await ScratchDirectory.with { home in
            try write(#"{"mcpServers": {"a": "#, to: ".cursor/mcp.json", in: home)
            try write(#"{"mcpServers": {"ok": {"command": "ok"}}}"#, to: ".gemini/settings.json", in: home)
            let contribution = try await source(home: home).collect()
            #expect(contribution.agents.mcpServers.map(\.name) == ["ok"])
            let path = home.appending(path: ".cursor/mcp.json").path
            #expect(contribution.agents.incompleteFiles == [path])
            #expect(contribution.limitations == ["Konfiguration von Cursor nicht lesbar (\(path)): Zeile 1: Unerwartetes Dateiende"])
        }
    }

    @Test func structuralProblemsAreLimitationsButNoGap() async throws {
        try await ScratchDirectory.with { home in
            try write(#"{"mcpServers": {"a": 1}}"#, to: ".cursor/mcp.json", in: home)
            let contribution = try await source(home: home).collect()
            #expect(contribution.limitations == ["Konfiguration von Cursor: mcp.json: Eintrag „a“ ist kein Objekt"])
            #expect(contribution.agents.incompleteFiles.isEmpty)
        }
    }

    @Test func emptyFileIsNoConfiguration() async throws {
        try await ScratchDirectory.with { home in
            try write("  \n", to: ".cursor/mcp.json", in: home)
            let contribution = try await source(home: home).collect()
            #expect(contribution.limitations.isEmpty)
        }
    }

    @Test func inspectsLocalProgramsAndRecordsFileMode() async throws {
        try await ScratchDirectory.with { home in
            let program = home.appending(path: "bin/server")
            try write("binär", to: "bin/server", in: home)   // kein Skript: Skripte werden nicht signaturgeprüft
            try write(#"{"mcpServers": {"l": {"command": "\#(program.path)"}, "gone": {"command": "/nicht/da"}}}"#,
                      to: ".cursor/mcp.json", in: home)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: home.appending(path: ".cursor/mcp.json").path)
            let inspector = RecordingSigningInspector(result: SigningInfo(kind: .adHoc))
            let contribution = try await source(home: home, inspector: inspector).collect()
            let local = try #require(contribution.agents.mcpServers.first { $0.name == "l" })
            #expect(local.programSigning == SigningInfo(kind: .adHoc))
            #expect(local.programPresence == .present)
            #expect(local.configFileMode == 0o644)
            #expect(contribution.agents.mcpServers.first { $0.name == "gone" }?.programPresence == .missing)
            #expect(inspector.paths == [program.path])
        }
    }

    /// Skripte (`#!`) und Programme hinter einem Interpreter tragen keine Code-Signatur – keine Prüfung.
    @Test func skipsSigningForScriptsAndInterpretedPrograms() async throws {
        try await ScratchDirectory.with { home in
            let script = home.appending(path: "bin/server.sh")
            try write("#!/bin/sh\nexit 0\n", to: "bin/server.sh", in: home)
            try write(#"{"mcpServers": {"s": {"command": "\#(script.path)"}, "n": {"command": "node", "args": ["\#(script.path)"]}}}"#,
                      to: ".cursor/mcp.json", in: home)
            let inspector = RecordingSigningInspector(result: SigningInfo(kind: .adHoc))
            let contribution = try await source(home: home, inspector: inspector).collect()
            #expect(contribution.agents.mcpServers.allSatisfy { $0.programSigning == nil })
            #expect(contribution.agents.mcpServers.first { $0.name == "s" }?.programPresence == .present)
            #expect(inspector.paths.isEmpty)
        }
    }

    @Test func encodedSnapshotNeverContainsSecretValues() async throws {
        try await ScratchDirectory.with { home in
            try write(#"""
            {"mcpServers": {"s": {"command": "npx", "args": ["pkg", "--api-key=GEHEIM-A"], "env": {"API_KEY": "GEHEIM-B"}},
                            "r": {"url": "https://u:GEHEIM-C@h/x?token=GEHEIM-D", "headers": {"Authorization": "GEHEIM-E"}}}}
            """#, to: ".cursor/mcp.json", in: home)
            try write("[mcp_servers.t]\ncommand = \"t\"\nhttp_headers = { X = \"GEHEIM-F\" }\n[mcp_servers.t.env]\nK = \"GEHEIM-G\"\n",
                      to: ".codex/config.toml", in: home)
            let contribution = try await source(home: home).collect()
            let snapshot = Snapshot(takenAt: TestData.date, grants: [], autostartItems: [], mcpServers: contribution.agents.mcpServers,
                                    agentAutoApprovals: contribution.agents.agentAutoApprovals, sourceErrors: [],
                                    sourceLimitations: contribution.limitations.map { SourceLimitation(source: .agents, message: $0) })
            let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
            #expect(!json.contains("GEHEIM"))
            #expect(contribution.agents.mcpServers.count == 3)
        }
    }
}
