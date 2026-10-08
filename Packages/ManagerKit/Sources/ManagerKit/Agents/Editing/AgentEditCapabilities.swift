import Foundation

/// Was sich an einem MCP-Server ändern lässt (Stufe 2) – ohne Dateizugriff, aus Bereich, Pfad und Katalog. Ob die Datei
/// selbst änderbar ist (Symlink, Eigentümer, Größe …), prüft erst die Aktion (`AgentConfigFileAccess`).
public struct AgentEditCapabilities: Hashable, Sendable {
    /// Ob „Server entfernen …“ (und ggf. der Schalter) angeboten wird.
    public let availability: ActionAvailability
    /// Ob das Format einen Schalter für diesen Server kennt.
    public let canSwitch: Bool
    /// Datei im Projektordner (`.mcp.json`) – oft versioniert.
    public let isProjectFile: Bool
    /// Das Tool schreibt die Datei laufend (Claude Code `~/.claude.json`): vorher beenden.
    public let toolRewritesFile: Bool
    public let toolName: String

    public init(reference: AgentServerReference, isEnabled: Bool?, catalog: AgentToolCatalog = .standard, home: String = NSHomeDirectory()) {
        self.init(reference: reference, isEnabled: isEnabled, target: try? AgentServerTarget(reference: reference, catalog: catalog, home: home),
                  home: home)
    }

    /// Mit bereits aufgelöstem Ziel (`nil`: Grantry kennt die Datei nicht) – ohne zweiten Katalog-Lookup.
    init(reference: AgentServerReference, isEnabled: Bool?, target: AgentServerTarget?, home: String) {
        toolName = reference.toolName
        isProjectFile = reference.registryPath != nil
        toolRewritesFile = target?.file.isRewrittenByTool == true && !isProjectFile
        if reference.scope == .system {
            availability = .readOnly(.managedConfiguration)
        } else if !AgentConfigReader.isInside(reference.configPath, home) {
            availability = .readOnly(.configurationOutsideHome)
        } else if target == nil {
            availability = .readOnly(.unknownConfiguration)
        } else {
            availability = .available
        }
        canSwitch = availability == .available && target?.switchKind != nil && isEnabled != nil
    }

    /// Hinweis zu Neustart und versionierten Projektdateien für Bestätigung und Ergebnis.
    public var restartNote: String {
        var note = toolRewritesFile
            ? "Beende \(toolName) vorher: Es schreibt diese Datei laufend und könnte die Änderung sonst überschreiben. Danach \(toolName) neu starten."
            : "\(toolName) übernimmt die Änderung erst nach einem Neustart."
        if isProjectFile {
            note += " Die Datei liegt im Projekt und ist oft versioniert – die Änderung erscheint dann auch dort."
        }
        return note
    }
}

extension MCPServerEntry {
    /// `AgentEditCapabilities` dieses Servers.
    public func editCapabilities(catalog: AgentToolCatalog = .standard, home: String = NSHomeDirectory()) -> AgentEditCapabilities {
        AgentEditCapabilities(reference: reference, isEnabled: isEnabled, catalog: catalog, home: home)
    }
}
