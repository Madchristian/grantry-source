import Foundation

/// Risiko einer Speicher-Kategorie; bestimmt Löschweg und Vorauswahl (Spec Speicher §1).
public enum StorageRisk: String, Hashable, Sendable, Codable {
    case low, medium, reportOnly
}

/// Offizieller Aufräumbefehl mit festem Programmpfad (nie über `PATH` gesucht).
public struct CommandSpec: Hashable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    public var commandLine: String { ([executable] + arguments).joined(separator: " ") }

    /// Fester Grund-`PATH` für jeden Befehl; eine aus dem Finder gestartete App erbt den von launchd.
    static let basePath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// Läuft über `/usr/bin/env` mit eigenem `PATH`: Ordner des Programms vor dem Grund-`PATH`, damit z. B.
    /// `#!/usr/bin/env node` das `node` neben npm findet. Einheitlich für alle Befehle (Speicher, Simulatoren) und
    /// sichtbar in der Bestätigung.
    static func tool(_ executable: String, _ arguments: [String]) -> CommandSpec {
        let directory = (executable as NSString).deletingLastPathComponent
        return CommandSpec(executable: "/usr/bin/env", arguments: ["PATH=" + directory + ":" + basePath, executable] + arguments)
    }
}

/// Wie ein Eintrag entfernt wird.
public enum RemovalMethod: Hashable, Sendable {
    case trash, delete, command(CommandSpec), none

    /// Weg im `StorageCleanOutcome`.
    var outcomeMethod: StorageCleanOutcome.Method {
        switch self {
        case .trash: .trash
        case .delete: .delete
        case .command: .command
        case .none: .none
        }
    }
}

/// Beschreibung einer Kategorie. `roots`: Ordner, unter denen ihre Einträge liegen dürfen (`StoragePathGuard`).
public struct StorageCategory: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let risk: StorageRisk
    public let roots: [String]
    /// Sperre durch laufende Prozesse (DerivedData: Builds, #226); `nil` ohne.
    public let processLock: ProcessLock?

    public init(id: String, title: String, summary: String, risk: StorageRisk, roots: [String],
                processLock: ProcessLock? = nil) {
        self.id = id
        self.title = title
        self.summary = summary
        self.risk = risk
        self.roots = roots
        self.processLock = processLock
    }
}

/// Sperre von Einträgen durch laufende Prozesse (#226, DerivedData während eines Builds).
public struct ProcessLock: Hashable, Sendable {
    /// Prozessnamen (`p_comm`); ihre Unterprozesse zählen mit.
    public let processes: Set<String>
    /// Namen der Einträge, die genau einem Vorgang gehören (DerivedData: `<Projekt>-<28 Kleinbuchstaben>`); sie sperrt nur
    /// eine offene Datei darin. Alle übrigen – geteilte Caches wie `ModuleCache.noindex`, die Compiler nur kurz öffnen
    /// oder bloß einblenden – sperrt schon ein laufender Prozess. `nil`: Jeder Eintrag gehört einem Vorgang.
    public let ownedEntryPattern: String?

    public init(processes: Set<String>, ownedEntryPattern: String? = nil) {
        self.processes = processes
        self.ownedEntryPattern = ownedEntryPattern
    }

    /// Geteilt, wenn ein Muster gilt und der Name nicht passt; ein ungültiges Muster zählt als geteilt (fail-closed).
    func isShared(_ name: String) -> Bool {
        guard let ownedEntryPattern else { return false }
        guard let regex = try? Regex(ownedEntryPattern) else { return true }
        return name.wholeMatch(of: regex) == nil
    }
}

/// Ein Eintrag einer Kategorie: Ordner oder Befehl.
public struct StorageItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let path: String?
    public var size: FileSize
    public let removal: RemovalMethod
    public let isPreselected: Bool
    /// Befehl zum Kopieren (Nur-Bericht, z. B. Time Machine).
    public let hint: String?
    /// Zweite Zeile, z. B. „Zuletzt benutzt vor 3 Tagen“ oder „Wird gerade benutzt von xcodebuild“.
    public let detail: String?
    /// Der Befehl entfernt den ganzen Eintrag (Simulator-Laufzeit); seine Größe ist dann kein Bestand wie bei
    /// `uv cache prune`, von dem der Befehl nur Ungenutztes freigibt.
    public let commandRemovesItem: Bool
    /// Das Objekt beim Scan; vor dem Entfernen muss es noch dasselbe sein (`StoragePathGuard`).
    let identity: FileIdentity?

    init(id: String, title: String, path: String?, size: FileSize, removal: RemovalMethod, isPreselected: Bool,
         hint: String? = nil, detail: String? = nil, commandRemovesItem: Bool = false, identity: FileIdentity? = nil) {
        self.id = id
        self.title = title
        self.path = path
        self.size = size
        self.removal = removal
        self.isPreselected = isPreselected
        self.hint = hint
        self.detail = detail
        self.commandRemovesItem = commandRemovesItem
        self.identity = identity
    }

    /// Nur-Bericht-Einträge sind nicht wählbar.
    public var isSelectable: Bool { removal != .none }
    /// „1,2 GB“, „Größe unbekannt“, „Größe nicht lesbar“ (`RemovalSize.text`).
    public var sizeText: String { RemovalSize(sizes: [size]).text }
}

public enum StorageCategoryStatus: Hashable, Sendable {
    case available, notInstalled, needsFullDiskAccess, failed(String)
}

/// Ergebnis des Scans einer Kategorie.
public struct StorageCategoryReport: Identifiable, Hashable, Sendable {
    public let category: StorageCategory
    public let status: StorageCategoryStatus
    public let items: [StorageItem]
    /// Ordner, die sich nicht lesen ließen (etwa ohne Festplattenvollzugriff); ihr Inhalt fehlt in `items`.
    public let unreadablePaths: [String]

    public init(category: StorageCategory, status: StorageCategoryStatus, items: [StorageItem],
                unreadablePaths: [String] = []) {
        self.category = category
        self.status = status
        self.items = items
        self.unreadablePaths = unreadablePaths
    }

    public var id: String { category.id }
    /// Nicht erfasste Orte: unlesbare Ordner und Einträge mit nicht lesbarer Größe (#226).
    public var uncoveredPaths: [String] {
        unreadablePaths + items.filter { $0.size == .unreadable }.compactMap(\.path)
    }
    var size: RemovalSize { RemovalSize(sizes: items.map(\.size)) }
    /// „1,2 GB“, „mindestens 1,2 GB“, „Größe unbekannt“ (`RemovalSize.text`).
    public var sizeText: String { size.text }
    /// Gezählte Bytes, für die Sortierung.
    public var knownBytes: Int64 { size.known }
}

/// Ausgang je Eintrag; auch Zeile im `CleanupLog`.
public struct StorageCleanOutcome: Hashable, Sendable, Codable {
    public enum Method: String, Hashable, Sendable, Codable {
        /// `signal`: Prozesse beendet (Segment „Prozesse“, #221).
        case trash, delete, command, signal, none
    }

    public enum Result: Hashable, Sendable, Codable {
        case removed
        case skipped(String)
        case failed(String)
    }

    public let categoryID: String
    /// Pfad oder Befehlszeile.
    public let target: String
    public let method: Method
    /// `nil`: nicht bestimmbar (z. B. Docker).
    public let freedBytes: Int64?
    public let result: Result

    public init(categoryID: String, target: String, method: Method, freedBytes: Int64?, result: Result) {
        self.categoryID = categoryID
        self.target = target
        self.method = method
        self.freedBytes = freedBytes
        self.result = result
    }
}
