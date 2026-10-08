/// Befehlszeilen zum Anzeigen und Kopieren (#137): Argumente, die eine POSIX-Shell zerlegen oder auswerten würde,
/// stehen in einfachen Anführungszeichen, ein `'` darin als `'\''`. Eingefügt in eine Shell ergibt die Zeile also genau
/// die angezeigten Argumentgrenzen. Maskierte Werte (`•••`) und andere Nicht-ASCII-Zeichen bleiben unquotiert.
public enum ShellQuoting {
    /// Zeichen, die eine Shell in einem ungequoteten Wort besonders behandelt (Leerraum prüft `quoted(_:)` gesondert).
    private static let specialCharacters: Set<Character> = [
        "'", "\"", "\\", "$", "`", ";", "&", "|", "<", ">", "(", ")", "*", "?", "[", "]", "{", "}", "~", "#", "!",
    ]

    /// `words` als eine Zeile, jedes Wort nach `quoted(_:)`.
    public static func commandLine(_ words: [String]) -> String {
        words.map(quoted).joined(separator: " ")
    }

    /// Das Wort unverändert, wenn die Shell es so übernähme; sonst in einfachen Anführungszeichen. Ein leeres Wort
    /// wird `''`.
    public static func quoted(_ word: String) -> String {
        let needsQuoting = word.isEmpty || word.contains { $0.isWhitespace || specialCharacters.contains($0) }
        guard needsQuoting else { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
