import Foundation

/// Aktionen an MCP-Servern und das Wiederherstellen aus dem Verlauf (Spec Agenten Stufe 2).
extension ActionRunner {
    /// Entfernt den Server (nach Bestätigung); `runningRecordID` ist seine `id`.
    public func removeServer(_ entry: MCPServerEntry, context: ActionContext) async {
        await run(recordID: entry.id, context: context) { coordinator in
            await coordinator.removeServer(entry)
        } present: { outcome in
            .removeServer(entry, outcome: outcome)
        }
    }

    /// Aktiviert bzw. deaktiviert den Server (nach Bestätigung).
    public func setServerEnabled(_ entry: MCPServerEntry, _ enabled: Bool, context: ActionContext) async {
        await run(recordID: entry.id, context: context) { coordinator in
            await coordinator.setServerEnabled(entry, enabled)
        } present: { outcome in
            .setServerEnabled(entry, enabled, outcome: outcome)
        }
    }

    /// Nimmt eine Änderung an einer Agenten-Konfiguration zurück (nach Bestätigung); `runningRecordID` ist die
    /// Beleg-ID.
    public func restore(_ change: AgentConfigChange, context: ActionContext) async {
        await run(recordID: change.id.uuidString, context: context) { coordinator in
            await coordinator.restoreAgentChange(change)
        } present: { outcome in
            .restore(change, outcome: outcome)
        }
    }

    /// Stellt aus einem Beleg des Verlaufs wieder her – Autostart oder Agenten-Konfiguration.
    public func restore(_ restorable: RestorableChange, context: ActionContext) async {
        switch restorable {
        case .autostart(let entry): await restore(entry, context: context)
        case .agentConfig(let change): await restore(change, context: context)
        }
    }
}
