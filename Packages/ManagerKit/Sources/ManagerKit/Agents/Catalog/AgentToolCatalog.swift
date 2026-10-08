/// Welche Agenten-Tools Grantry kennt und wo deren Konfiguration liegt (Spec §2). Reine Daten: Ein neues Tool mit
/// bekanntem Format ist ein neuer Eintrag in `AgentToolCatalog.standard`, ohne Änderung an Scanner oder Extraktion.
public struct AgentToolCatalog: Hashable, Sendable {
    public let tools: [AgentToolDefinition]

    public init(tools: [AgentToolDefinition]) {
        self.tools = tools
    }

    public func tool(id: String) -> AgentToolDefinition? {
        tools.first { $0.id == id }
    }

    /// Alle festen Dateipfade (Home aufgelöst), ohne Projektdateien – für die Dateiüberwachung.
    public func staticPaths(home: String) -> [String] {
        var seen = Set<String>()
        return tools.flatMap(\.files).map { $0.expandedPath(home: home) }.filter { seen.insert($0).inserted }
    }

    /// Anzeigenamen aller Tools als Aufzählung: „Claude Desktop, Claude Code, … und Gemini CLI“.
    public var toolNamesText: String {
        let names = tools.map(\.displayName)
        guard let last = names.last, names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " und " + last
    }
}

/// Ein Agenten-Tool.
public struct AgentToolDefinition: Hashable, Sendable, Identifiable {
    /// Wer die Server startet – und damit, wessen Berechtigungen sie erben (Spec §5, „Rechte des Starters“).
    public enum Starter: Hashable, Sendable {
        /// Desktop-App mit diesen Bundle-IDs.
        case app(bundleIDs: [String])
        /// Kommandozeilen-Tool: startet in der Terminal-App (`TerminalHosts`).
        case terminal
    }

    public let id: String
    public let displayName: String
    public let starter: Starter
    public let files: [AgentConfigFile]

    public init(id: String, displayName: String, starter: Starter, files: [AgentConfigFile]) {
        self.id = id
        self.displayName = displayName
        self.starter = starter
        self.files = files
    }
}

/// Eine Konfigurationsdatei eines Tools.
public struct AgentConfigFile: Hashable, Sendable {
    public enum Scope: Hashable, Sendable {
        /// Im Benutzerordner.
        case user
        /// Verwaltete Systemdatei – nur lesend, nie änderbar (Stufe 2).
        case system
    }

    /// `~/…` oder absolut.
    public let path: String
    public let syntax: ConfigSyntax
    public let scope: Scope
    /// Schlüsselpfade zu Objekten mit Servern (`["mcpServers"]`, `["mcp", "servers"]` …).
    public let serverPaths: [[String]]
    /// Von der Datei registrierte Projekte (nur Claude Code).
    public let projects: ProjectLocation?
    /// Dateiweite automatische Freigaben.
    public let autoApprovals: [AutoApprovalRule]
    public let shape: ServerShape
    /// Namenslisten dieser Datei, die für die `ProjectFile`-Server **aller** Projekte des Tools gelten (Claude Code
    /// `~/.claude/settings.json`, `managed-settings.json`); vereinigt mit den Listen der Projekt-Ebenen.
    public let projectServerApprovals: ProjectServerApprovalLists?
    /// Das Tool schreibt die Datei laufend (Claude Code `~/.claude.json`): Vor einer Änderung durch Grantry muss es
    /// beendet sein, sonst überschreibt es sie (Stufe 2).
    public let isRewrittenByTool: Bool

    public init(
        path: String, syntax: ConfigSyntax, scope: Scope = .user, serverPaths: [[String]],
        projects: ProjectLocation? = nil, autoApprovals: [AutoApprovalRule] = [], shape: ServerShape = .standard,
        projectServerApprovals: ProjectServerApprovalLists? = nil, isRewrittenByTool: Bool = false
    ) {
        self.path = path
        self.syntax = syntax
        self.scope = scope
        self.serverPaths = serverPaths
        self.projects = projects
        self.autoApprovals = autoApprovals
        self.shape = shape
        self.projectServerApprovals = projectServerApprovals
        self.isRewrittenByTool = isRewrittenByTool
    }

    /// Pfad mit aufgelöstem `~`; Symlinks bleiben unaufgelöst. Ein abschließender `/` von `home` entfällt, damit kein
    /// `//` entsteht.
    public func expandedPath(home: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        return PathDisplay.trimmingTrailingSlashes(home) + path.dropFirst()
    }
}

// MARK: Schwärzung

extension ConfigRedaction {
    /// Regel für Agenten-Dateien: `ServerShape.redactedKeys` schwärzen, außer als Servernamen direkt in `serverPaths`.
    static func agentConfig(serverPaths: [[String]] = []) -> ConfigRedaction {
        ConfigRedaction(keys: ServerShape.redactedKeys, exemptParents: serverPaths)
    }
}

/// Wie eine Katalogdatei geparst wird – Scan und Inhalts-Stempel lesen jede Datei über diese eine Beschreibung.
protocol ParsedConfigFile {
    var syntax: ConfigSyntax { get }
    var redaction: ConfigRedaction { get }
}

extension AgentConfigFile: ParsedConfigFile {
    /// Schwärzungsregel der Datei (Scan und Inhalts-Stempel): Server-Listen der Datei und je registriertem Projekt.
    var redaction: ConfigRedaction {
        let projectServerPaths = projects.map { location in
            location.serverPaths.map { location.projectsPath + ["*"] + $0 }
        } ?? []
        return .agentConfig(serverPaths: serverPaths + projectServerPaths)
    }
}

extension ProjectFile: ParsedConfigFile {
    var redaction: ConfigRedaction { .agentConfig(serverPaths: serverPaths) }
}

extension ProjectSettingsFile: ParsedConfigFile {
    /// Ohne Server-Listen: Die Schlüssel werden überall geschwärzt.
    var redaction: ConfigRedaction { .agentConfig() }
}

/// Projekte, die eine Datei selbst registriert (Claude Code: `projects` in `~/.claude.json`). Kein rekursives Suchen.
public struct ProjectLocation: Hashable, Sendable {
    /// Objekt, dessen Schlüssel Projektpfade sind.
    public let projectsPath: [String]
    /// Server je Projektobjekt.
    public let serverPaths: [[String]]
    /// Liste abgeschalteter Servernamen im Projektobjekt.
    public let disabledNamesPath: [String]?
    /// Freigaben je Projektobjekt.
    public let autoApprovals: [AutoApprovalRule]
    /// Datei im Projektordner (`.mcp.json`).
    public let projectFile: ProjectFile?
    /// Einstellungsdateien im Projektordner; ihre Namenslisten werden vereinigt (`ProjectApprovalState`).
    public let settingsFiles: [ProjectSettingsFile]

    public init(
        projectsPath: [String], serverPaths: [[String]], disabledNamesPath: [String]? = nil,
        autoApprovals: [AutoApprovalRule] = [], projectFile: ProjectFile? = nil, settingsFiles: [ProjectSettingsFile] = []
    ) {
        self.projectsPath = projectsPath
        self.serverPaths = serverPaths
        self.disabledNamesPath = disabledNamesPath
        self.autoApprovals = autoApprovals
        self.projectFile = projectFile
        self.settingsFiles = settingsFiles
    }
}

/// Wo eine Quelle festhält, welche Server der `ProjectFile` freigegeben sind: Listen freigegebener und abgelehnter
/// Namen sowie ein Bool, der alle freigibt.
public protocol ProjectServerApprovalPaths {
    var enabledNamesPath: [String]? { get }
    var disabledNamesPath: [String]? { get }
    var enableAllPath: [String]? { get }
}

extension ProjectServerApprovalPaths {
    /// Die Werte unter den drei Pfaden – genau das, was die Freigabe bestimmt (für Inhalts-Stempel).
    func approvalValues(in document: ConfigValue) -> [ConfigValue?] {
        [enabledNamesPath, disabledNamesPath, enableAllPath].map { path in path.flatMap { document.value(at: $0) } }
    }
}

/// Namenslisten ohne eigene Datei (`AgentConfigFile.projectServerApprovals`).
public struct ProjectServerApprovalLists: Hashable, Sendable, ProjectServerApprovalPaths {
    public let enabledNamesPath: [String]?
    public let disabledNamesPath: [String]?
    public let enableAllPath: [String]?

    public init(enabledNamesPath: [String]? = nil, disabledNamesPath: [String]? = nil, enableAllPath: [String]? = nil) {
        self.enabledNamesPath = enabledNamesPath
        self.disabledNamesPath = disabledNamesPath
        self.enableAllPath = enableAllPath
    }
}

/// Konfigurationsdatei im Projektordner; ob ihre Server freigegeben sind, steht im Projektobjekt der Registerdatei
/// (Pfade dieses Typs) und in den `ProjectLocation.settingsFiles`.
public struct ProjectFile: Hashable, Sendable, ProjectServerApprovalPaths {
    public let relativePath: String
    public let syntax: ConfigSyntax
    public let serverPaths: [[String]]
    public let enabledNamesPath: [String]?
    public let disabledNamesPath: [String]?
    /// Bool im Projektobjekt, der alle Server der Datei freigibt.
    public let enableAllPath: [String]?

    public init(
        relativePath: String, syntax: ConfigSyntax, serverPaths: [[String]], enabledNamesPath: [String]? = nil,
        disabledNamesPath: [String]? = nil, enableAllPath: [String]? = nil
    ) {
        self.relativePath = relativePath
        self.syntax = syntax
        self.serverPaths = serverPaths
        self.enabledNamesPath = enabledNamesPath
        self.disabledNamesPath = disabledNamesPath
        self.enableAllPath = enableAllPath
    }
}

/// Einstellungsdatei im Projektordner (Claude Code `.claude/settings.json`, `.claude/settings.local.json`): dateiweite
/// Freigaben mit Projekt-Bereich und die Freigabe der `ProjectFile`-Server. Nicht überwacht, nur bei Scans gelesen.
public struct ProjectSettingsFile: Hashable, Sendable, ProjectServerApprovalPaths {
    public let relativePath: String
    public let syntax: ConfigSyntax
    public let autoApprovals: [AutoApprovalRule]
    public let enabledNamesPath: [String]?
    public let disabledNamesPath: [String]?
    public let enableAllPath: [String]?

    public init(
        relativePath: String, syntax: ConfigSyntax, autoApprovals: [AutoApprovalRule] = [],
        enabledNamesPath: [String]? = nil, disabledNamesPath: [String]? = nil, enableAllPath: [String]? = nil
    ) {
        self.relativePath = relativePath
        self.syntax = syntax
        self.autoApprovals = autoApprovals
        self.enabledNamesPath = enabledNamesPath
        self.disabledNamesPath = disabledNamesPath
        self.enableAllPath = enableAllPath
    }
}

/// Feldnamen eines Server-Objekts. Pfade relativ zum Server-Objekt; der erste vorhandene gilt.
public struct ServerShape: Hashable, Sendable {
    public enum EnabledField: Hashable, Sendable {
        /// Bool, `true` = aktiv (Codex `enabled`).
        case enabled([String])
        /// Bool, `true` = abgeschaltet (`disabled`).
        case disabled([String])
    }

    /// Kennzeichen eines Servers, den eine Erweiterung des Tools bereitstellt: Ohne Befehl und URL wird er still
    /// übersprungen statt als Problem gemeldet.
    public enum ExtensionMarker: Hashable, Sendable {
        /// Wert unter `path` (`ConfigValue.scalarText`) ist `value` (Zed `"source": "extension"`).
        case value(path: [String], equals: String)
        /// Das Server-Objekt hat nur Schlüssel aus `keys` (Zed, ältere Form: nur `settings`).
        case onlyKeys(Set<String>)
    }

    /// Schlüssel, deren Werte der Parser nie liest – auf jeder Ebene jeder Agenten-Datei, außer als Servername direkt in
    /// einer Server-Liste (`ConfigRedaction.agentConfig`, Spec §3). Enthält alle
    /// letzten Glieder von `environmentPaths`/`headerPaths` sowie Codex' `env_http_headers` und das ältere
    /// `bearer_token` (Klartext-Token).
    public static let redactedKeys: Set<String> = ["env", "headers", "http_headers", "env_http_headers", "bearer_token"]

    public let commandPaths: [[String]]
    public let argumentPaths: [[String]]
    public let environmentPaths: [[String]]
    public let headerPaths: [[String]]
    public let urlPaths: [[String]]
    public let transportPaths: [[String]]
    public let enabledField: EnabledField?
    /// Freigaben je Server (Gemini `trust`).
    public let serverApprovals: [AutoApprovalRule]
    public let extensionMarkers: [ExtensionMarker]
    /// Schlüssel, deren bloßes Vorhandensein ein Geheimnis im Klartext bedeutet (Codex `bearer_token`); ihr Wert ist
    /// geschwärzt (`redactedKeys`) und daher unbekannt. Nur Variablennamen (`bearer_token_env_var`) zählen nicht.
    public let credentialPaths: [[String]]

    public init(
        commandPaths: [[String]] = [["command"]], argumentPaths: [[String]] = [["args"]],
        environmentPaths: [[String]] = [["env"]], headerPaths: [[String]] = [["headers"]],
        urlPaths: [[String]] = [["url"], ["serverUrl"], ["httpUrl"]], transportPaths: [[String]] = [["type"], ["transport"]],
        enabledField: EnabledField? = nil, serverApprovals: [AutoApprovalRule] = [], extensionMarkers: [ExtensionMarker] = [],
        credentialPaths: [[String]] = []
    ) {
        self.commandPaths = commandPaths
        self.argumentPaths = argumentPaths
        self.environmentPaths = environmentPaths
        self.headerPaths = headerPaths
        self.urlPaths = urlPaths
        self.transportPaths = transportPaths
        self.enabledField = enabledField
        self.serverApprovals = serverApprovals
        self.extensionMarkers = extensionMarkers
        self.credentialPaths = credentialPaths
    }

    /// `mcpServers`-Format von Claude, Cursor, Gemini und VS Code ohne Schalter.
    public static let standard = ServerShape()
}

/// Einstellung, die Werkzeugaufrufe ohne Rückfrage erlaubt, wenn ihr Wert (`ConfigValue.scalarText`) einer der
/// `triggers` ist.
public struct AutoApprovalRule: Hashable, Sendable {
    public let path: [String]
    public let triggers: Set<String>
    public let message: String

    public init(path: [String], triggers: Set<String>, message: String) {
        self.path = path
        self.triggers = triggers
        self.message = message
    }
}

/// Terminal-Apps, aus denen Kommandozeilen-Tools typischerweise starten (Spec §5): Ihre Berechtigungen erben die
/// Server von Claude Code, Codex oder Gemini CLI.
public enum TerminalHosts {
    public static let bundleIDs: [String] = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "com.github.wez.wezterm", "net.kovidgoyal.kitty", "org.alacritty", "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.exafunction.windsurf",
    ]
}
