import Foundation
import Testing
@testable import ManagerKit

@Suite struct AgentConfigExtractorTests {
    let catalog = AgentToolCatalog.standard

    private func document(
        _ text: String, _ syntax: ConfigSyntax = .json, redaction: ConfigRedaction = .agentConfig()
    ) throws -> ConfigValue {
        try ConfigParsing.parse(Data(text.utf8), syntax: syntax, redaction: redaction)
    }

    private func extract(_ toolID: String, file index: Int = 0, _ text: String, _ syntax: ConfigSyntax = .json) throws -> AgentExtraction {
        let tool = try #require(catalog.tool(id: toolID))
        let file = tool.files[index]
        return AgentConfigExtractor.extract(try document(text, syntax, redaction: file.redaction), file: file, tool: tool,
                                            configPath: file.expandedPath(home: "/h"))
    }

    @Test func claudeDesktopLocalServer() throws {
        let result = try extract("claudeDesktop", #"""
        {"mcpServers": {"fs": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "~/"],
                               "env": {"GITHUB_TOKEN": "GEHEIM", "MODE": "x"}}}}
        """#)
        let server = try #require(result.servers.first)
        #expect(server.name == "fs")
        #expect(server.transport == .local(command: "npx", arguments: ["-y", "@modelcontextprotocol/server-filesystem", "~/"]))
        #expect(server.environmentKeys == ["GITHUB_TOKEN", "MODE"])
        #expect(server.packageSource == .npm(package: "@modelcontextprotocol/server-filesystem", version: nil))
        #expect(server.scope == .user)
        #expect(server.configPath == "/h/Library/Application Support/Claude/claude_desktop_config.json")
        #expect(server.isEnabled == nil)
    }

    @Test func remoteServerWithHeadersAndMaskedURL() throws {
        let result = try extract("vscode", #"""
        { // Kommentar
          "servers": {"gh": {"type": "http", "url": "https://api.example.com/mcp?token=abc", "headers": {"Authorization": "GEHEIM"}},},
        }
        """#, .jsonc)
        let server = try #require(result.servers.first)
        #expect(server.transport == .remote(url: "https://api.example.com/mcp?token=•••", kind: "http"))
        #expect(server.headerKeys == ["Authorization"])
        #expect(server.hasSecretInArguments)
        #expect(server.packageSource == .remote(host: "api.example.com"))
    }

    @Test func claudeCodeProjectsAndDisabledNames() throws {
        let result = try extract("claudeCode", #"""
        {"mcpServers": {"g": {"command": "uvx", "args": ["x==1.0"]}},
         "projects": {"/p/web": {"mcpServers": {"a": {"command": "node", "args": ["/p/web/a.js"]}, "b": {"command": "b"}},
                                 "disabledMcpServers": ["b"], "enableAllProjectMcpServers": true},
                      "/p/leer": {}}}
        """#)
        #expect(result.servers.map(\.name) == ["g", "a", "b"])
        #expect(result.servers[1].scope == .project(path: "/p/web"))
        #expect(result.servers[1].packageSource == .localProgram(path: "/p/web/a.js"))
        #expect(result.servers[1].isEnabled == true)   // nicht in `disabledMcpServers` = aktiv
        #expect(result.servers[2].isEnabled == false)
        #expect(result.projects.map(\.path) == ["/p/web", "/p/leer"])
        // Ältere Claude-Code-Versionen schrieben `enableAllProjectMcpServers` ins Projektobjekt: Projekt-Freigabe.
        #expect(result.approvals.map(\.setting) == ["enableAllProjectMcpServers"])
        #expect(result.approvals.first?.scope == .project(path: "/p/web"))
        #expect(result.approvals.first?.configPath == "/h/.claude.json")
        #expect(result.approvals.first?.message == "Alle MCP-Server aus .mcp.json-Dateien werden ohne Rückfrage freigegeben")
    }

    /// Server-Namen wie `env` oder `headers` sind Namen, keine geschwärzten Felder – sonst bliebe ein solcher Server
    /// unsichtbar. Das `env` im Server-Objekt bleibt geschwärzt.
    @Test func serversNamedLikeRedactedKeysAreExtracted() throws {
        let desktop = try extract("claudeDesktop", #"{"mcpServers": {"env": {"command": "/tmp/x", "env": {"K": "GEHEIM"}}}}"#)
        let server = try #require(desktop.servers.first)
        #expect(server.name == "env")
        #expect(server.transport == .local(command: "/tmp/x", arguments: []))
        #expect(server.environmentKeys == ["K"])
        #expect(!String(describing: desktop).contains("GEHEIM"))

        let codex = try extract("codex", """
        [mcp_servers.env]
        command = "/tmp/x"

        [mcp_servers.env.env]
        K = "GEHEIM"

        [mcp_servers.bearer_token]
        url = "https://mcp.example.com/sse"
        bearer_token = "GEHEIM"
        """, .toml)
        #expect(codex.servers.map(\.name) == ["env", "bearer_token"])
        #expect(codex.servers.first?.transport == .local(command: "/tmp/x", arguments: []))
        #expect(codex.servers.first?.environmentKeys == ["K"])
        #expect(!String(describing: codex).contains("GEHEIM"))

        let code = try extract("claudeCode", #"""
        {"projects": {"/p/web": {"mcpServers": {"headers": {"url": "https://mcp.example.com/sse",
                                                            "headers": {"Authorization": "GEHEIM"}}}}},
         "env": {"T": "GEHEIM"}}
        """#)
        #expect(code.servers.map(\.name) == ["headers"])
        #expect(code.servers.first?.scope == .project(path: "/p/web"))
        #expect(code.servers.first?.headerKeys == ["Authorization"])
        #expect(!String(describing: code).contains("GEHEIM"))
    }

    /// Außerhalb der Server-Listen bleibt jeder geschwärzte Schlüssel geschwärzt (`~/.claude/settings.json`: `env`).
    @Test func redactedKeysOutsideServerListsStayRedacted() throws {
        let tool = try #require(catalog.tool(id: "claudeCode"))
        let settings = try document(#"{"env": {"TOKEN": "GEHEIM"}, "mcpServers": {"env": "GEHEIM"}}"#,
                                    redaction: tool.files[1].redaction)
        #expect(settings.value(at: ["env", "TOKEN"]) == .redacted)
        #expect(settings.value(at: ["mcpServers", "env"]) == .redacted)
        #expect(!String(describing: settings).contains("GEHEIM"))
    }

    /// `/p/web` und `/p/web/` sind dasselbe Projekt: einmal, ohne abschließenden `/`.
    @Test func duplicateProjectPathsWithTrailingSlashCountOnce() throws {
        let result = try extract("claudeCode", #"""
        {"projects": {"/p/web": {"mcpServers": {"a": {"command": "a"}}},
                      "/p/web/": {"mcpServers": {"a": {"command": "a"}}},
                      "/p/neu/": {"mcpServers": {"b": {"command": "b"}}}}}
        """#)
        #expect(result.projects.map(\.path) == ["/p/web", "/p/neu"])
        #expect(result.servers.map(\.scope) == [.project(path: "/p/web"), .project(path: "/p/neu")])
        #expect(result.problems.isEmpty)
    }

    @Test func claudeCodeSettingsEnableAllProjectServers() throws {
        let result = try extract("claudeCode", file: 1, #"{"enableAllProjectMcpServers": true}"#)
        #expect(result.approvals.map(\.setting) == ["enableAllProjectMcpServers"])
        #expect(result.approvals.first?.value == "true")
        #expect(result.approvals.first?.scope == .user)
        #expect(result.approvals.first?.configPath == "/h/.claude/settings.json")
        let off = try extract("claudeCode", file: 1, #"{"enableAllProjectMcpServers": false}"#)
        #expect(off.approvals.isEmpty)
    }

    @Test func projectFileUsesApprovalLists() throws {
        let tool = try #require(catalog.tool(id: "claudeCode"))
        let registry = try document(#"{"projects": {"/p": {"enabledMcpjsonServers": ["a"], "disabledMcpjsonServers": ["b"]}}}"#)
        let project = try #require(AgentConfigExtractor.extract(registry, file: tool.files[0], tool: tool, configPath: "/h/.claude.json").projects.first)
        let projectFile = try #require(tool.files[0].projects?.projectFile)
        let result = AgentConfigExtractor.extractProjectFile(
            try document(#"{"mcpServers": {"a": {"command": "a"}, "b": {"command": "b"}, "c": {"command": "c"}}}"#),
            projectFile: projectFile, projectPath: project.path,
            approvalState: ProjectApprovalState().overlaid(with: project.settings, paths: projectFile), tool: tool,
            configPath: "/p/.mcp.json",
            registryPath: "/h/.claude.json", shape: tool.files[0].shape
        )
        #expect(result.servers.map(\.isEnabled) == [true, false, nil])   // nil = Freigabe ausstehend
        #expect(result.servers.allSatisfy { $0.registryPath == "/h/.claude.json" && $0.scope == .project(path: "/p") })
    }

    @Test func codexTomlWithEnabledFlagAndApprovals() throws {
        let result = try extract("codex", """
        approval_policy = "never"
        sandbox_mode = "workspace-write"
        [mcp_servers.chat]
        command = "/usr/local/bin/chat"
        enabled = false
        [mcp_servers.chat.env]
        CHAT_TOKEN = "GEHEIM"
        """, .toml)
        let server = try #require(result.servers.first)
        #expect(server.isEnabled == false)
        #expect(server.environmentKeys == ["CHAT_TOKEN"])
        #expect(server.packageSource == .localProgram(path: "/usr/local/bin/chat"))
        #expect(result.approvals.map(\.setting) == ["approval_policy"])
        #expect(result.approvals.first?.value == "never")
    }

    @Test func missingSwitchCountsAsEnabled() throws {
        let windsurf = try extract("windsurf", #"{"mcpServers": {"w": {"command": "w"}, "d": {"command": "d", "disabled": true}}}"#)
        #expect(windsurf.servers.map(\.isEnabled) == [true, false])
        let codex = try extract("codex", """
        [mcp_servers.c]
        command = "c"
        """, .toml)
        #expect(codex.servers.map(\.isEnabled) == [true])
    }

    @Test func zedNestedCommand() throws {
        let result = try extract("zed", #"{"context_servers": {"z": {"command": {"path": "/bin/z", "args": ["--x"], "env": {"K": "v"}}}}}"#, .jsonc)
        #expect(result.servers.first?.transport == .local(command: "/bin/z", arguments: ["--x"]))
        #expect(result.servers.first?.environmentKeys == ["K"])
    }

    @Test func geminiTrustIsServerApproval() throws {
        let result = try extract("gemini", #"{"mcpServers": {"t": {"command": "t", "trust": true}}}"#)
        #expect(result.approvals.map(\.setting) == ["mcpServers.t.trust"])
    }

    @Test func vscodeDottedTopLevelKeys() throws {
        let result = try extract("vscode", file: 1, #"{"chat.tools.autoApprove": true, "mcp.servers": {"s": {"command": "s"}}}"#, .jsonc)
        #expect(result.servers.map(\.name) == ["s"])
        #expect(result.approvals.map(\.value) == ["true"])
    }

    @Test func malformedEntriesBecomeProblemsWithoutValues() throws {
        let result = try extract("cursor", #"{"mcpServers": {"a": "GEHEIM", "b": {"env": {"X": "GEHEIM"}}, "c": {"command": "c"}}}"#)
        #expect(result.servers.map(\.name) == ["c"])
        #expect(result.problems == ["mcp.json: Eintrag „a“ ist kein Objekt", "mcp.json: Eintrag „b“ hat weder Befehl noch URL"])
        #expect(!result.problems.joined().contains("GEHEIM"))
    }

    @Test func secretValuesNeverReachEntries() throws {
        let result = try extract("claudeDesktop", #"{"mcpServers": {"p": {"command": "x", "args": ["--token", "GEHEIM", "postgresql://u:GEHEIM@h/db"], "env": {"A_KEY": "GEHEIM"}}}}"#)
        let encoded = String(decoding: try JSONEncoder().encode(result.servers), as: UTF8.self)
        #expect(!encoded.contains("GEHEIM"))
        #expect(result.servers.first?.hasSecretInArguments == true)
    }
    /// Regression (#137, Codex Runde 3): Ein Shell-Skript mit Webhook-Token oder Zeilenfortsetzung erreicht den
    /// serialisierten Eintrag nur als `•••`.
    @Test(arguments: [
        #"curl https://hooks.slack.com/services/T000/B000/GEHEIM"#,
        #"run --to\\\nken GEHEIM"#,
    ])
    func hiddenShellScriptsNeverReachTheTransport(script: String) throws {
        let result = try extract("claudeDesktop", #"{"mcpServers": {"s": {"command": "sh", "args": ["-c", ""# + script + #""]}}}"#)
        let server = try #require(result.servers.first)
        #expect(server.transport == .local(command: "sh", arguments: ["-c", "•••"]))
        #expect(!String(decoding: try JSONEncoder().encode(result.servers), as: UTF8.self).contains("GEHEIM"))
    }

    /// Regression (#137, Codex Runde 5): Hinter einer Shell gilt jedes Argument als mögliches Skript – unabhängig von
    /// Optionsclustern mit Ziffern, `+o` oder einer Skriptdatei.
    @Test(arguments: [
        #"["-c5", "true&&API_TOKEN=GEHEIM /usr/bin/printenv API_TOKEN"]"#,
        #"["-5c", "true&&API_TOKEN=GEHEIM /usr/bin/printenv API_TOKEN"]"#,
        #"["+o", "posix", "-c", "true&&API_TOKEN=GEHEIM run"]"#,
        #"["script.sh", "--token", "GEHEIM"]"#,
    ])
    func shellArgumentsNeverReachTheTransportInPlaintext(arguments: String) throws {
        let result = try extract("claudeDesktop", #"{"mcpServers": {"s": {"command": "zsh", "args": "# + arguments + "}}}")
        let server = try #require(result.servers.first)
        #expect(server.transport.commandLine?.contains("GEHEIM") == false)
        #expect(!String(decoding: try JSONEncoder().encode(result.servers), as: UTF8.self).contains("GEHEIM"))
    }

    /// Regression (Codex-Review 2026.10.6, #155): Ein Passwort, das mit `-` beginnt, erreicht weder Transport noch
    /// serialisierten Snapshot im Klartext, und der Geheimnis-Hinweis steht.
    @Test func passwordStartingWithADashNeverReachesTheTransport() throws {
        let result = try extract("claudeDesktop", #"{"mcpServers": {"db": {"command": "db-mcp", "args": ["--password", "-GEHEIM123"]}}}"#)
        let server = try #require(result.servers.first)
        #expect(server.transport == .local(command: "db-mcp", arguments: ["--password", "•••"]))
        #expect(server.hasSecretInArguments)
        #expect(!String(decoding: try JSONEncoder().encode(result.servers), as: UTF8.self).contains("GEHEIM"))
    }

    // MARK: Review Task 8

    @Test func commandIsMaskedWithoutSplitting() throws {
        let result = try extract("claudeDesktop", #"""
        {"mcpServers": {"sh": {"command": "sh -c 'export API_TOKEN=GEHEIM123; run'", "args": ["--x"]},
                        "tok": {"command": "ghp_ABCDEFGHIJ1234567890xx"}}}
        """#)
        #expect(result.servers.count == 2)
        let encoded = String(decoding: try JSONEncoder().encode(result.servers), as: UTF8.self)
        #expect(!encoded.contains("GEHEIM"))
        #expect(!encoded.contains("ghp_ABCDEFGHIJ1234567890xx"))
        #expect(result.servers.map(\.hasSecretInArguments) == [true, true])
        guard case .local(let command, let arguments) = try #require(result.servers.first).transport else {
            Issue.record("kein lokaler Server")
            return
        }
        #expect(command.hasPrefix("sh -c 'export API_TOKEN="))
        #expect(arguments == ["--x"])
    }

    @Test func duplicateNamesInOneFileKeepFirst() throws {
        let result = try extract("vscode", file: 1, #"""
        {"mcp": {"servers": {"s": {"command": "erst"}}}, "mcp.servers": {"s": {"command": "zweit"}}}
        """#, .jsonc)
        #expect(result.servers.map(\.transport) == [.local(command: "erst", arguments: [])])
        #expect(result.problems == ["settings.json: Eintrag „s“ mehrfach"])
    }

    @Test func sameNameInDifferentProjectsIsNoDuplicate() throws {
        let result = try extract("claudeCode", #"""
        {"mcpServers": {"s": {"command": "s"}}, "projects": {"/p/a": {"mcpServers": {"s": {"command": "s"}}}}}
        """#)
        #expect(result.servers.count == 2)
        #expect(result.problems.isEmpty)
    }

    @Test func zedExtensionServersAreSkippedSilently() throws {
        let result = try extract("zed", #"{"context_servers": {"gh": {"source": "extension", "settings": {}}}}"#, .jsonc)
        #expect(result.servers.isEmpty)
        #expect(result.problems.isEmpty)
    }

    @Test func problemsNameFileProjectAndShortenedName() throws {
        let long = String(repeating: "x", count: 80)
        let result = try extract("claudeCode", #"""
        {"projects": {"/p/web": {"mcpServers": {"a\n\t b": 1, "\#(long)": 2}}, "/p/kaputt": 3}}
        """#)
        #expect(result.problems == [
            ".claude.json (Projekt web): Eintrag „a b“ ist kein Objekt",
            ".claude.json (Projekt web): Eintrag „\(String(repeating: "x", count: 59))…“ ist kein Objekt",
            ".claude.json: Projekt „/p/kaputt“ ist kein Objekt",
        ])
        #expect(result.projects.map(\.path) == ["/p/web"])
    }

    @Test func serverContainerThatIsNoObjectIsAProblem() throws {
        let result = try extract("cursor", #"{"mcpServers": ["a"]}"#)
        #expect(result.servers.isEmpty)
        #expect(result.problems == ["mcp.json: „mcpServers“ ist kein Objekt"])
    }

    @Test func blankStringsAreIgnored() throws {
        let result = try extract("cursor", #"{"mcpServers": {"a": {"command": "  ", "url": "https://h.example/mcp"}, "b": {"command": ""}}}"#)
        #expect(result.servers.map(\.transport) == [.remote(url: "https://h.example/mcp", kind: nil)])
        #expect(result.problems == ["mcp.json: Eintrag „b“ hat weder Befehl noch URL"])
    }

    @Test func remoteTypePrefersURLOverCommand() throws {
        let result = try extract("cursor", #"""
        {"mcpServers": {"r": {"type": "sse", "command": "x", "url": "https://h.example/sse"},
                        "l": {"type": "stdio", "command": "x", "url": "https://h.example/sse"}}}
        """#)
        #expect(result.servers.map(\.transport) == [
            .remote(url: "https://h.example/sse", kind: "sse"), .local(command: "x", arguments: []),
        ])
    }

    @Test func nonScalarArgumentsAreDropped() throws {
        let result = try extract("cursor", #"{"mcpServers": {"a": {"command": "a", "args": ["x", null, {"k": 1}, [2], 3, true]}}}"#)
        #expect(result.servers.first?.transport == .local(command: "a", arguments: ["x", "3", "true"]))
    }

    @Test func managedFileHasSystemScope() throws {
        let result = try extract("claudeCode", file: 2, #"{"mcpServers": {"m": {"command": "m"}}}"#)
        #expect(result.servers.first?.scope == .system)
        #expect(result.servers.first?.configPath == "/Library/Application Support/ClaudeCode/managed-mcp.json")
    }

    @Test func codexHTTPHeadersBecomeHeaderKeys() throws {
        let result = try extract("codex", """
        [mcp_servers.r]
        url = "https://h.example/mcp"
        [mcp_servers.r.http_headers]
        Authorization = "GEHEIM"
        """, .toml)
        #expect(result.servers.first?.headerKeys == ["Authorization"])
        #expect(result.servers.first?.transport == .remote(url: "https://h.example/mcp", kind: nil))
    }

    @Test func alternativeURLKeys() throws {
        let result = try extract("gemini", #"{"mcpServers": {"a": {"serverUrl": "https://a.example/"}, "b": {"httpUrl": "https://b.example/"}}}"#)
        #expect(result.servers.map(\.packageSource) == [.remote(host: "a.example"), .remote(host: "b.example")])
    }

    @Test func serverApprovalInProjectScope() throws {
        let claudeCode = try #require(catalog.tool(id: "claudeCode"))
        let gemini = try #require(catalog.tool(id: "gemini"))
        let projectFile = try #require(claudeCode.files[0].projects?.projectFile)
        let result = AgentConfigExtractor.extractProjectFile(
            try document(#"{"mcpServers": {"t": {"command": "t", "trust": true}}}"#),
            projectFile: projectFile, projectPath: "/p/web", approvalState: ProjectApprovalState(), tool: claudeCode,
            configPath: "/p/web/.mcp.json",
            registryPath: "/h/.claude.json", shape: gemini.files[0].shape
        )
        let approval = try #require(result.approvals.first)
        #expect(approval.scope == .project(path: "/p/web"))
        #expect(approval.setting == "mcpServers.t.trust")
        #expect(approval.configPath == "/p/web/.mcp.json")
    }
    // MARK: Task 7b – Projekt-Einstellungen

    private var claudeCodeLocation: ProjectLocation {
        get throws { try #require(catalog.tool(id: "claudeCode")?.files[0].projects) }
    }

    @Test func approvalStateUnitesSources() throws {
        let location = try claudeCodeLocation
        let projectFile = try #require(location.projectFile)
        let shared = try #require(location.settingsFiles.first)
        let local = try #require(location.settingsFiles.last)
        let state = ProjectApprovalState()
            .overlaid(with: try document(#"{"enabledMcpjsonServers": ["obj"], "disabledMcpjsonServers": ["x"]}"#), paths: projectFile)
            .overlaid(with: try document(#"{"enabledMcpjsonServers": ["q"], "disabledMcpjsonServers": []}"#), paths: shared)
            .overlaid(with: try document(#"{"enabledMcpjsonServers": ["p", "x", "aus"], "disabledMcpjsonServers": ["aus"]}"#), paths: local)
        #expect(state.isEnabled("p") == true)
        #expect(state.isEnabled("q") == true)          // geteilt + lokal: beide freigegeben
        #expect(state.isEnabled("obj") == true)
        #expect(state.isEnabled("x") == false)         // Ablehnung aus dem Projektobjekt bleibt, schlägt Freigabe
        #expect(state.isEnabled("aus") == false)
        #expect(state.isEnabled("neu") == nil)
    }

    @Test func approvalStateKeepsListsAbsentInLaterSources() throws {
        let location = try claudeCodeLocation
        let local = try #require(location.settingsFiles.last)
        let state = ProjectApprovalState()
            .overlaid(with: try document(#"{"enabledMcpjsonServers": ["a"]}"#), paths: try #require(location.projectFile))
            .overlaid(with: try document(#"{"permissions": {}, "enabledMcpjsonServers": []}"#), paths: local)
        #expect(state.isEnabled("a") == true)
    }

    @Test func enableAllFromAnySourceWinsButNotOverRejection() throws {
        let location = try claudeCodeLocation
        let shared = try #require(location.settingsFiles.first)
        let local = try #require(location.settingsFiles.last)
        let state = ProjectApprovalState()
            .overlaid(with: try document(#"{"enableAllProjectMcpServers": true, "disabledMcpjsonServers": ["b"]}"#), paths: shared)
            .overlaid(with: try document(#"{"enableAllProjectMcpServers": false}"#), paths: local)
        #expect(state.isEnabled("a") == true)
        #expect(state.isEnabled("b") == false)
        #expect(ProjectApprovalState().isEnabled("a") == nil)
    }

    @Test func projectSettingsYieldProjectScopedApprovals() throws {
        let tool = try #require(catalog.tool(id: "claudeCode"))
        let settingsFile = try #require(try claudeCodeLocation.settingsFiles.first)
        let result = AgentConfigExtractor.extractProjectSettings(
            try document(#"{"permissions": {"defaultMode": "bypassPermissions"}, "mcpServers": {"s": {"command": "s"}}}"#),
            settingsFile: settingsFile, projectPath: "/p/web", tool: tool, configPath: "/p/web/.claude/settings.json",
            registryPath: "/h/.claude.json"
        )
        #expect(result.servers.isEmpty)
        let approval = try #require(result.approvals.first)
        #expect(result.approvals.count == 1)
        #expect(approval.setting == "permissions.defaultMode")
        #expect(approval.scope == .project(path: "/p/web"))
        #expect(approval.configPath == "/p/web/.claude/settings.json")
        #expect(approval.registryPath == "/h/.claude.json")
    }

    @Test func zedSettingsOnlyEntriesAreSkippedSilently() throws {
        let result = try extract("zed", #"{"context_servers": {"a": {"settings": {"k": 1}}, "b": {"settings": {}, "x": 1}}}"#, .jsonc)
        #expect(result.servers.isEmpty)
        #expect(result.problems == ["settings.json: Eintrag „b“ hat weder Befehl noch URL"])
    }

    @Test func longProjectLabelIsShortenedInProblems() throws {
        let folder = String(repeating: "o", count: 80)
        let result = try extract("claudeCode", #"{"projects": {"/p/\#(folder)": {"mcpServers": {"a": 1}}}}"#)
        let label = AgentConfigExtractor.displayName("Projekt " + folder)
        #expect(result.problems == [".claude.json (\(label)): Eintrag „a“ ist kein Objekt"])
        #expect(label.count == AgentConfigExtractor.problemNameLength)
    }
    @Test func codexBearerTokenCountsAsSecret() throws {
        let result = try extract("codex", """
        [mcp_servers.alt]
        url = "https://h.example/mcp"
        bearer_token = "GEHEIM"
        [mcp_servers.neu]
        url = "https://h.example/mcp"
        bearer_token_env_var = "MY_TOKEN"
        """, .toml)
        #expect(result.servers.map(\.hasSecretInArguments) == [true, false])
        let encoded = String(decoding: try JSONEncoder().encode(result.servers), as: UTF8.self)
        #expect(!encoded.contains("GEHEIM"))
    }
}
