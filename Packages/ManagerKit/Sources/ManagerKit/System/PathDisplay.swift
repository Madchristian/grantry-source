import Foundation

/// Pfade für Protokolle und Texte: der Benutzerordner (samt Kontonamen) als `~`.
public enum PathDisplay {
    /// `path` mit `~` statt `home`, wenn er dort liegt (ganze Pfadbestandteile); sonst unverändert.
    public static func abbreviatingHome(_ path: String, home: String = NSHomeDirectory()) -> String {
        let home = trimmingTrailingSlashes(home)
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// `text` mit `~` statt `home` in jedem Pfad darin (Hinweistexte wie „… nicht lesbar (/Users/x/.claude.json)“). Ein
    /// Pfad beginnt am Textanfang oder nach Leerraum, „(“, „„“ bzw. `"`; `home` zählt nur als ganzer Pfadbestandteil.
    public static func abbreviatingHomePaths(in text: String, home: String = NSHomeDirectory()) -> String {
        let home = trimmingTrailingSlashes(home)
        guard !home.isEmpty else { return text }
        var result = ""
        var rest = text.startIndex
        var searchStart = text.startIndex
        while let range = text.range(of: home, range: searchStart..<text.endIndex) {
            searchStart = range.upperBound
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            guard before.map(isPathOpener) ?? true, after.map(isComponentEnd) ?? true else { continue }
            result += text[rest..<range.lowerBound] + "~"
            rest = range.upperBound
        }
        return result + text[rest...]
    }

    /// `path` ohne abschließende `/` (`/Users/x/` → `/Users/x`; `/` → leer).
    static func trimmingTrailingSlashes(_ path: String) -> String {
        var path = Substring(path)
        while path.hasSuffix("/") { path = path.dropLast() }
        return String(path)
    }

    private static func isPathOpener(_ character: Character) -> Bool {
        character.isWhitespace || "(„\"".contains(character)
    }

    /// Ende eines Pfadbestandteils: `/`, Leerraum oder ein Zeichen, das in Hinweistexten auf einen Pfad folgt.
    private static func isComponentEnd(_ character: Character) -> Bool {
        character.isWhitespace || "/)“\":,.".contains(character)
    }
}
