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

    /// Das eigentliche Werkzeug hinter dem festen env-Vorsatz; direkt konstruierte Specs bleiben möglich.
    var cleanupExecutable: String {
        if executable == "/usr/bin/env", arguments.count >= 2, arguments[0].hasPrefix("PATH="),
           arguments[1].hasPrefix("/") { return arguments[1] }
        return executable
    }

    /// Keine geerbten Interpreter-, Loader- oder Paketmanager-Overrides und keine Tokens aus der App-Umgebung. Variablen,
    /// die Ziel oder Ablageort wählen (`targetVariables`), bleiben erhalten: Der Befehl trifft denselben Docker-Daemon
    /// bzw. Cache wie ohne Reduktion (#252).
    func cleanupEnvironment(inheriting inherited: [String: String] = ProcessInfo.processInfo.environment)
        -> [String: String] {
        let directory = (cleanupExecutable as NSString).deletingLastPathComponent
        let tool = (cleanupExecutable as NSString).lastPathComponent
        var environment = inherited.filter { Self.sharedTargetVariables.contains($0.key)
            || Self.targetVariables[tool, default: []].contains($0.key) }
        environment.merge(["HOME": NSHomeDirectory(), "USER": NSUserName(), "LOGNAME": NSUserName(),
                           "PATH": directory + ":" + Self.basePath, "TMPDIR": NSTemporaryDirectory(),
                           "LANG": "en_US.UTF-8"]) { $1 }
        if tool == "brew" {
            environment["HOMEBREW_NO_AUTOREMOVE"] = "1"
            environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        }
        return environment
    }

    /// XDG-Basisordner legen Konfiguration, Daten und Caches mehrerer Werkzeuge fest (uv, pnpm, npm-Ableger).
    static let sharedTargetVariables: Set<String> = ["XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME"]

    /// Je Werkzeug nur Variablen für Ziel (Docker-Daemon) und Ablageort, keine Ausführungs-Overrides (Hooks, Optionen).
    static let targetVariables: [String: Set<String>] = [
        "docker": ["DOCKER_CONTEXT", "DOCKER_HOST", "DOCKER_CONFIG", "DOCKER_TLS", "DOCKER_TLS_VERIFY",
                   "DOCKER_CERT_PATH"],
        "brew": ["HOMEBREW_CACHE", "HOMEBREW_LOGS", "HOMEBREW_TEMP"],
        "npm": ["npm_config_cache", "NPM_CONFIG_CACHE"],
        "pnpm": ["PNPM_HOME", "npm_config_store_dir", "NPM_CONFIG_STORE_DIR", "npm_config_cache_dir",
                 "NPM_CONFIG_CACHE_DIR"],
        "uv": ["UV_CACHE_DIR"],
    ]

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
    /// Jeder eigene Prozess mit offener Datei oder Arbeitsordner im Eintrag sperrt ihn (Agenten-Arbeitsordner, #229).
    public static let anyProcess = ProcessLock(processes: nil)

    /// Prozessnamen (`p_comm`); ihre Unterprozesse zählen mit. `nil`: jeder eigene Prozess.
    public let processes: Set<String>?
    /// Namen der Einträge, die genau einem Vorgang gehören (DerivedData: `<Projekt>-<28 Kleinbuchstaben>`); sie sperrt nur
    /// eine offene Datei darin. Alle übrigen – geteilte Caches wie `ModuleCache.noindex`, die Compiler nur kurz öffnen
    /// oder bloß einblenden – sperrt schon ein laufender Prozess. `nil`: Jeder Eintrag gehört einem Vorgang.
    public let ownedEntryPattern: String?

    public init(processes: Set<String>?, ownedEntryPattern: String? = nil) {
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

extension FileSize {
    /// Ob die Messung eine Vorauswahl trägt (#220): Ohne Ergebnis – Frist abgelaufen, abgebrochen – bleibt ein Eintrag
    /// im Zweifel abgewählt. „Nicht lesbar“ ist ein Ergebnis und ändert die Vorauswahl nicht.
    var permitsPreselection: Bool { self != .unknown }
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
        /// `signal`: Prozesse beendet (Segment „Prozesse“, #221). `timeMachineExclude`/`timeMachineInclude`: Ordner aus
        /// Time Machine ausgenommen bzw. wieder gesichert (#227); `Result.removed` heißt dort „ausgeführt“.
        case trash, delete, command, signal, none, timeMachineExclude, timeMachineInclude
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
