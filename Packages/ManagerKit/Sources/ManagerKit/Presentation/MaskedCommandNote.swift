/// Hinweis unter einem maskiert angezeigten Befehl (#137): ein ganz verborgenes Shell-Skript oder einzelne maskierte
/// Werte.
public enum MaskedCommandNote {
    public static let hiddenScript = "Skript enthält mögliche Zugangsdaten und wird verborgen."
    public static let maskedValues = "Zugangsdaten sind maskiert (•••)."

    /// `hiddenScript`, wenn ein Skript in `arguments` ganz maskiert ist (`ShellSyntax.hasHiddenScript`); sonst
    /// `maskedValues`, wenn etwas maskiert wurde; sonst `nil`.
    static func text(for arguments: [String], program: String?, isMasked: Bool, hasHiddenScript: Bool = false) -> String? {
        if hasHiddenScript || ShellSyntax.hasHiddenScript(in: arguments, program: program) { return hiddenScript }
        return isMasked ? maskedValues : nil
    }
}
