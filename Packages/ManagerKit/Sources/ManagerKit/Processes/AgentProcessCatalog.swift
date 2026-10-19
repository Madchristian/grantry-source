import Foundation

/// Welche Prozesse zu KI-Agenten gehören (#221). Reine Daten wie der `AgentToolCatalog` (#129): Ein neues Muster ist ein
/// neuer Eintrag in `standard`, ohne Änderung am `OrphanAgentTreeDetector`.
///
/// - `orphanRoots`: Muster, deren Prozess mit Elternprozess launchd (ppid 1) als verwaister Agenten-Baum gilt.
/// - `sessions`: laufende Agenten-Sitzungen (Claude Code, Codex CLI). Ein Baum mit einer Sitzung wird nie angeboten,
///   ebenso ein von Sitzungen geteilter Prozess (`isSharedAcrossSessions`), solange eine Sitzung in seinem
///   Arbeitsordner läuft.
public struct AgentProcessCatalog: Hashable, Sendable {
    public let orphanRoots: [AgentProcessPattern]
    public let sessions: [AgentProcessPattern]

    public init(orphanRoots: [AgentProcessPattern], sessions: [AgentProcessPattern]) {
        self.orphanRoots = orphanRoots
        self.sessions = sessions
    }

    func orphanPattern(for entry: ProcessEntry) -> AgentProcessPattern? {
        orphanRoots.first { $0.matches(entry) }
    }

    func isSession(_ entry: ProcessEntry) -> Bool {
        sessions.contains { $0.matches(entry) }
    }
}

/// Ein Prozessmuster; es passt, wenn eine seiner Regeln passt.
public struct AgentProcessPattern: Hashable, Sendable, Identifiable {
    /// Eine Regel über Programmpfad und Argumente. Namen sind letzte Pfadbestandteile.
    public enum Rule: Hashable, Sendable {
        /// Programm oder ein Argument endet auf diesen Pfad (z. B. `/scripts/app-server-broker.mjs`), und alle
        /// `containing`-Teile kommen darin vor.
        case path(suffix: String, containing: [String] = [])
        /// Programm oder ein Argument liegt unter diesem Ordnerteil (z. B. `/.claude/plugins/`).
        case pathContaining(String)
        /// Der Programmname (Programm, argv[0] oder bei Interpretern argv[1]) ist `name`, ein Argument ist `argument`
        /// (`nil`: beliebig) und keines der Argumente `excluding`.
        case command(name: String, argument: String? = nil, excluding: [String] = [])
        /// Ein Paketname (letzter Pfadbestandteil eines Arguments ohne `@Version`) endet auf `suffix` oder beginnt mit
        /// `prefix` – etwa `npx chrome-devtools-mcp@latest` oder `mcp-server-postgres`.
        case package(suffix: String? = nil, prefix: String? = nil)
    }

    public let id: String
    public let displayName: String
    public let rules: [Rule]
    /// Mehrere Sitzungen teilen sich den Prozess (Codex-Broker je Arbeitsordner): Er ist trotz ppid 1 in Benutzung,
    /// solange eine Sitzung im selben Arbeitsordner läuft.
    public let isSharedAcrossSessions: Bool
    /// Argument, dessen Wert der Arbeitsordner ist (`--cwd`); sonst der Arbeitsordner des Prozesses.
    public let workspaceArgument: String?

    public init(id: String, displayName: String, rules: [Rule], isSharedAcrossSessions: Bool = false,
                workspaceArgument: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.rules = rules
        self.isSharedAcrossSessions = isSharedAcrossSessions
        self.workspaceArgument = workspaceArgument
    }

    func matches(_ entry: ProcessEntry) -> Bool {
        rules.contains { Self.rule($0, matches: entry) }
    }

    /// Arbeitsordner laut `workspaceArgument`, sonst der des Prozesses.
    func workspace(of entry: ProcessEntry) -> String? {
        if let workspaceArgument, let index = entry.arguments.firstIndex(of: workspaceArgument),
           index + 1 < entry.arguments.count {
            return entry.arguments[index + 1]
        }
        return entry.workingDirectory
    }

    private static func rule(_ rule: Rule, matches entry: ProcessEntry) -> Bool {
        let paths = [entry.executablePath] + entry.arguments
        switch rule {
        case .path(let suffix, let containing):
            return paths.contains { path in path.hasSuffix(suffix) && containing.allSatisfy(path.contains) }
        case .pathContaining(let part):
            return paths.contains { $0.contains(part) }
        case .command(let name, let argument, let excluding):
            let arguments = entry.arguments.dropFirst()
            return programNames(of: entry).contains(name)
                && (argument.map(arguments.contains) ?? true)
                && !excluding.contains(where: arguments.contains)
        case .package(let suffix, let prefix):
            return entry.arguments.contains { argument in
                let name = packageName(argument)
                return (suffix.map(name.hasSuffix) ?? false) || (prefix.map(name.hasPrefix) ?? false)
            }
        }
    }

    /// Programm, argv[0] und – bei einem Pfad als argv[1] (Interpreter wie `node`, `bun`) – argv[1].
    private static func programNames(of entry: ProcessEntry) -> Set<String> {
        var names: Set<String> = [ProcessEntry.lastComponent(entry.executablePath)]
        if let first = entry.arguments.first { names.insert(ProcessEntry.lastComponent(first)) }
        if entry.arguments.count > 1, entry.arguments[1].hasPrefix("/") {
            names.insert(ProcessEntry.lastComponent(entry.arguments[1]))
        }
        return names
    }

    /// `/x/node_modules/@scope/pkg@1.2` → `pkg`; `chrome-devtools-mcp@latest` → `chrome-devtools-mcp`.
    static func packageName(_ argument: String) -> String {
        let last = ProcessEntry.lastComponent(argument)
        guard let at = last.dropFirst().firstIndex(of: "@") else { return last }
        return String(last[..<at])
    }
}

extension AgentProcessCatalog {
    /// Codex-Plugin für Claude Code (Broker und App-Server), MCP-Server aus Claude-Code-Plugins und per `npx`/Paket
    /// gestartete MCP-Server; Sitzungen von Claude Code und Codex CLI.
    public static let standard = AgentProcessCatalog(
        orphanRoots: [
            AgentProcessPattern(
                id: "codexBroker", displayName: "Codex-Broker (Claude-Code-Plugin)",
                rules: [.path(suffix: "/app-server-broker.mjs", containing: ["/openai-codex/"])],
                isSharedAcrossSessions: true, workspaceArgument: "--cwd"
            ),
            AgentProcessPattern(
                id: "codexAppServer", displayName: "Codex App-Server",
                rules: [.command(name: "codex", argument: "app-server")]
            ),
            AgentProcessPattern(
                id: "claudePluginServer", displayName: "Claude-Code-Plugin-Server",
                rules: [.pathContaining("/.claude/plugins/")]
            ),
            AgentProcessPattern(
                id: "mcpServer", displayName: "MCP-Server",
                rules: [.package(suffix: "-mcp"), .package(prefix: "mcp-server"), .package(suffix: "-mcp-server")]
            ),
        ],
        sessions: [
            AgentProcessPattern(
                id: "claudeCode", displayName: "Claude Code",
                rules: [.command(name: "claude"), .pathContaining("/@anthropic-ai/claude-code/")]
            ),
            AgentProcessPattern(
                id: "codexCLI", displayName: "Codex CLI",
                rules: [.command(name: "codex", excluding: ["app-server", "mcp-server"])]
            ),
        ]
    )
}
