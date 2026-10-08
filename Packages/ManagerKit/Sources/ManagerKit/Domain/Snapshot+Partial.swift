import Foundation

extension Snapshot {
    /// Dieser Snapshot ohne Einträge, Fehler und Einschränkungen der Quellen `sources` – Ausgangspunkt eines Teilscans,
    /// der nur diese Quellen neu liefert. `baselineSources` bleibt unverändert. Neue Eintragsarten müssen hier ergänzt
    /// werden.
    func removingRecords(of sources: Set<SourceID>) -> Snapshot {
        var result = self
        result.grants.removeAll { sources.contains($0.source) }
        result.autostartItems.removeAll { sources.contains($0.source) }
        result.securityChecks.removeAll { sources.contains($0.source) }
        result.installedApps.removeAll { sources.contains($0.source) }
        result.networkListeners.removeAll { sources.contains($0.source) }
        result.mcpServers.removeAll { sources.contains($0.source) }
        result.agentAutoApprovals.removeAll { sources.contains($0.source) }
        result.sourceErrors.removeAll { sources.contains($0.source) }
        result.sourceLimitations.removeAll { sources.contains($0.source) }
        return result
    }
}
