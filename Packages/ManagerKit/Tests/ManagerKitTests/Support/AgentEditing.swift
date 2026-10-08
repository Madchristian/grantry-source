import Foundation
@testable import ManagerKit

/// Bausteine für Tests der Stufe 2 (Ändern von Agenten-Konfigurationen): Referenzen auf Katalogdateien unter einem
/// festen Home, Editor und Ausführen einer Änderung auf Text.
enum AgentEditing {
    static let home = "/Users/test"

    /// Referenz auf einen Server in einer Katalogdatei des Standardkatalogs.
    static func reference(
        _ name: String, tool: String = "claudeDesktop", path: String = "~/Library/Application Support/Claude/claude_desktop_config.json",
        scope: AgentScope = .user, registryPath: String? = nil
    ) -> AgentServerReference {
        let expanded = path.hasPrefix("~/") ? home + path.dropFirst() : path
        let toolName = AgentToolCatalog.standard.tool(id: tool)?.displayName ?? tool
        return AgentServerReference(toolID: tool, toolName: toolName, configPath: expanded, registryPath: registryPath,
                                    scope: scope, name: name)
    }

    static func editor(_ reference: AgentServerReference) throws -> AgentConfigEditor {
        AgentConfigEditor(target: try AgentServerTarget(reference: reference, catalog: .standard, home: home))
    }

    /// `operation` auf `text`; ohne Erwartung an den angezeigten Eintrag.
    static func apply(_ operation: AgentConfigEditor.Operation, to text: String, _ reference: AgentServerReference) throws -> String {
        String(decoding: try editor(reference).apply(operation, expected: nil, to: Data(text.utf8)), as: UTF8.self)
    }

    static let codex = (tool: "codex", path: "~/.codex/config.toml")
    static let windsurf = (tool: "windsurf", path: "~/.codeium/windsurf/mcp_config.json")
    static let vscodeSettings = (tool: "vscode", path: "~/Library/Application Support/Code/User/settings.json")
    static let claudeCode = (tool: "claudeCode", path: "~/.claude.json")
}
