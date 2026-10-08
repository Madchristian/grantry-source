/// Ausgeführter Befehl vor und nach einer Änderung (#137): für den Verlauf und die Vorher/Nachher-Bilanz (#127), damit
/// ein Befehlswechsel bei gleichem Programm (`/bin/sh -c A` → `/bin/sh -c B`) sichtbar und kopierbar ist. Beide Zeilen
/// mit Shell-Quoting (`ShellQuoting`) und maskierten Geheimnissen.
public struct CommandChange: Hashable, Sendable {
    public let before: String
    public let after: String

    public init(before: String, after: String) {
        self.before = before
        self.after = after
    }

    /// `nil`, wenn eine Seite fehlt oder beide Zeilen gleich sind (etwa wenn sich nur ein maskiertes Geheimnis
    /// geändert hat – die Zeilen zeigten dann zweimal dasselbe).
    init?(before: String?, after: String?) {
        guard let before, let after, before != after else { return nil }
        self.init(before: before, after: after)
    }
}

extension ChangeEvent {
    /// Befehl vorher/nachher eines geänderten Autostart-Eintrags bzw. lokalen MCP-Servers; sonst `nil`.
    public var commandChange: CommandChange? {
        guard kind == .modified else { return nil }
        switch (before, after) {
        case (.autostartItem(let old)?, .autostartItem(let new)?):
            return CommandChange(before: old.commandLine, after: new.commandLine)
        case (.mcpServer(let old)?, .mcpServer(let new)?):
            return CommandChange(before: old.normalizedTransport.commandLine, after: new.normalizedTransport.commandLine)
        default:
            return nil
        }
    }
}
