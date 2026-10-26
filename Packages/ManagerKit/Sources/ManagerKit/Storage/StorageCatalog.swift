import Foundation
import GrantryShared

/// Alle Kategorien des Speicher-Aufräumens (Spec Speicher, Tabelle „Kategorien“), in Anzeigereihenfolge vor der
/// Sortierung nach Größe. Die Reihenfolge ist zugleich die des Aufräumens (`ordered(_:by:)`): „Nicht verfügbare
/// Simulatoren“ läuft vor dem Löschen von Simulator-Laufzeiten, sonst löschte `simctl delete unavailable` die gerade
/// unbenutzbar gewordenen Geräte samt ihren Daten mit (#226).
public enum StorageCatalog {
    public struct Configuration: Sendable {
        public let home: String
        public let codeRoots: [String]
        public let minimumAgeDays: Int
        /// Programme-Ordner für Spieldaten der Time-Machine-Vorschläge (#227); Tests setzen einen eigenen.
        public let applications: String

        public init(home: String, codeRoots: [String], minimumAgeDays: Int, applications: String = "/Applications") {
            self.home = home
            self.codeRoots = codeRoots
            self.minimumAgeDays = minimumAgeDays
            self.applications = applications
        }
    }

    /// Orte, die Speicher-Kategorien und Time-Machine-Vorschläge teilen (#227): eine Quelle für beide Listen.
    struct Locations {
        let home: String

        func at(_ relative: String) -> String { home + "/" + relative }
        var xcode: String { at("Library/Developer/Xcode") }
        var derivedData: String { xcode + "/DerivedData" }
        var caches: String { at("Library/Caches") }
        var deviceSupport: [String] { ["iOS", "watchOS", "tvOS", "visionOS"].map { xcode + "/\($0) DeviceSupport" } }
        var simulatorDevices: String { at("Library/Developer/CoreSimulator/Devices") }
        var steam: String { at("Library/Application Support/Steam") }
        var llmModels: [String] {
            [at(".ollama/models"), at(".omlx"), at(".lmstudio/models"), at(".cache/lm-studio/models"),
             at("Library/Caches/llama.cpp")]
        }
    }

    /// Sperre von DerivedData durch Builds aus Xcode und `xcodebuild` (#226): Projektordner (`<Name>-<28 Kleinbuchstaben>`)
    /// bei offenen Dateien, geteilte Caches (`ModuleCache.noindex`, `SDKStatCaches.noindex` …) solange ein Build läuft.
    static let buildLock = ProcessLock(processes: ["xcodebuild", "SWBBuildService", "XCBBuildService"],
                                       ownedEntryPattern: ".+-[a-z]{28}")
    /// Ab diesem Alter sind heruntergeladene VM-Installer vorausgewählt (#226).
    static let installerMinimumAgeDays = 90
    /// Ab so vielen Tagen ohne Änderung sind Agenten-Arbeitsordner vorausgewählt (#229).
    static let agentWorkdirMinimumAgeDays = 2

    /// Mit den echten Abhängigkeiten der App.
    public static func providers(_ configuration: Configuration) -> [any StorageCategoryProvider] {
        providers(configuration, measurer: FileSizeCalculator(timeout: FileSizeCalculator.appTimeout),
                  runner: ProcessCommandRunner(), locator: ToolLocator(home: configuration.home))
    }

    /// `openFiles` und `fullDiskAccess` sind für Tests austauschbar.
    static func providers(_ configuration: Configuration, measurer: any FileSizeMeasuring, runner: any CommandRunning,
                          locator: ToolLocator, openFiles: any OpenFileProbing = LibprocOpenFileProbe(),
                          fullDiskAccess: @escaping @Sendable () async -> Bool = { await FullDiskAccessProbe().hasFullDiskAccess() })
        -> [any StorageCategoryProvider] {
        let home = configuration.home
        let places = Locations(home: home)
        @Sendable func at(_ relative: String) -> String { places.at(relative) }
        func category(_ id: String, _ title: String, _ summary: String,
                      _ risk: StorageRisk, _ roots: [String] = [], lockedBy lock: ProcessLock? = nil) -> StorageCategory {
            StorageCategory(id: id, title: title, summary: summary, risk: risk, roots: roots, processLock: lock)
        }
        func paths(_ id: String, _ title: String, _ summary: String, _ risk: StorageRisk, _ roots: [String],
                   excluding excluded: Set<String> = [], lockedBy lock: ProcessLock? = nil) -> PathCategoryProvider {
            PathCategoryProvider(category: category(id, title, summary, risk, roots, lockedBy: lock),
                                 excludedNames: excluded, measurer: measurer, openFiles: openFiles)
        }
        func command(_ id: String, _ title: String, _ summary: String,
                     _ risk: StorageRisk, tool: String, candidates: [String]? = nil, _ arguments: [String],
                     measuring measured: String?, companions: [String] = [],
                     requiring required: String? = nil) -> CommandCategoryProvider {
            CommandCategoryProvider(category: category(id, title, summary, risk), tool: tool, candidates: candidates,
                                    arguments: arguments, measuredPath: measured, requiredCompanions: companions,
                                    requiredPath: required, locator: locator, measurer: measurer)
        }
        func report(_ id: String, _ title: String, _ summary: String,
                    _ paths: @escaping @Sendable () -> [String]) -> ReportOnlyProvider {
            ReportOnlyProvider(category: category(id, title, summary, .reportOnly), paths: paths, measurer: measurer)
        }
        let xcode = places.xcode
        let codeRoots = configuration.codeRoots
        // Eigene CLI-Kategorie (Homebrew), Modelle (llama.cpp, Bericht unter „LLM-Modelle“), Apple-Dienste ohne
        // `com.apple.`-Präfix, deren Daemons die Ordner offen halten (CloudKit: Datenbank von `cloudd`), und Daten, die
        // nicht von selbst neu entstehen: IDE-Verlauf (JetBrains, Google/AndroidStudio*: Local History), Poetry-
        // Umgebungen (pypoetry) und heruntergeladene Test-Runner (ms-playwright, Cypress).
        var cachesExclusions: Set<String> = [
            "Homebrew", "llama.cpp", "CloudKit", "FamilyCircle", "familycircled", "GeoServices", "PassKit", "GameKit",
            "SiriTTS", "askpermissiond", "AMSDataMigratorTool", "JetBrains", "pypoetry", "ms-playwright", "Cypress",
            "Google",
        ]
        // Grantrys eigener Cache (u. a. Sparkle-Downloads eines laufenden Updates) bleibt unangetastet.
        if let ownIdentifier = Bundle.main.bundleIdentifier { cachesExclusions.insert(ownIdentifier) }
        let simulatorDevices = places.simulatorDevices
        let virtualBuddy = at("Library/Application Support/VirtualBuddy")
        let installerDownloads = "_Downloads"
        return [
            paths("derivedData", "Xcode DerivedData", "Build-Zwischenstände; Xcode legt sie bei Bedarf neu an.", .low,
                  [places.derivedData], lockedBy: buildLock),
            paths("caches", "Caches", "Zwischenspeicher der Apps (inkl. pip, CocoaPods); werden neu aufgebaut.", .low,
                  [places.caches], excluding: cachesExclusions),
            command("uv", "uv-Cache", "Entfernt nicht mehr benötigte Pakete aus dem uv-Cache.", .low, tool: "uv",
                    ["cache", "prune"], measuring: at(".cache/uv")),
            command("homebrew", "Homebrew aufräumen",
                    "Entfernt alte Versionen, Downloads und nicht mehr benötigte Abhängigkeiten (brew cleanup).",
                    .medium, tool: "brew", ["cleanup", "-s"], measuring: at("Library/Caches/Homebrew")),
            command("npm", "npm-Cache", "Leert den npm-Cache.", .low, tool: "npm", ["cache", "clean", "--force"],
                    measuring: at(".npm/_cacache"), companions: ["node"]),
            command("pnpm", "pnpm-Store", "Entfernt nicht referenzierte Pakete aus dem pnpm-Store.", .low, tool: "pnpm",
                    ["store", "prune"], measuring: at("Library/pnpm/store"), companions: ["node"]),
            command("unavailableSimulators", "Nicht verfügbare Simulatoren", "Simulatoren ohne passende Laufzeit.", .low,
                    tool: "xcrun", candidates: ["/usr/bin/xcrun"], ["simctl", "delete", "unavailable"], measuring: nil,
                    requiring: simulatorDevices),
            paths("deviceSupport", "Geräte-Support", "Symboldateien je iOS-/watchOS-/tvOS-/visionOS-Version.", .medium,
                  places.deviceSupport),
            paths("archives", "Xcode-Archive", "Archivierte Builds; nötig für Symbolisierung alter Releases.", .medium,
                  [xcode + "/Archives"]),
            paths("logs", "Protokolle", "Protokolle und Absturzberichte in ~/Library/Logs.", .medium, [at("Library/Logs")]),
            ProjectArtifactsProvider(roots: codeRoots, minimumAgeDays: configuration.minimumAgeDays, measurer: measurer),
            command("docker", "Docker", """
                    Gestoppte Container samt ihrer Daten, unbenutzte Netzwerke, verwaiste Images und Build-Cache im \
                    aktuellen Docker-Kontext – nie Volumes.
                    """, .medium, tool: "docker",
                    candidates: ["/Applications/Docker.app/Contents/Resources/bin/docker", "/usr/local/bin/docker",
                                 "/opt/homebrew/bin/docker"],
                    ["system", "prune", "-f"], measuring: nil),
            SimulatorRuntimesProvider(requiredPath: simulatorDevices, runner: runner, locator: locator),
            report("simulatorDevices", "Simulatoren", "Verwalten in Xcode → Devices and Simulators.") {
                [simulatorDevices]
            },
            report("simulatorDyldCache", "Simulator-dyld-Cache", """
                   Wird mit der zugehörigen Simulator-Laufzeit entfernt; den Rest kann nur ein Administrator löschen.
                   """) { ["/Library/Developer/CoreSimulator/Caches/dyld"] },
            WebKitWALProvider(home: home, canReadAppContainers: fullDiskAccess),
            TimeMachineSnapshotsProvider(runner: runner),
            report("llmModels", "LLM-Modelle", "Lokale Sprachmodelle (Ollama, oMLX, LM Studio).") { places.llmModels },
            // VirtualBuddy je Eintrag ohne die Installer-Downloads (eigene Kategorie, sonst doppelt gezählt).
            report("virtualMachines", "Virtuelle Maschinen", "VirtualBuddy, UTM, VMware, Parallels.") {
                entries(of: virtualBuddy).filter { ($0 as NSString).lastPathComponent != installerDownloads }
                    + [at("Library/Containers/com.utmapp.UTM/Data/Documents"), at("Virtual Machines.localized"), at("Parallels")]
            },
            DownloadedInstallersProvider(
                category: category("virtualBuddyDownloads", "VirtualBuddy-Downloads", """
                                   Heruntergeladene macOS-Installer (.ipsw); ältere als \(installerMinimumAgeDays) Tage \
                                   sind vorausgewählt.
                                   """, .low, [virtualBuddy + "/" + installerDownloads]),
                extensions: ["ipsw"], minimumAgeDays: installerMinimumAgeDays, measurer: measurer),
            report("steam", "Steam-Spiele", "Installierte Spiele; deinstallieren in Steam.") {
                [places.steam + "/steamapps"]
            },
            report("agentWorktrees", "Agent-Worktrees", "Arbeitskopien von KI-Agenten (`.claude/worktrees`).") {
                codeRoots.flatMap { root in entries(of: root).map { $0 + "/.claude/worktrees" } }
            },
            // Orcas Standard-Arbeitsordner (Einstellung „workspaceDir“).
            OrcaWorktreesProvider(workspaceRoot: at("orca/workspaces"), measurer: measurer),
            AgentWorkdirsProvider(claudeRoot: "/private/tmp/claude-\(getuid())", codexRoot: at(".codex/.tmp"), home: home,
                                  minimumAgeDays: agentWorkdirMinimumAgeDays, measurer: measurer, openFiles: openFiles),
            report("trash", "Papierkorb", "Leeren im Finder.") { [at(".Trash")] },
        ]
    }

    /// Ordner, die Grantry zum Ausnehmen aus Time Machine vorschlägt (#227), aus denselben Orten wie die Kategorien.
    /// Risiko „niedrig“ (vorausgewählt): Caches und Build-Zwischenstände, die von selbst neu entstehen, sowie die
    /// Docker-VM-Disk, die sich ständig ändert und darum jedes Mal voll gesichert würde. „Mittel“: große, aber nur
    /// mühsam neu ladbare Daten (Simulator-Geräte, LLM-Modelle, VM-Bundles, Spieldaten). Bei Spielen nur der
    /// Datenordner, nie Einstellungen oder Addons (World of Warcraft: `Data`, nicht `_retail_`; weitere Steam-
    /// Bibliotheken: `steamapps/common`, nicht Manifeste oder `workshop`).
    public static func timeMachineCandidates(_ configuration: Configuration) -> [TimeMachineCandidate] {
        let places = Locations(home: configuration.home)
        func candidate(_ title: String, _ path: String, _ risk: StorageRisk, category: String? = nil,
                       needsFullDiskAccess: Bool = false) -> TimeMachineCandidate {
            TimeMachineCandidate(title: title, path: path, risk: risk, categoryID: category,
                                 needsFullDiskAccess: needsFullDiskAccess)
        }
        let packageCaches: [(String, String, String?)] = [
            ("Paket-Caches (uv, pip, Hugging Face)", ".cache", nil), ("npm-Cache", ".npm", "npm"),
            ("Bun-Cache", ".bun/install/cache", nil), ("Go-Module", "go/pkg/mod", nil),
            ("Codex-Zwischenablage", ".codex/.tmp", nil),
        ]
        let steamGames = SteamLibraries.additional(steamRoot: places.steam).map {
            candidate("Steam-Bibliothek – Spiele", $0 + "/steamapps/common", .medium)
        }
        return [candidate("Xcode DerivedData", places.derivedData, .low, category: "derivedData"),
                candidate("Caches", places.caches, .low, category: "caches")]
            + places.deviceSupport.map { candidate("Geräte-Support", $0, .low, category: "deviceSupport") }
            // Ordner in App-Containern liest Grantry nur mit Festplattenvollzugriff (wie `WebKitWALProvider`).
            + [candidate("Docker-VM-Disk", places.at("Library/Containers/com.docker.docker/Data/vms"), .low,
                         category: "docker", needsFullDiskAccess: true)]
            + packageCaches.map { title, relative, category in candidate(title, places.at(relative), .low, category: category) }
            + [candidate("Simulator-Geräte", places.simulatorDevices, .medium, category: "simulatorDevices")]
            + places.llmModels.map { candidate("LLM-Modelle", $0, .medium, category: "llmModels") }
            + [candidate("Claude-VM-Bundles", places.at("Library/Application Support/Claude/vm_bundles"), .medium),
               candidate("World of Warcraft – Spieldaten", configuration.applications + "/World of Warcraft/Data", .medium)]
            + steamGames
    }

    /// `reports` in der Reihenfolge der Kategorie-IDs `order` (aus `providers`), unbekannte zuletzt – unabhängig davon,
    /// in welcher Reihenfolge die Scans fertig wurden.
    public static func ordered(_ reports: [StorageCategoryReport], by order: [String]) -> [StorageCategoryReport] {
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return reports.enumerated()
            .sorted { (position[$0.element.id] ?? Int.max, $0.offset) < (position[$1.element.id] ?? Int.max, $1.offset) }
            .map(\.element)
    }

    /// Pfade der nicht versteckten Einträge eines Ordners, sortiert; leer, wenn er fehlt oder nicht lesbar ist.
    @Sendable static func entries(of folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
            .filter { !RawPath.isHidden($0) }.map { folder + "/" + $0 }
    }
}
