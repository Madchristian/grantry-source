#if DEBUG
import Foundation
import ManagerKit

/// Beispieldaten für die SwiftUI-Previews des Bereichs „Agenten“ – erfundene Einträge, keine echten Konfigurationen.
enum AgentPreviewData {
    /// Lokaler Server mit geheimnisartiger Umgebungsvariable und ungepinntem Paket.
    static let localServer = MCPServerEntry(
        toolID: "claudeCode", toolName: "Claude Code", configPath: "~/.claude.json", scope: .user, name: "github",
        transport: .local(command: "npx", arguments: ["-y", "@modelcontextprotocol/server-github", "--token", "•••"]),
        environmentKeys: ["GITHUB_TOKEN", "LOG_LEVEL"], isEnabled: true,
        packageSource: .npm(package: "@modelcontextprotocol/server-github", version: nil), hasSecretInArguments: true
    )

    /// Entfernter Server über unverschlüsseltes `http://` mit Header, projektbezogen.
    static let remoteServer = MCPServerEntry(
        toolID: "claudeCode", toolName: "Claude Code", configPath: "/Users/beispiel/web/.mcp.json",
        registryPath: "~/.claude.json", scope: .project(path: "/Users/beispiel/web"), name: "intranet",
        transport: .remote(url: "http://mcp.intern.example:8080/sse", kind: "sse"), headerKeys: ["Authorization"],
        isEnabled: false, packageSource: .remote(host: "mcp.intern.example")
    )

    static let approval = AgentAutoApproval(
        toolID: "claudeCode", toolName: "Claude Code", configPath: "~/.claude/settings.json", scope: .user,
        setting: "permissions.defaultMode", value: "bypassPermissions",
        message: "Claude Code führt Werkzeugaufrufe ohne Rückfrage aus."
    )

    static let approvalFinding = RiskFinding(
        rule: .autoApproval, severity: .low, recordID: approval.id,
        message: "Automatische Freigabe aktiv: Werkzeugaufrufe laufen ohne Rückfrage."
    )

    /// Snapshot mit beiden Servern, der Freigabe und einer Terminal-Berechtigung (Rechte des Starters).
    static let presentation: PresentationSnapshot = {
        let terminal = AppIdentity(bundleID: "com.apple.Terminal", path: "/System/Applications/Utilities/Terminal.app",
                                   displayName: "Terminal", signing: SigningInfo(kind: .apple), presence: .present)
        let grant = PermissionGrant(service: "kTCCServiceSystemPolicyAllFiles", client: terminal, authValue: .allowed,
                                    scope: .system, lastModified: .now)
        let snapshot = Snapshot(takenAt: .now, grants: [grant], autostartItems: [],
                                mcpServers: [localServer, remoteServer], agentAutoApprovals: [approval],
                                sourceErrors: [])
        let findings = [
            RiskFinding(rule: .plaintextSecret, severity: .low, recordID: localServer.id,
                        message: "Geheimnis im Klartext in den Argumenten."),
            RiskFinding(rule: .unpinnedPackage, severity: .low, recordID: localServer.id,
                        message: "npm-Paket ohne festgelegte Version."),
            RiskFinding(rule: .cleartextRemote, severity: .medium, recordID: remoteServer.id,
                        message: "Entfernter Server über unverschlüsseltes http://."),
            approvalFinding,
        ]
        return PresentationSnapshot.make(snapshot: snapshot, findings: findings, events: [], recentAdditions: [],
                                         now: .now)
    }()
}
#endif
