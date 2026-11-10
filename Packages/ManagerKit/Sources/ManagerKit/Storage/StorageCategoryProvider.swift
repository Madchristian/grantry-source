import Foundation

/// Eine Kategorie des Speicher-Aufräumens; liest nur. Entfernt wird zentral im `StorageRemover`.
public protocol StorageCategoryProvider: Sendable {
    var category: StorageCategory { get }
    /// Ordner, deren Inhalt die Kategorie aufräumt oder meldet – für die Hinweise der Belegung (`OccupancyHints`).
    /// Standard: die Wurzeln der Kategorie mit allen Einträgen.
    var locations: [StorageCategoryLocation] { get }
    func scan() async -> StorageCategoryReport
}

extension StorageCategoryProvider {
    public var locations: [StorageCategoryLocation] { category.roots.map { StorageCategoryLocation(path: $0) } }
}

/// Ordner einer Kategorie (TM-15.3, #402). `includesEntry` entscheidet über die direkten Einträge (Name); tiefer
/// liegende Ordner gehören zu dem Eintrag, unter dem sie liegen.
public struct StorageCategoryLocation: Sendable {
    public let path: String
    let includesEntry: @Sendable (String) -> Bool

    init(path: String, includesEntry: @escaping @Sendable (String) -> Bool = { _ in true }) {
        self.path = path
        self.includesEntry = includesEntry
    }
}

/// Findet Werkzeuge nur an festen Orten, nie über `PATH` (Spec Speicher §1).
struct ToolLocator: Sendable {
    let home: String
    let isExecutable: @Sendable (String) -> Bool
    /// Ob ein Ordner existiert (Symlinks werden nicht verfolgt); für Voraussetzungen wie den CoreSimulator-Ordner.
    let isDirectory: @Sendable (String) -> Bool
    /// Wie ein gefundenes Werkzeug startet (liest den Dateianfang); `nil`: unklar.
    let kind: @Sendable (String) -> ExecutableKind?

    init(home: String = NSHomeDirectory(),
         isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
         isDirectory: @escaping @Sendable (String) -> Bool = { FileIdentity.of($0)?.type == .directory },
         kind: @escaping @Sendable (String) -> ExecutableKind? = ExecutableKind.of) {
        self.home = home
        self.isExecutable = isExecutable
        self.isDirectory = isDirectory
        self.kind = kind
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
