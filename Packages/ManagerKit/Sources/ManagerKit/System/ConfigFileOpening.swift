import Foundation

/// Ob Grantry eine Konfigurationsdatei zum Ansehen öffnen darf (Bereich „Agenten“, „Öffnen“). Geöffnet wird nur eine
/// reguläre Datei mit Endung `json`, `jsonc` oder `toml` – bei einem Symlink zählt das aufgelöste Ziel. So startet
/// „Öffnen“ nie ein Programm, Skript (`.command`) oder Bundle, auch nicht über einen umgebogenen Symlink.
public enum ConfigFileOpening {
    /// Endungen, die Grantry in einem Editor öffnet (Kleinschreibung).
    public static let editableExtensions: Set<String> = ["json", "jsonc", "toml"]

    public enum Verdict: Hashable, Sendable {
        /// Reguläre Datei mit erlaubter Endung; `url` ist das aufgelöste Ziel.
        case openable(URL)
        /// Die Datei bzw. das Ziel des Symlinks fehlt.
        case missing
        /// Keine reguläre Datei (Ordner, Bundle, Gerät …) oder eine andere Endung.
        case notEditable
    }

    /// Prüft `path` (auch mit `~`) per `lstat`, bei einem Symlink zusätzlich dessen aufgelöstes Ziel.
    public static func verdict(for path: String, home: String = NSHomeDirectory()) -> Verdict {
        let url = fileURL(for: path, home: home)
        guard let link = FileIdentity.of(url.path) else { return .missing }
        let target = link.type == .symbolicLink ? url.resolvingSymlinksInPath() : url
        // Bleibt nach dem Auflösen ein Symlink übrig, zeigt er ins Leere (oder im Kreis).
        guard let identity = FileIdentity.of(target.path), identity.type != .symbolicLink else { return .missing }
        guard identity.type == .regularFile, editableExtensions.contains(target.pathExtension.lowercased()) else {
            return .notEditable
        }
        return .openable(target)
    }

    /// `verdict(for:home:)` ohne Zugriff auf Netzlaufwerke – für die Anzeige auf dem Main-Thread, wo ein hängender
    /// Server die Oberfläche anhielte. `nil`, wenn `path` oder ein Symlink-Ziel auf einem nicht lokalen Volume liegt
    /// (oder die Symlink-Kette zu lang ist): Dann entscheidet erst `verdict` beim Öffnen.
    public static func verdictIfLocal(for path: String, home: String = NSHomeDirectory()) -> Verdict? {
        verdictIfLocal(for: path, home: home, volumes: MountedVolume.current())
    }

    static func verdictIfLocal(for path: String, home: String, volumes: [MountedVolume]) -> Verdict? {
        guard let target = LocalPathResolver.resolve(fileURL(for: path, home: home).path, volumes: volumes) else {
            return nil
        }
        switch target.entry {
        case .missing:
            return .missing
        case .regularFile:
            let url = URL(filePath: target.path)
            return editableExtensions.contains(url.pathExtension.lowercased()) ? .openable(url) : .notEditable
        default:
            return .notEditable
        }
    }

    /// Datei-URL zu `path`; ein führendes `~` steht für `home`.
    public static func fileURL(for path: String, home: String = NSHomeDirectory()) -> URL {
        if path == "~" { return URL(filePath: home) }
        guard path.hasPrefix("~/") else { return URL(filePath: path) }
        return URL(filePath: home).appending(path: String(path.dropFirst(2)))
    }
}
