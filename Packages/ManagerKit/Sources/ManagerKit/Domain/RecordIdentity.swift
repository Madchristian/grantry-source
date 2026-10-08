import Foundation

/// Baut die Identität (`id`) eines Eintrags aus mehreren Komponenten, ohne dass Trennzeichen in den Komponenten zu
/// Kollisionen führen können.
enum RecordIdentity {
    /// Trennzeichen zwischen den Komponenten.
    private static let separator = "|"
    /// Schutzzeichen vor Trennzeichen und vor sich selbst.
    private static let escape = "\\"

    /// Maskiert in jeder Komponente `\` zu `\\` und `|` zu `\|` und verbindet sie mit `|`. Für gewöhnliche Werte
    /// (ohne diese beiden Zeichen) ist das Ergebnis schlicht `a|b|c`.
    static func join(_ parts: [String]) -> String {
        parts.map(masked).joined(separator: separator)
    }

    private static func masked(_ part: String) -> String {
        part
            .replacingOccurrences(of: escape, with: escape + escape)
            .replacingOccurrences(of: separator, with: escape + separator)
    }
}
