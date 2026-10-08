import Foundation

/// Aktionen an MCP-Servern (Spec Agenten Stufe 2) – Ablauf wie bei Autostart: eingereiht, danach Prüfscan der Quelle
/// `agents`.
extension ActionCoordinator {
    /// Entfernt den Server samt Sicherung; bestätigt, wenn er im neuen Snapshot fehlt.
    public func removeServer(_ entry: MCPServerEntry) async -> ActionOutcome {
        let check = Check(
            source: .agents,
            unconfirmed: .doneButUnverified("Der Server ist im neuen Scan noch eingetragen."),
            effectiveDespiteFailure: Self.agentEffectiveDespiteFailure(
                otherwise: "\(Self.effectiveDespiteFailure) Kein Wiederherstellungsbeleg vorhanden."
            )
        ) { snapshot in !snapshot.mcpServers.contains { $0.id == entry.id } }
        return await perform(check) { [agentConfigs] in
            _ = try await agentConfigs.removeServer(entry)
            return nil
        }
    }

    /// Aktiviert/deaktiviert den Server; bestätigt, wenn er im neuen Snapshot den gewünschten Zustand hat.
    public func setServerEnabled(_ entry: MCPServerEntry, _ enabled: Bool) async -> ActionOutcome {
        let check = Check(
            source: .agents,
            unconfirmed: .doneButUnverified("Die Änderung ist im neuen Scan noch nicht zu sehen."),
            effectiveDespiteFailure: Self.agentEffectiveDespiteFailure(otherwise: Self.effectiveDespiteFailure)
        ) { snapshot in
            snapshot.mcpServers.contains { $0.id == entry.id && $0.isEnabled == enabled }
        }
        return await perform(check) { [agentConfigs] in
            _ = try await agentConfigs.setEnabled(entry, enabled)
            return nil
        }
    }

    /// Nimmt die Änderung zurück; bestätigt, wenn der Server wieder (im früheren Zustand) im neuen Snapshot steht.
    /// Stand er schon wieder so in der Datei, ist das Ergebnis ein Hinweis statt eines Fehlers – auch, wenn das
    /// Wiederherstellen scheitert, der Scan den früheren Zustand aber zeigt (der Beleg bleibt dann erhalten). Ausnahme:
    /// Fehler, die belegen, dass nichts wiederhergestellt wurde (`restoreFailureRulesOutEffect`) – ein gleichnamiger
    /// Server im Scan ist dann ein anderer, und die echte Meldung zählt.
    public func restoreAgentChange(_ change: AgentConfigChange) async -> ActionOutcome {
        var check = Check(
            source: .agents,
            unconfirmed: .doneButUnverified("Wiederhergestellt, aber im neuen Scan noch nicht zu sehen."),
            effectiveDespiteFailure: Self.agentEffectiveDespiteFailure(
                otherwise: "\(change.label) stand bereits so in der Datei; der Beleg bleibt erhalten."
            )
        ) { snapshot in
            snapshot.mcpServers.contains { entry in
                guard entry.id == change.server.entryID else { return false }
                if case .setEnabled(let enabled) = change.kind { return entry.isEnabled == !enabled }
                return true
            }
        }
        check.failureRulesOutEffect = Self.restoreFailureRulesOutEffect
        return await perform(check) { [agentConfigs] in
            switch try await agentConfigs.restore(changeID: change.id) {
            case .alreadyRestored: "\(change.label) stand bereits wieder so in der Datei – nichts geändert."
            case .restoredFile, .revertedEntry: nil
            }
        }
    }

    /// Wiederherstellen scheiterte nachweislich ohne Wirkung: anderer Server unter dem Namen (`nameTaken`), Eintrag
    /// nicht gezielt änderbar (`unsupportedLayout`) oder kein Beleg mehr (`changeNotFound`).
    static func restoreFailureRulesOutEffect(_ error: any Error) -> Bool {
        guard let error = error as? AgentConfigEditError else { return false }
        return [.nameTaken, .unsupportedLayout, .changeNotFound].contains(error)
    }

    /// Hinweis nach einem Fehler, dessen Änderung trotzdem wirksam ist: Hat der Fehler die Datei nachweislich geändert
    /// (`replacedUnverified`), sagt sein eigener Text, was gilt – Sicherung und Beleg bleiben dann erhalten; sonst
    /// `otherwise`.
    private static func agentEffectiveDespiteFailure(otherwise: String) -> @Sendable (any Error) -> String {
        { error in
            if let error = error as? AgentConfigEditError, !error.leavesFileUnchanged { return message(for: error) }
            return otherwise
        }
    }
}
