import Foundation

/// Texte der Aktionen an MCP-Servern (Spec Agenten Stufe 2).
extension ActionConfirmation {
    public static func removeServer(
        _ entry: MCPServerEntry, capabilities: AgentEditCapabilities, home: String = NSHomeDirectory()
    ) -> ActionConfirmation {
        ActionConfirmation(
            title: "„\(entry.name)“ aus \(entry.locationDescription) entfernen?",
            message: "Grantry entfernt nur diesen Eintrag aus \(PathDisplay.abbreviatingHome(entry.configPath, home: home)); alles "
                + "andere in der Datei bleibt unverändert. Die Datei wird vorher gesichert und lässt sich im Verlauf "
                + "wiederherstellen.",
            note: capabilities.restartNote,
            confirmTitle: "Entfernen",
            isDestructive: true
        )
    }

    public static func setServerEnabled(
        _ entry: MCPServerEntry, _ enabled: Bool, capabilities: AgentEditCapabilities, home: String = NSHomeDirectory()
    ) -> ActionConfirmation {
        ActionConfirmation(
            title: "„\(entry.name)“ in \(entry.locationDescription) \(enabled ? "aktivieren" : "deaktivieren")?",
            message: "Grantry ändert nur den Schalter dieses Eintrags in \(PathDisplay.abbreviatingHome(entry.configPath, home: home)). "
                + "Die Datei wird vorher gesichert.",
            note: capabilities.restartNote,
            confirmTitle: enabled ? "Aktivieren" : "Deaktivieren",
            isDestructive: false
        )
    }

    /// Nennt Ort (Tool und Bereich) und Datei, damit klar ist, wohin zurückgelegt wird.
    public static func restore(
        _ change: AgentConfigChange, capabilities: AgentEditCapabilities, home: String = NSHomeDirectory()
    ) -> ActionConfirmation {
        let server = change.server
        let location = "\(server.locationDescription) (\(PathDisplay.abbreviatingHome(server.configPath, home: home)))"
        let what = switch change.kind {
        case .removedServer: "trägt den entfernten Server wieder in \(location) ein"
        case .setEnabled(let enabled): "stellt den Server in \(location) wieder auf „\(enabled ? "deaktiviert" : "aktiviert")“"
        }
        return ActionConfirmation(
            title: "\(change.label) wiederherstellen?",
            message: "Grantry \(what). Ist die Datei seit der Änderung unverändert, wird die gesicherte Fassung "
                + "zurückgelegt; sonst ändert Grantry nur diesen Eintrag.",
            note: capabilities.restartNote,
            confirmTitle: "Wiederherstellen",
            isDestructive: false
        )
    }

    /// Bestätigung für einen Beleg aus dem Verlauf.
    public static func restore(_ restorable: RestorableChange, home: String = NSHomeDirectory()) -> ActionConfirmation {
        switch restorable {
        case .autostart(let entry): restore(entry)
        case .agentConfig(let change):
            restore(change, capabilities: AgentEditCapabilities(reference: change.server, isEnabled: nil, home: home), home: home)
        }
    }
}

extension ActionOutcomePresentation {
    /// Ergebnis von `ActionCoordinator.removeServer(_:)`.
    public static func removeServer(
        _ entry: MCPServerEntry, outcome: ActionOutcome, home: String = NSHomeDirectory()
    ) -> ActionOutcomePresentation {
        ActionOutcomePresentation(outcome, successMessage: "„\(entry.name)“ wurde aus \(entry.locationDescription) entfernt. "
            + "\(entry.editCapabilities(home: home).restartNote) Wiederherstellen ist im Verlauf möglich.")
    }

    /// Ergebnis von `ActionCoordinator.setServerEnabled(_:_:)`.
    public static func setServerEnabled(
        _ entry: MCPServerEntry, _ enabled: Bool, outcome: ActionOutcome, home: String = NSHomeDirectory()
    ) -> ActionOutcomePresentation {
        ActionOutcomePresentation(outcome, successMessage: "„\(entry.name)“ wurde \(enabled ? "aktiviert" : "deaktiviert"). "
            + entry.editCapabilities(home: home).restartNote)
    }

    /// Ergebnis von `ActionCoordinator.restoreAgentChange(_:)`.
    public static func restore(
        _ change: AgentConfigChange, outcome: ActionOutcome, home: String = NSHomeDirectory()
    ) -> ActionOutcomePresentation {
        ActionOutcomePresentation(outcome, successMessage: "\(change.label) wurde wiederhergestellt. "
            + AgentEditCapabilities(reference: change.server, isEnabled: nil, home: home).restartNote)
    }
}
