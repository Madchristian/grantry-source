import Foundation

/// Ein Tool im Bereich „Agenten“ mit seinen Servern und Freigaben.
public struct AgentToolGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// Benutzerweit vor Projekt vor System, darin nach Name (natürliche Sortierung), zuletzt nach `id`.
    public let servers: [MCPServerEntry]
    /// Benutzerweit vor Projekt vor System, darin nach Einstellung, zuletzt nach `id`.
    public let approvals: [AgentAutoApproval]

    /// IDs aller Server und Freigaben der Gruppe.
    public var recordIDs: [String] { servers.map(\.id) + approvals.map(\.id) }
}

/// Berechtigungen, die die Server eines Tools erben (Spec §5, „Rechte des Starters“) – Info, keine Bewertung.
public struct AgentStarterAccess: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Die Desktop-App des Tools startet die Server.
        case app
        /// Kommandozeilen-Tool: Die Server laufen mit den Rechten der Terminal-App, aus der es startet.
        case terminal
        /// Tool nicht im Katalog.
        case unknown
    }

    public let kind: Kind
    /// Erteilte Berechtigungen der Starter-App(s); bei Terminal-Tools nur sensible Dienste bekannter Terminal-Apps.
    public let grants: [PermissionGrant]

    /// Tool nicht im Katalog – keine Angaben.
    public static let unknown = AgentStarterAccess(kind: .unknown, grants: [])
}

/// Name einer Umgebungsvariable bzw. eines Headers mit Geheimnis-Markierung – nie mit Wert.
public struct NamedKey: Identifiable, Hashable, Sendable {
    public let name: String
    public let isSecret: Bool

    public var id: String { name }
}

/// Angaben im Detail eines MCP-Servers (Spec §7).
public struct MCPServerDetail: Hashable, Sendable {
    public let entry: MCPServerEntry
    public let findings: [RiskFinding]
    public let starter: AgentStarterAccess
    /// „lokal“ bzw. „entfernt (http)“.
    public let kindText: String
    /// Vollständiger (maskierter) Befehl (`MCPTransport.commandLine`); `nil` bei entfernten Servern.
    public let commandLine: String?
    /// Hinweis zum Befehl (`MaskedCommandNote`): verborgenes Skript oder maskierte Werte; `nil` sonst und bei entfernten
    /// Servern.
    public let commandNote: String?
    /// Ziel-URL (maskiert); `nil` bei lokalen Servern.
    public let url: String?
    public let packageText: String
    public let environment: [NamedKey]
    public let headers: [NamedKey]
    /// „global (Benutzer)“, „Projekt ~/web“, „System (verwaltet)“.
    public let scopeText: String
    /// `MCPServerEntry.enabledText`.
    public let enabledText: String?
    /// Konfigurationsdatei mit `~`.
    public let configPathText: String
    /// Was sich ändern lässt (Stufe 2: Entfernen, Schalter).
    public let editing: AgentEditCapabilities

    public init(entry: MCPServerEntry, findings: [RiskFinding], starter: AgentStarterAccess, home: String = NSHomeDirectory()) {
        self.entry = entry
        self.findings = findings
        self.starter = starter
        commandLine = entry.transport.commandLine
        switch entry.transport {
        case .local(let command, let arguments):
            kindText = "lokal"
            url = nil
            let words = [command] + arguments
            commandNote = MaskedCommandNote.text(
                for: words, program: nil, isMasked: words.contains { $0.contains(ArgumentRedactor.mask) },
                hasHiddenScript: entry.hasHiddenScript
            )
        case .remote(let remoteURL, let kind):
            kindText = kind.map { "entfernt (\($0))" } ?? "entfernt"
            url = remoteURL
            commandNote = nil
        }
        packageText = AgentPresenter.packageText(entry.packageSource, home: home)
        environment = entry.environmentKeys.map { NamedKey(name: $0, isSecret: SecretNames.looksSecret($0)) }
        headers = entry.headerKeys.map { NamedKey(name: $0, isSecret: SecretNames.looksSecret($0)) }
        scopeText = AgentPresenter.scopeText(entry.scope, home: home)
        enabledText = entry.enabledText
        configPathText = PathDisplay.abbreviatingHome(entry.configPath, home: home)
        editing = entry.editCapabilities(home: home)
    }
}

/// Bereitet Agenten-Einträge für die Oberfläche auf.
public enum AgentPresenter {
    /// Gruppen in Katalogreihenfolge; Tools ohne Einträge entfallen, unbekannte Tools folgen nach Anzeigename.
    public static func groups(snapshot: Snapshot, catalog: AgentToolCatalog = .standard) -> [AgentToolGroup] {
        let servers = Dictionary(grouping: snapshot.mcpServers, by: \.toolID)
        let approvals = Dictionary(grouping: snapshot.agentAutoApprovals, by: \.toolID)
        let groups = Set(servers.keys).union(approvals.keys).map { id in
            let toolServers = servers[id] ?? [], toolApprovals = approvals[id] ?? []
            return AgentToolGroup(
                id: id,
                name: catalog.tool(id: id)?.displayName ?? toolServers.first?.toolName ?? toolApprovals.first?.toolName ?? id,
                servers: toolServers.sorted { precedes(($0.scope, $0.name, $0.id), ($1.scope, $1.name, $1.id)) },
                approvals: toolApprovals.sorted { precedes(($0.scope, $0.setting, $0.id), ($1.scope, $1.setting, $1.id)) }
            )
        }
        let catalogIndex = Dictionary(uniqueKeysWithValues: catalog.tools.enumerated().map { ($1.id, $0) })
        return groups.sorted { lhs, rhs in
            switch (catalogIndex[lhs.id], catalogIndex[rhs.id]) {
            case let (left?, right?): left < right
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): precedes((.user, lhs.name, lhs.id), (.user, rhs.name, rhs.id))
            }
        }
    }

    /// Rechte des Starters je Tool mit MCP-Servern oder automatischen Freigaben im Snapshot.
    public static func starterAccessByToolID(
        snapshot: Snapshot, catalog: AgentToolCatalog = .standard
    ) -> [String: AgentStarterAccess] {
        Dictionary(uniqueKeysWithValues: Set(snapshot.mcpServers.map(\.toolID) + snapshot.agentAutoApprovals.map(\.toolID)).map {
            ($0, starterAccess(toolID: $0, grants: snapshot.grants, catalog: catalog))
        })
    }

    /// Erteilte Berechtigungen der Starter-App(s) eines Tools (Spec §5) – Info, keine Bewertung.
    public static func starterAccess(
        toolID: String, grants: [PermissionGrant], catalog: AgentToolCatalog = .standard
    ) -> AgentStarterAccess {
        let granted = grants.filter(\.authValue.isGranted)
        switch catalog.tool(id: toolID)?.starter {
        case .app(let bundleIDs)?:
            return AgentStarterAccess(kind: .app, grants: sorted(granted.filter { $0.client.bundleID.map(bundleIDs.contains) == true }))
        case .terminal?:
            let terminals = Set(TerminalHosts.bundleIDs)
            return AgentStarterAccess(kind: .terminal, grants: sorted(granted.filter {
                $0.client.bundleID.map(terminals.contains) == true && PermissionCatalog.service(for: $0.service).isSensitive
            }))
        case nil:
            return .unknown
        }
    }

    /// „global (Benutzer)“, „Projekt ~/web“, „System (verwaltet)“ – Geltungsbereich im Detail.
    public static func scopeText(_ scope: AgentScope, home: String = NSHomeDirectory()) -> String {
        switch scope {
        case .user: "global (Benutzer)"
        case .project(let path): "Projekt \(PathDisplay.abbreviatingHome(path, home: home))"
        case .system: "System (verwaltet)"
        }
    }

    /// „npm-Paket fs@1.0.0“, „PyPI-Paket f – ohne festgelegte Version“, „Befehl „uv“ aus dem PATH“ …
    public static func packageText(_ source: PackageSource, home: String = NSHomeDirectory()) -> String {
        let unpinned = source.isUnpinned ? " – ohne festgelegte Version" : ""
        switch source {
        case .npm(let package, let version): return "npm-Paket \(package)\(version.map { "@\($0)" } ?? "")\(unpinned)"
        case .pypi(let package, let version): return "PyPI-Paket \(package)\(version.map { "==\($0)" } ?? "")\(unpinned)"
        case .container(let image, let reference): return "Container-Image \(image)\(reference.map { " (\($0))" } ?? "")\(unpinned)"
        case .localProgram(let path): return "Lokales Programm \(PathDisplay.abbreviatingHome(path, home: home))"
        case .command(let name): return "Befehl „\(name)“ aus dem PATH"
        case .remote(let host): return "Entfernter Server \(host)"
        }
    }

    private static func sorted(_ grants: [PermissionGrant]) -> [PermissionGrant] {
        grants.sorted { ($0.client.displayName, $0.service) < ($1.client.displayName, $1.service) }
    }

    /// Gemeinsame Reihenfolge der Einträge: Geltungsbereich (`AgentScope.order`), dann Text in natürlicher Sortierung
    /// (`localizedStandardCompare`), zuletzt `id` für eine stabile Reihenfolge.
    private static func precedes(_ lhs: (scope: AgentScope, text: String, id: String),
                                 _ rhs: (scope: AgentScope, text: String, id: String)) -> Bool {
        if lhs.scope.order != rhs.scope.order { return lhs.scope.order < rhs.scope.order }
        let comparison = lhs.text.localizedStandardCompare(rhs.text)
        return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
    }
}

/// Bereich „Agenten“ eines `PresentationSnapshot` (`agents`).
public struct AgentPresentationState: Hashable, Sendable {
    /// Agenten-Tools mit ihren MCP-Servern und automatischen Freigaben in Katalogreihenfolge (`AgentPresenter`).
    public let groups: [AgentToolGroup]
    let starterAccessByToolID: [String: AgentStarterAccess]
    let index: AgentRecordIndex

    init(snapshot: Snapshot) {
        groups = AgentPresenter.groups(snapshot: snapshot)
        starterAccessByToolID = AgentPresenter.starterAccessByToolID(snapshot: snapshot)
        index = AgentRecordIndex(snapshot: snapshot)
    }
}

extension PresentationSnapshot {
    /// Angaben im Detail eines MCP-Servers samt Befunden und Rechten des Starters.
    public func agentDetail(for server: MCPServerEntry, home: String = NSHomeDirectory()) -> MCPServerDetail {
        MCPServerDetail(entry: server, findings: findings(for: server.id),
                        starter: agents.starterAccessByToolID[server.toolID] ?? .unknown, home: home)
    }

    /// MCP-Server mit dieser ID; `nil`, wenn es ihn nicht (mehr) gibt.
    public func agentServer(id: String) -> MCPServerEntry? { agents.index.servers[id] }

    /// Automatische Freigabe mit dieser ID; `nil`, wenn es sie nicht (mehr) gibt.
    public func agentApproval(id: String) -> AgentAutoApproval? { agents.index.approvals[id] }

    /// Höchster Schweregrad der Befunde im Bereich „Agenten“ (`highestSeverity`, `flaggedArea`); `nil` ohne Befunde.
    var agentsHighestSeverity: RiskFinding.Severity? {
        agents.groups.flatMap(\.recordIDs).compactMap { highestSeverity(for: $0) }.max()
    }
}

/// Agenten-Einträge nach ID – Nachschlagen für Navigation und Detail.
struct AgentRecordIndex: Hashable, Sendable {
    let servers: [String: MCPServerEntry]
    let approvals: [String: AgentAutoApproval]

    init(snapshot: Snapshot) {
        servers = Dictionary(snapshot.mcpServers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        approvals = Dictionary(snapshot.agentAutoApprovals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

extension AgentScope {
    /// Benutzerweit (0) vor Projekt (1) vor System (2).
    fileprivate var order: Int {
        switch self {
        case .user: 0
        case .project: 1
        case .system: 2
        }
    }
}
