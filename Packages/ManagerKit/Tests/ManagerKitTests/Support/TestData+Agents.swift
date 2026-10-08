import Foundation
@testable import ManagerKit

extension TestData {
    /// Standardquellen plus Agenten-Quelle (eingeschwungener Zustand).
    static let agentSources: Set<SourceID> = allSources.union([.agents])

    static func mcpServer(
        _ name: String = "filesystem", toolID: String = "claudeDesktop", toolName: String = "Claude Desktop",
        configPath: String = "/Users/test/Library/Application Support/Claude/claude_desktop_config.json",
        scope: AgentScope = .user, transport: MCPTransport = .local(command: "npx", arguments: ["-y", "pkg"]),
        environmentKeys: [String] = [], headerKeys: [String] = [], isEnabled: Bool? = nil,
        packageSource: PackageSource = .npm(package: "pkg", version: nil), hasSecretInArguments: Bool = false,
        programSigning: SigningInfo? = nil, programPresence: Presence = .unknown, configFileMode: UInt16? = 0o600,
        registryPath: String? = nil
    ) -> MCPServerEntry {
        MCPServerEntry(
            toolID: toolID, toolName: toolName, configPath: configPath, registryPath: registryPath, scope: scope,
            name: name, transport: transport, environmentKeys: environmentKeys, headerKeys: headerKeys,
            isEnabled: isEnabled, packageSource: packageSource, hasSecretInArguments: hasSecretInArguments,
            programSigning: programSigning, programPresence: programPresence, configFileMode: configFileMode
        )
    }

    /// Standardkatalog ohne Systemdateien (Tests lesen nie außerhalb ihres Fixture-Homes).
    static let userCatalog = AgentToolCatalog(tools: AgentToolCatalog.standard.tools.map { tool in
        AgentToolDefinition(id: tool.id, displayName: tool.displayName, starter: tool.starter,
                            files: tool.files.filter { $0.scope == .user })
    })

    static func autoApproval(
        toolID: String = "claudeCode", toolName: String = "Claude Code", configPath: String = "/Users/test/.claude/settings.json",
        registryPath: String? = nil, scope: AgentScope = .user, setting: String = "permissions.defaultMode",
        value: String = "bypassPermissions", message: String = "Werkzeugaufrufe laufen ohne Rückfrage"
    ) -> AgentAutoApproval {
        AgentAutoApproval(
            toolID: toolID, toolName: toolName, configPath: configPath, registryPath: registryPath, scope: scope,
            setting: setting, value: value, message: message
        )
    }

    /// Snapshot mit Agenten-Einträgen; Baseline enthält die Agenten-Quelle.
    static func agentSnapshot(
        _ servers: [MCPServerEntry], approvals: [AgentAutoApproval] = [], grants: [PermissionGrant] = [],
        errors: [SourceError] = [], baseline: Set<SourceID> = agentSources, at date: Date = date
    ) -> Snapshot {
        Snapshot(takenAt: date, grants: grants, autostartItems: [], mcpServers: servers, agentAutoApprovals: approvals,
                 sourceErrors: errors, baselineSources: baseline)
    }
}
