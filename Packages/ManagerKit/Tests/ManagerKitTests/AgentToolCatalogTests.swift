import Testing
@testable import ManagerKit

@Suite struct AgentToolCatalogTests {
    let catalog = AgentToolCatalog.standard

    @Test func toolIDsAreUniqueAndKnown() {
        #expect(catalog.tools.map(\.id) == ["claudeDesktop", "claudeCode", "cursor", "codex", "windsurf", "vscode", "vscodeInsiders", "zed", "gemini"])
    }

    @Test func expandsHomeOnly() {
        let file = AgentConfigFile(path: "~/.cursor/mcp.json", syntax: .json, serverPaths: [["mcpServers"]])
        #expect(file.expandedPath(home: "/Users/a") == "/Users/a/.cursor/mcp.json")
        let system = AgentConfigFile(path: "/Library/x.json", syntax: .json, scope: .system, serverPaths: [])
        #expect(system.expandedPath(home: "/Users/a") == "/Library/x.json")
    }

    @Test func expandedPathHasNoDoubleSlash() {
        let file = AgentConfigFile(path: "~/.cursor/mcp.json", syntax: .json, serverPaths: [["mcpServers"]])
        #expect(file.expandedPath(home: "/Users/a/") == "/Users/a/.cursor/mcp.json")
        #expect(file.expandedPath(home: "/Users/a//") == "/Users/a/.cursor/mcp.json")
        #expect(file.expandedPath(home: "/") == "/.cursor/mcp.json")
    }

    @Test func staticPathsCoverAllFiles() {
        let paths = catalog.staticPaths(home: "/Users/a")
        #expect(paths.contains("/Users/a/.claude.json"))
        #expect(paths.contains("/Users/a/.codex/config.toml"))
        #expect(paths.contains("/Library/Application Support/ClaudeCode/managed-mcp.json"))
        #expect(Set(paths).count == paths.count)
    }

    @Test func redactedKeysCoverAllSecretPaths() {
        for tool in catalog.tools {
            for file in tool.files {
                let paths = file.shape.environmentPaths + file.shape.headerPaths
                #expect(paths.allSatisfy { $0.last.map(ServerShape.redactedKeys.contains) == true }, "\(tool.id) \(file.path)")
            }
        }
    }

    @Test func redactedKeysIncludeSpecialCredentialKeys() {
        #expect(ServerShape.redactedKeys.isSuperset(of: ["env", "headers", "http_headers", "env_http_headers", "bearer_token"]))
    }

    @Test func toolLookup() {
        #expect(catalog.tool(id: "codex")?.displayName == "Codex")
        #expect(catalog.tool(id: "nope") == nil)
    }

    @Test func userCatalogHasNoSystemFiles() {
        let files = TestData.userCatalog.tools.flatMap(\.files)
        #expect(!files.isEmpty)
        #expect(files.allSatisfy { $0.scope == .user })
        #expect(TestData.userCatalog.tools.map(\.id) == catalog.tools.map(\.id))
        #expect(catalog.tools.flatMap(\.files).contains { $0.scope == .system })
    }

    /// Jede Freigabe-Regel eines Tools als `Einstellung=Auslöser`, egal ob dateiweit, je Server oder je Projekt.
    private func approvalSettings(_ toolID: String) -> Set<String> {
        let rules = (catalog.tool(id: toolID)?.files ?? []).flatMap { file in
            file.autoApprovals + file.shape.serverApprovals + (file.projects?.autoApprovals ?? [])
        }
        return Set(rules.flatMap { rule in rule.triggers.map { rule.path.joined(separator: ".") + "=" + $0 } })
    }

    @Test func approvalRulesAreFixed() {
        #expect(approvalSettings("claudeCode") == [
            "permissions.defaultMode=bypassPermissions", "skipDangerousModePermissionPrompt=true",
            "enableAllProjectMcpServers=true",
        ])
        #expect(approvalSettings("codex") == ["approval_policy=never", "sandbox_mode=danger-full-access"])
        #expect(approvalSettings("vscode") == ["chat.tools.autoApprove=true", "chat.tools.global.autoApprove=true"])
        #expect(approvalSettings("vscodeInsiders") == approvalSettings("vscode"))
        #expect(approvalSettings("zed") == ["agent.always_allow_tool_actions=true"])
        #expect(approvalSettings("gemini") == ["trust=true", "tools.autoAccept=true", "autoAccept=true"])
        for toolID in ["claudeDesktop", "cursor", "windsurf"] {
            #expect(approvalSettings(toolID).isEmpty, "\(toolID)")
        }
    }

    @Test func enableAllProjectServersIsSettingsFileRule() throws {
        let claudeCode = try #require(catalog.tool(id: "claudeCode"))
        let registry = try #require(claudeCode.files.first { $0.path == "~/.claude.json" })
        let settings = try #require(claudeCode.files.first { $0.path == "~/.claude/settings.json" })
        // Ältere Claude-Code-Versionen schrieben den Schalter ins Projektobjekt – dort dieselbe Regel.
        #expect(registry.projects?.autoApprovals == settings.autoApprovals.filter { $0.path == ["enableAllProjectMcpServers"] })
        #expect(settings.autoApprovals.contains {
            $0.path == ["enableAllProjectMcpServers"] && $0.triggers == ["true"]
                && $0.message == "Alle MCP-Server aus .mcp.json-Dateien werden ohne Rückfrage freigegeben"
        })
    }

    @Test func geminiTrustIsPerServerApproval() throws {
        let gemini = try #require(catalog.tool(id: "gemini"))
        #expect(gemini.files.count == 2)
        for file in gemini.files {
            #expect(file.shape.serverApprovals.map(\.path) == [["trust"]], "\(file.path)")
            #expect(file.autoApprovals.map(\.path) == [["tools", "autoAccept"], ["autoAccept"]], "\(file.path)")
        }
    }

    @Test func managedFilesShareRulesWithUserFiles() throws {
        let claudeCode = try #require(catalog.tool(id: "claudeCode"))
        let userSettings = try #require(claudeCode.files.first { $0.path == "~/.claude/settings.json" })
        let managedSettings = try #require(claudeCode.files.first { $0.path == "/Library/Application Support/ClaudeCode/managed-settings.json" })
        #expect(managedSettings.scope == .system)
        #expect(managedSettings.serverPaths.isEmpty)
        #expect(managedSettings.autoApprovals == userSettings.autoApprovals)

        let gemini = try #require(catalog.tool(id: "gemini"))
        let userFile = try #require(gemini.files.first { $0.scope == .user })
        let managedFile = try #require(gemini.files.first { $0.path == "/Library/Application Support/GeminiCli/settings.json" })
        #expect(managedFile.scope == .system)
        #expect(managedFile.syntax == userFile.syntax)
        #expect(managedFile.serverPaths == userFile.serverPaths)
        #expect(managedFile.autoApprovals == userFile.autoApprovals)
        #expect(managedFile.shape == userFile.shape)
    }

    @Test func zedAgentApprovalIsNestedSetting() throws {
        let zed = try #require(catalog.tool(id: "zed"))
        let rule = try #require(zed.files.flatMap(\.autoApprovals).first)
        #expect(rule.path == ["agent", "always_allow_tool_actions"])
        #expect(rule.triggers == ["true"])
        #expect(rule.message == "Werkzeugaufrufe des Agenten laufen ohne Rückfrage")
    }

    @Test func vscodeInsidersMirrorsVSCodeInOwnDirectory() throws {
        let stable = try #require(catalog.tool(id: "vscode"))
        let insiders = try #require(catalog.tool(id: "vscodeInsiders"))
        #expect(insiders.displayName == "VS Code Insiders")
        #expect(insiders.files.map(\.path) == [
            "~/Library/Application Support/Code - Insiders/User/mcp.json",
            "~/Library/Application Support/Code - Insiders/User/settings.json",
        ])
        #expect(stable.files.map(\.path) == [
            "~/Library/Application Support/Code/User/mcp.json",
            "~/Library/Application Support/Code/User/settings.json",
        ])
        for (stableFile, insidersFile) in zip(stable.files, insiders.files) {
            #expect(insidersFile.syntax == stableFile.syntax)
            #expect(insidersFile.serverPaths == stableFile.serverPaths)
            #expect(insidersFile.autoApprovals == stableFile.autoApprovals)
            #expect(insidersFile.shape == stableFile.shape)
        }
    }

    @Test func systemFilesAreExactlyTheAbsolutePaths() {
        let files = catalog.tools.flatMap(\.files)
        let systemPaths = files.filter { $0.scope == .system }.map(\.path)
        #expect(Set(systemPaths) == [
            "/Library/Application Support/ClaudeCode/managed-mcp.json",
            "/Library/Application Support/ClaudeCode/managed-settings.json",
            "/Library/Application Support/GeminiCli/settings.json",
        ])
        #expect(files.filter { $0.scope == .system }.allSatisfy { $0.path.hasPrefix("/") })
        #expect(files.filter { $0.scope == .user }.allSatisfy { $0.path.hasPrefix("~/") })
        #expect(files.filter { $0.path.hasPrefix("/") }.allSatisfy { $0.scope == .system })
    }

    @Test func everyFileReadsServersOrApprovals() {
        for tool in catalog.tools {
            for file in tool.files {
                let hasServers = !file.serverPaths.isEmpty || file.projects != nil
                #expect(hasServers || !file.autoApprovals.isEmpty, "\(tool.id) \(file.path)")
            }
        }
    }

    @Test func onlyClaudeCodeRegistersProjects() throws {
        let withProjects = catalog.tools.flatMap { tool in tool.files.filter { $0.projects != nil }.map { (tool.id, $0) } }
        #expect(withProjects.map(\.0) == ["claudeCode"])
        let location = try #require(withProjects.first?.1.projects)
        #expect(withProjects.first?.1.path == "~/.claude.json")
        #expect(location.projectsPath == ["projects"])
        #expect(location.serverPaths == [["mcpServers"]])
        #expect(location.disabledNamesPath == ["disabledMcpServers"])
        #expect(location.autoApprovals.map(\.path) == [["enableAllProjectMcpServers"]])
        let projectFile = try #require(location.projectFile)
        #expect(projectFile.relativePath == ".mcp.json")
        #expect(projectFile.syntax == .json)
        #expect(projectFile.serverPaths == [["mcpServers"]])
        #expect(projectFile.enabledNamesPath == ["enabledMcpjsonServers"])
        #expect(projectFile.disabledNamesPath == ["disabledMcpjsonServers"])
        #expect(projectFile.enableAllPath == ["enableAllProjectMcpServers"])
        #expect(location.settingsFiles.map(\.relativePath) == [".claude/settings.json", ".claude/settings.local.json"])
        let globalLists = try #require(catalog.tool(id: "claudeCode")).files.filter { $0.projectServerApprovals != nil }
        #expect(globalLists.map(\.path) == ["~/.claude/settings.json", "/Library/Application Support/ClaudeCode/managed-settings.json"])
        for file in globalLists {
            #expect(file.projectServerApprovals == ProjectServerApprovalLists(
                enabledNamesPath: ["enabledMcpjsonServers"], disabledNamesPath: ["disabledMcpjsonServers"],
                enableAllPath: ["enableAllProjectMcpServers"]
            ))
        }
        #expect(catalog.tools.filter { $0.id != "claudeCode" }.flatMap(\.files).allSatisfy { $0.projectServerApprovals == nil })
        let userSettings = try #require(catalog.tool(id: "claudeCode")?.files.first { $0.path == "~/.claude/settings.json" })
        for settingsFile in location.settingsFiles {
            #expect(settingsFile.syntax == .json)
            #expect(settingsFile.autoApprovals == userSettings.autoApprovals)
            #expect(settingsFile.enabledNamesPath == ["enabledMcpjsonServers"])
            #expect(settingsFile.disabledNamesPath == ["disabledMcpjsonServers"])
            #expect(settingsFile.enableAllPath == ["enableAllProjectMcpServers"])
        }
    }

    @Test func toolNamesTextListsAllToolsInCatalogOrder() {
        #expect(catalog.toolNamesText == "Claude Desktop, Claude Code, Cursor, Codex, Windsurf, VS Code, VS Code Insiders, Zed und Gemini CLI")
        let one = AgentToolCatalog(tools: [AgentToolDefinition(id: "a", displayName: "A", starter: .terminal, files: [])])
        #expect(one.toolNamesText == "A")
        #expect(AgentToolCatalog(tools: []).toolNamesText == "")
    }

    @Test func startersFollowToolKind() {
        let desktopApps: [String: [String]] = [
            "claudeDesktop": ["com.anthropic.claudefordesktop"],
            "cursor": ["com.todesktop.230313mzl4w4u92"],
            "windsurf": ["com.exafunction.windsurf"],
            "vscode": ["com.microsoft.VSCode"],
            "vscodeInsiders": ["com.microsoft.VSCodeInsiders"],
            "zed": ["dev.zed.Zed"],
        ]
        for (toolID, bundleIDs) in desktopApps {
            #expect(catalog.tool(id: toolID)?.starter == .app(bundleIDs: bundleIDs), "\(toolID)")
        }
        for toolID in ["claudeCode", "codex", "gemini"] {
            #expect(catalog.tool(id: toolID)?.starter == .terminal, "\(toolID)")
        }
        #expect(Set(desktopApps.keys).union(["claudeCode", "codex", "gemini"]) == Set(catalog.tools.map(\.id)))
    }

    @Test func terminalHostsCoverTerminalsAndEditors() {
        let expected: Set<String> = [
            "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
            "com.github.wez.wezterm", "net.kovidgoyal.kitty", "org.alacritty",
            "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.exafunction.windsurf",
        ]
        #expect(Set(TerminalHosts.bundleIDs) == expected)
        #expect(Set(TerminalHosts.bundleIDs).count == TerminalHosts.bundleIDs.count)
    }

    /// Jeder statische Pfad gehört genau einem Tool: Die Inhalts-Stempel (`AgentConfigSource.contentStamps`) sind
    /// nach Pfad geschlüsselt und rechnen mit dem ersten Tool.
    @Test func noTwoToolsShareAStaticPath() {
        let paths = catalog.tools.flatMap { tool in Set(tool.files.map { $0.expandedPath(home: "/Users/a") }) }
        #expect(Set(paths).count == paths.count)
    }
}
