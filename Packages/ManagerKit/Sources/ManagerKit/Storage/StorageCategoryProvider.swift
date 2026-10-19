import Foundation

/// Eine Kategorie des Speicher-Aufräumens; liest nur. Entfernt wird zentral im `StorageRemover`.
public protocol StorageCategoryProvider: Sendable {
    var category: StorageCategory { get }
    func scan() async -> StorageCategoryReport
}

/// Findet Werkzeuge nur an festen Orten, nie über `PATH` (Spec Speicher §1).
struct ToolLocator: Sendable {
    let home: String
    let isExecutable: @Sendable (String) -> Bool
    /// Ob ein Ordner existiert (Symlinks werden nicht verfolgt); für Voraussetzungen wie den CoreSimulator-Ordner.
    let isDirectory: @Sendable (String) -> Bool

    init(home: String = NSHomeDirectory(),
         isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
         isDirectory: @escaping @Sendable (String) -> Bool = { FileIdentity.of($0)?.type == .directory }) {
        self.home = home
        self.isExecutable = isExecutable
        self.isDirectory = isDirectory
    }

    /// Erster ausführbarer Kandidat. Ohne `candidates`: Homebrew (Apple Silicon, Intel), dann `~/.local/bin`. Mit
    /// `candidates`: nur diese Pfade in der Reihenfolge, nie die Standardorte (z. B. nur `/usr/bin/xcrun`, damit ein
    /// untergeschobenes `~/.local/bin/xcrun` nicht läuft).
    func locate(_ tool: String, candidates: [String]? = nil) -> String? {
        let paths = candidates
            ?? ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin"].map { $0 + "/" + tool }
        return paths.first(where: isExecutable)
    }
}
