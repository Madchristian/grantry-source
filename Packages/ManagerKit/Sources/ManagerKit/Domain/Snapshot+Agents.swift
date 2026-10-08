import Foundation

extension Snapshot {
    /// Nimmt die Agenten-Einträge eines Scans auf und schreibt die aus nicht lesbaren Dateien fort
    /// (`carryingForwardAgents`).
    func addingAgents(_ agents: AgentContribution, carryingForwardFrom previous: Snapshot?) -> Snapshot {
        var result = self
        result.mcpServers += agents.mcpServers
        result.agentAutoApprovals += agents.agentAutoApprovals
        return result.carryingForwardAgents(inIncompleteFiles: agents.incompleteFiles, from: previous)
    }

    /// Übernimmt Einträge aus Agenten-Dateien, die dieser Scan nicht lesen konnte (`AgentContribution
    /// .incompleteFiles`), aus `previous` – sonst erschienen sie als entfernt. Betroffen sind Einträge, deren
    /// `configPath` oder `registryPath` (Projekt- und Projekt-Einstellungsdateien einer nicht lesbaren Registerdatei)
    /// in `files` liegt – für Server wie für Freigaben.
    /// Idempotent: vorhandene IDs werden nicht doppelt übernommen.
    func carryingForwardAgents(inIncompleteFiles files: [String], from previous: Snapshot?) -> Snapshot {
        guard let previous, !files.isEmpty else { return self }
        let gaps = Set(files)
        let presentServers = Set(mcpServers.map(\.id))
        let presentApprovals = Set(agentAutoApprovals.map(\.id))
        var result = self
        func isInGap(configPath: String, registryPath: String?) -> Bool {
            gaps.contains(configPath) || registryPath.map(gaps.contains) == true
        }
        result.mcpServers += previous.mcpServers.filter {
            !presentServers.contains($0.id) && isInGap(configPath: $0.configPath, registryPath: $0.registryPath)
        }
        result.agentAutoApprovals += previous.agentAutoApprovals.filter {
            !presentApprovals.contains($0.id) && isInGap(configPath: $0.configPath, registryPath: $0.registryPath)
        }
        return result
    }
}
