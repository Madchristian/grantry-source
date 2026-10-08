// MARK: - Agenten (#129)

/// Texte enden ohne Punkt, weil sie oft mit Befehlen oder Werten enden.
extension ChangeDescription {
    static func describe(_ kind: ChangeEvent.Kind, server: MCPServerEntry, previous: MCPServerEntry?) -> Self {
        let subject = "„\(server.name)“ in \(server.locationDescription)"
        switch kind {
        case .added:
            return Self(title: "Neuer MCP-Server", body: "\(subject): \(server.summary)")
        case .modified:
            return Self(title: "MCP-Server geändert", body: "\(subject): \(change(from: previous, to: server))")
        case .removed:
            return Self(title: "MCP-Server entfernt", body: "„\(server.name)“ aus \(server.locationDescription) entfernt")
        }
    }

    static func describe(_ kind: ChangeEvent.Kind, approval: AgentAutoApproval, previous: AgentAutoApproval?) -> Self {
        let place = approval.locationDescription
        switch kind {
        case .added:
            return Self(title: "Automatische Freigabe aktiv",
                        body: "\(place): \(approval.setting) = \(approval.value) – \(approval.message)")
        case .modified:
            let before = previous?.value ?? "?"
            return Self(title: "Automatische Freigabe geändert", body: "\(place): \(approval.setting) \(before) → \(approval.value)")
        case .removed:
            return Self(title: "Automatische Freigabe entfernt", body: "\(place): \(approval.setting) = \(approval.value) ist nicht mehr aktiv")
        }
    }

    /// „npx pkg → npx pkg@2.0.0, deaktiviert“.
    private static func change(from previous: MCPServerEntry?, to server: MCPServerEntry) -> String {
        guard let previous else { return server.summary }
        var parts: [String] = []
        if server.transportDiffers(from: previous) { parts.append(transportChange(from: previous, to: server)) }
        if server.secretTransportDiffers(from: previous) { parts.append(maskedCommandChanged) }
        let isProjectFile = server.registryPath != nil
        if let switchChange = switchChange(from: previous.isEnabled, to: server.isEnabled, isProjectFile: isProjectFile) {
            parts.append(switchChange)
        }
        return parts.isEmpty ? "geändert" : parts.joined(separator: ", ")
    }

    /// „npx pkg → npx pkg@2.0.0“; sind die (gekürzten) Zusammenfassungen gleich, die Verbindungsart bzw. ein
    /// allgemeiner Hinweis.
    private static func transportChange(from previous: MCPServerEntry, to server: MCPServerEntry) -> String {
        guard previous.summary == server.summary else { return "\(previous.summary) → \(server.summary)" }
        switch (previous.transport, server.transport) {
        case (.remote(_, let before), .remote(_, let after)) where before != after:
            return "Verbindungsart \(before ?? "ohne Angabe") → \(after ?? "ohne Angabe")"
        case (_, .remote):
            return "Adresse geändert"
        case (_, .local):
            return "Befehl geändert"
        }
    }

    /// Wechsel des Schalters. Bei Servern aus Projektdateien (`isProjectFile`) heißt `nil` „Freigabe ausstehend“,
    /// sonst „Format ohne Schalter“ – der Server läuft dann, `nil` zählt also wie `true`.
    private static func switchChange(from previous: Bool?, to current: Bool?, isProjectFile: Bool) -> String? {
        guard isProjectFile else {
            let (before, after) = (previous ?? true, current ?? true)
            return before == after ? nil : (after ? "aktiviert" : "deaktiviert")
        }
        switch (previous, current) {
        case (true, false): return "deaktiviert"
        case (false, true): return "aktiviert"
        case (nil, true): return "freigegeben"
        case (nil, false): return "abgelehnt"
        case (.some, nil): return "Freigabe ausstehend"
        case (true, true), (false, false), (nil, nil): return nil
        }
    }
}

extension ChangeSubject {
    var mcpServer: MCPServerEntry? {
        if case .mcpServer(let server) = self { server } else { nil }
    }

    var agentAutoApproval: AgentAutoApproval? {
        if case .agentAutoApproval(let approval) = self { approval } else { nil }
    }
}
