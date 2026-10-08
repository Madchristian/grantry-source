extension AgentToolCatalog {
    /// Stufe-1-Katalog (Spec §2). Pfade auf dem Nutzer-Mac am 2026-10-05 geprüft, soweit vorhanden.
    public static let standard = AgentToolCatalog(tools: [
        AgentToolDefinition(
            id: "claudeDesktop", displayName: "Claude Desktop", starter: .app(bundleIDs: ["com.anthropic.claudefordesktop"]),
            files: [AgentConfigFile(path: "~/Library/Application Support/Claude/claude_desktop_config.json", syntax: .json,
                                    serverPaths: [["mcpServers"]])]
        ),
        AgentToolDefinition(
            id: "claudeCode", displayName: "Claude Code", starter: .terminal,
            files: [
                AgentConfigFile(
                    path: "~/.claude.json", syntax: .json, serverPaths: [["mcpServers"]],
                    projects: ProjectLocation(
                        projectsPath: ["projects"], serverPaths: [["mcpServers"]], disabledNamesPath: ["disabledMcpServers"],
                        // Ältere Claude-Code-Versionen schrieben den Schalter ins Projektobjekt.
                        autoApprovals: [enableAllProjectServers],
                        projectFile: ProjectFile(
                            relativePath: ".mcp.json", syntax: .json, serverPaths: [["mcpServers"]],
                            enabledNamesPath: ["enabledMcpjsonServers"], disabledNamesPath: ["disabledMcpjsonServers"],
                            enableAllPath: ["enableAllProjectMcpServers"]
                        ),
                        settingsFiles: [".claude/settings.json", ".claude/settings.local.json"].map { relativePath in
                            ProjectSettingsFile(
                                relativePath: relativePath, syntax: .json, autoApprovals: claudeCodeApprovals,
                                enabledNamesPath: claudeCodeServerApprovals.enabledNamesPath,
                                disabledNamesPath: claudeCodeServerApprovals.disabledNamesPath,
                                enableAllPath: claudeCodeServerApprovals.enableAllPath
                            )
                        }
                    ),
                    isRewrittenByTool: true
                ),
                AgentConfigFile(path: "~/.claude/settings.json", syntax: .json, serverPaths: [],
                                autoApprovals: claudeCodeApprovals, projectServerApprovals: claudeCodeServerApprovals),
                AgentConfigFile(path: "/Library/Application Support/ClaudeCode/managed-mcp.json", syntax: .json,
                                scope: .system, serverPaths: [["mcpServers"]]),
                AgentConfigFile(path: "/Library/Application Support/ClaudeCode/managed-settings.json", syntax: .json,
                                scope: .system, serverPaths: [], autoApprovals: claudeCodeApprovals,
                                projectServerApprovals: claudeCodeServerApprovals),
            ]
        ),
        AgentToolDefinition(
            id: "cursor", displayName: "Cursor", starter: .app(bundleIDs: ["com.todesktop.230313mzl4w4u92"]),
            files: [AgentConfigFile(path: "~/.cursor/mcp.json", syntax: .json, serverPaths: [["mcpServers"]])]
        ),
        AgentToolDefinition(
            id: "codex", displayName: "Codex", starter: .terminal,
            files: [AgentConfigFile(
                path: "~/.codex/config.toml", syntax: .toml, serverPaths: [["mcp_servers"]],
                autoApprovals: [
                    AutoApprovalRule(path: ["approval_policy"], triggers: ["never"],
                                     message: "Befehle laufen ohne Rückfrage"),
                    AutoApprovalRule(path: ["sandbox_mode"], triggers: ["danger-full-access"],
                                     message: "Befehle laufen ohne Sandbox mit vollem Zugriff"),
                ],
                shape: ServerShape(headerPaths: [["http_headers"]], urlPaths: [["url"]], transportPaths: [],
                                   enabledField: .enabled(["enabled"]), credentialPaths: [["bearer_token"]])
            )]
        ),
        AgentToolDefinition(
            id: "windsurf", displayName: "Windsurf", starter: .app(bundleIDs: ["com.exafunction.windsurf"]),
            files: [AgentConfigFile(path: "~/.codeium/windsurf/mcp_config.json", syntax: .json, serverPaths: [["mcpServers"]],
                                    shape: ServerShape(enabledField: .disabled(["disabled"])))]
        ),
        AgentToolDefinition(
            id: "vscode", displayName: "VS Code", starter: .app(bundleIDs: ["com.microsoft.VSCode"]),
            files: vscodeFiles(userDirectory: "Code")
        ),
        AgentToolDefinition(
            id: "vscodeInsiders", displayName: "VS Code Insiders", starter: .app(bundleIDs: ["com.microsoft.VSCodeInsiders"]),
            files: vscodeFiles(userDirectory: "Code - Insiders")
        ),
        AgentToolDefinition(
            id: "zed", displayName: "Zed", starter: .app(bundleIDs: ["dev.zed.Zed"]),
            files: [AgentConfigFile(
                path: "~/.config/zed/settings.json", syntax: .jsonc, serverPaths: [["context_servers"]],
                autoApprovals: [AutoApprovalRule(
                    path: ["agent", "always_allow_tool_actions"], triggers: ["true"],
                    message: "Werkzeugaufrufe des Agenten laufen ohne Rückfrage"
                )],
                shape: ServerShape(commandPaths: [["command", "path"], ["command"]], argumentPaths: [["command", "args"], ["args"]],
                                   environmentPaths: [["command", "env"], ["env"]], urlPaths: [["url"]], transportPaths: [],
                                   extensionMarkers: [.value(path: ["source"], equals: "extension"), .onlyKeys(["settings"])])
            )]
        ),
        AgentToolDefinition(
            id: "gemini", displayName: "Gemini CLI", starter: .terminal,
            files: [
                AgentConfigFile(path: "~/.gemini/settings.json", syntax: .json, serverPaths: [["mcpServers"]],
                                autoApprovals: geminiApprovals, shape: geminiShape),
                AgentConfigFile(path: "/Library/Application Support/GeminiCli/settings.json", syntax: .json, scope: .system,
                                serverPaths: [["mcpServers"]], autoApprovals: geminiApprovals, shape: geminiShape),
            ]
        ),
    ])

    // MARK: Gemeinsame Bausteine (je Tool ein Satz Regeln für Benutzer- und Systemdatei)

    /// Freigaben in Claude Codes `settings.json`, auch in der verwalteten `managed-settings.json` und den
    /// Einstellungsdateien der Projekte.
    private static let claudeCodeApprovals: [AutoApprovalRule] = [
        AutoApprovalRule(path: ["permissions", "defaultMode"], triggers: ["bypassPermissions"],
                         message: "Werkzeugaufrufe laufen ohne Rückfrage"),
        AutoApprovalRule(path: ["skipDangerousModePermissionPrompt"], triggers: ["true"],
                         message: "Die Warnung vor dem Modus ohne Rückfragen ist abgeschaltet"),
        enableAllProjectServers,
    ]

    /// Gibt alle Server der `.mcp.json`-Dateien frei – in den Einstellungsdateien und im Projektobjekt von `~/.claude.json`.
    private static let enableAllProjectServers = AutoApprovalRule(
        path: ["enableAllProjectMcpServers"], triggers: ["true"],
        message: "Alle MCP-Server aus .mcp.json-Dateien werden ohne Rückfrage freigegeben"
    )

    /// Namenslisten für die `.mcp.json`-Server in Claude Codes Einstellungsdateien (Benutzer, verwaltet, Projekt).
    private static let claudeCodeServerApprovals = ProjectServerApprovalLists(
        enabledNamesPath: ["enabledMcpjsonServers"], disabledNamesPath: ["disabledMcpjsonServers"],
        enableAllPath: ["enableAllProjectMcpServers"]
    )

    /// Dateiweite Freigaben in Gemini CLIs `settings.json`: `tools.autoAccept` (neu) und `autoAccept` (ältere Versionen).
    private static let geminiApprovals: [AutoApprovalRule] = [
        AutoApprovalRule(path: ["tools", "autoAccept"], triggers: ["true"],
                         message: "Als sicher geltende Werkzeugaufrufe laufen ohne Rückfrage"),
        AutoApprovalRule(path: ["autoAccept"], triggers: ["true"],
                         message: "Als sicher geltende Werkzeugaufrufe laufen ohne Rückfrage"),
    ]

    /// Server-Form von Gemini CLI: `trust` gibt einen einzelnen Server frei.
    private static let geminiShape = ServerShape(serverApprovals: [AutoApprovalRule(
        path: ["trust"], triggers: ["true"], message: "Werkzeugaufrufe dieses Servers laufen ohne Rückfrage"
    )])

    /// Freigaben in VS Codes `settings.json` (punktierte Schlüssel auf oberster Ebene).
    private static let vscodeApprovals: [AutoApprovalRule] = [
        AutoApprovalRule(path: ["chat.tools.autoApprove"], triggers: ["true"],
                         message: "Werkzeugaufrufe im Chat laufen ohne Rückfrage"),
        AutoApprovalRule(path: ["chat.tools.global.autoApprove"], triggers: ["true"],
                         message: "Werkzeugaufrufe im Chat laufen ohne Rückfrage"),
    ]

    /// Dateien einer VS-Code-Variante; `userDirectory` ist der Ordnername unter `Application Support`
    /// (`Code`, `Code - Insiders`).
    private static func vscodeFiles(userDirectory: String) -> [AgentConfigFile] {
        let directory = "~/Library/Application Support/\(userDirectory)/User"
        return [
            AgentConfigFile(path: directory + "/mcp.json", syntax: .jsonc, serverPaths: [["servers"]]),
            AgentConfigFile(path: directory + "/settings.json", syntax: .jsonc,
                            serverPaths: [["mcp", "servers"], ["mcp.servers"]], autoApprovals: vscodeApprovals),
        ]
    }
}
