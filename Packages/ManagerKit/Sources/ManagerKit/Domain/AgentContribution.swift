/// Beitrag der Agenten-Quelle zu einem Scan (`InventoryContribution.agents`).
public struct AgentContribution: Sendable, Equatable {
    public var mcpServers: [MCPServerEntry]
    public var agentAutoApprovals: [AgentAutoApproval]
    /// Agenten-Dateien, deren Inhalt die Quelle gar nicht extrahieren konnte (Parserfehler, zu groß, Symlink aus dem
    /// Home, keine Leserechte) – nicht bei Teilproblemen einzelner Einträge: Ihre Einträge werden fortgeschrieben
    /// (`Snapshot.carryingForwardAgents`).
    public var incompleteFiles: [String]

    public init(
        mcpServers: [MCPServerEntry] = [], agentAutoApprovals: [AgentAutoApproval] = [], incompleteFiles: [String] = []
    ) {
        self.mcpServers = mcpServers
        self.agentAutoApprovals = agentAutoApprovals
        self.incompleteFiles = incompleteFiles
    }

    /// Hängt den Beitrag einer weiteren Quelle an.
    mutating func append(_ other: AgentContribution) {
        mcpServers += other.mcpServers
        agentAutoApprovals += other.agentAutoApprovals
        incompleteFiles += other.incompleteFiles
    }
}
