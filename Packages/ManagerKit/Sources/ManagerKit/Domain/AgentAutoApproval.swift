/// Eine aktive Einstellung, mit der ein Agenten-Tool Werkzeugaufrufe ohne Rückfrage erlaubt (Spec §4/§5) – als Hinweis,
/// nicht als Wertung des Herstellers. `value` ist immer einer der Auslösewerte aus dem Katalog, nie freier Text.
public struct AgentAutoApproval: InventoryRecord, Codable {
    public var toolID: String
    public var toolName: String
    public var configPath: String
    /// Bei Freigaben aus Projekt-Einstellungsdateien die Datei, die das Projekt registriert (`~/.claude.json`) – für
    /// das Fortschreiben, wenn sie nicht lesbar ist; sonst `nil`. Nicht signifikant, fehlt in älteren Snapshots.
    public var registryPath: String?
    public var scope: AgentScope
    /// Schlüsselpfad mit Punkten, z. B. `permissions.defaultMode` oder `mcpServers.x.trust`.
    public var setting: String
    public var value: String
    /// Erklärung aus dem Katalog.
    public var message: String
    public var source: SourceID

    public init(
        toolID: String, toolName: String, configPath: String, registryPath: String? = nil, scope: AgentScope,
        setting: String, value: String, message: String, source: SourceID = .agents
    ) {
        self.toolID = toolID
        self.toolName = toolName
        self.configPath = configPath
        self.registryPath = registryPath
        self.scope = scope
        self.setting = setting
        self.value = value
        self.message = message
        self.source = source
    }

    /// Identität laut #129: Tool + Datei + Geltungsbereich + Einstellung, davor die Art des Eintrags (`approval`). Sie
    /// trennt Freigaben von MCP-Servern gleichen Namens in derselben Datei (`MCPServerEntry.id`). `RecordIdentity`
    /// maskiert Trennzeichen.
    public var id: String { RecordIdentity.join(["approval", toolID, configPath, scope.identityComponent, setting]) }

    /// Signifikant ist nur der Auslösewert; die Erklärung (`message`) stammt aus dem Katalog und zählt nicht, ebenso
    /// wenig die Registerdatei.
    public func hasSignificantChanges(comparedTo other: AgentAutoApproval) -> Bool {
        value != other.value
    }

    /// „Claude Code“, „Claude Code (Projekt web)“.
    public var locationDescription: String { toolName + scope.displaySuffix }
}
