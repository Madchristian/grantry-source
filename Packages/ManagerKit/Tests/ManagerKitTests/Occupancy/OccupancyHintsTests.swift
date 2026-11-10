import Darwin
import Foundation
import Testing
import TestSupport
@testable import ManagerKit

/// Hinweise je Ordner der Belegung (TM-15.3, #402): Kategorie des Speicher-Aufräumens samt Risiko und Time-Machine-
/// Vorschlag aus dem `StorageCatalog`. Nur lesend; `tmutil` läuft nur als `MockCommandRunner`.
@Suite struct OccupancyHintsTests {
    private static let configuration = StorageCatalog.Configuration(home: "/home", codeRoots: ["/home/Projects"],
                                                                     minimumAgeDays: 30, applications: "/Apps")

    private static func providers() -> [any StorageCategoryProvider] {
        StorageCatalog.providers(configuration, measurer: FixedSizeMeasurer(), runner: MockCommandRunner(),
                                 locator: ToolLocator(home: "/home") { _ in false }, openFiles: FakeOpenFileProbe(),
                                 fullDiskAccess: { false })
    }

    private let hints = OccupancyHints(providers: providers(),
                                       timeMachineCandidates: StorageCatalog.timeMachineCandidates(configuration))

    private func categoryID(_ path: String) -> String? { hints.hint(forPath: path).category?.id }

    // MARK: Zuordnung je Kategorie

    @Test func everyCategoryLocationMapsToItsCategory() {
        let providers = Self.providers()
        for provider in providers {
            for location in provider.locations {
                #expect(categoryID(location.path) == provider.category.id, "\(location.path)")
                #expect(categoryID(location.path + "/Eintrag/tiefer") == provider.category.id, "\(location.path)")
            }
        }
        // Kein Ort gehört zwei Kategorien: Die Zuordnung wäre sonst Zufall der Reihenfolge.
        let paths = providers.flatMap(\.locations).map(\.path)
        #expect(Set(paths).count == paths.count)
    }

    @Test(arguments: [
        ("/home/Library/Developer/Xcode/DerivedData/Grantry-abc", "derivedData", StorageRisk.low),
        ("/home/Library/Caches/com.example.App", "caches", .low),
        ("/home/.cache/uv/archive-v0", "uv", .low),
        ("/home/Library/Caches/Homebrew/downloads", "homebrew", .medium),
        ("/home/.npm/_cacache/index-v5", "npm", .low),
        ("/home/Library/pnpm/store/v3", "pnpm", .low),
        ("/home/Library/Developer/Xcode/iOS DeviceSupport/18.0", "deviceSupport", .medium),
        ("/home/Library/Developer/Xcode/visionOS DeviceSupport", "deviceSupport", .medium),
        ("/home/Library/Developer/Xcode/Archives/2026-11-08", "archives", .medium),
        ("/home/Library/Logs/DiagnosticReports", "logs", .medium),
        ("/home/Library/Developer/CoreSimulator/Devices/ABC", "simulatorDevices", .reportOnly),
        ("/Library/Developer/CoreSimulator/Caches/dyld/23A", "simulatorDyldCache", .reportOnly),
        ("/home/.ollama/models/blobs", "llmModels", .reportOnly),
        ("/home/Library/Caches/llama.cpp/model.gguf", "llmModels", .reportOnly),
        ("/home/Parallels/Windows.pvm", "virtualMachines", .reportOnly),
        ("/home/Library/Application Support/VirtualBuddy/_Downloads", "virtualBuddyDownloads", .low),
        ("/home/Library/Application Support/Steam/steamapps/common", "steam", .reportOnly),
        ("/home/orca/workspaces/grantry/feature", "orcaWorktrees", .reportOnly),
        ("/home/.codex/.tmp/session", "agentWorkdirs", .low),
        ("/home/.Trash/alt", "trash", .reportOnly),
    ])
    func folderMapsToCategoryWithRisk(path: String, id: String, risk: StorageRisk) throws {
        let category = try #require(hints.hint(forPath: path).category, "\(path)")
        #expect(category.id == id)
        #expect(category.risk == risk)
    }

    @Test func agentWorkdirsOfThisUserMapToTheirCategory() {
        #expect(categoryID("/private/tmp/claude-\(getuid())/-Users-name-Projekt/abc") == "agentWorkdirs")
    }

    /// Ordner, die Grantry selbst aufräumt, sind „über Speicher aufräumbar“; Nur-Bericht-Kategorien zeigen nur den Weg.
    @Test func onlyCleaningCategoriesAreCleanable() {
        #expect(hints.hint(forPath: "/home/Library/Caches/com.example.App").isCleanable)
        #expect(hints.hint(forPath: "/home/Library/Logs").isCleanable)
        #expect(!hints.hint(forPath: "/home/.Trash").isCleanable)
        #expect(!hints.hint(forPath: "/home/Documents").isCleanable)
    }

    // MARK: Verschachtelte Kategorien

    /// Homebrew (eigene Kategorie, Risiko mittel) und llama.cpp (LLM-Modelle) liegen in den Caches: Die innerste gewinnt,
    /// auch wenn die äußere früher im Katalog steht.
    @Test func innermostCategoryWins() {
        #expect(categoryID("/home/Library/Caches") == "caches")
        #expect(categoryID("/home/Library/Caches/Homebrew") == "homebrew")
        #expect(categoryID("/home/Library/Caches/Homebrew/downloads/x") == "homebrew")
        #expect(categoryID("/home/Library/Caches/llama.cpp") == "llmModels")
        #expect(categoryID("/home/Library/Caches/SomeApp/deep/er") == "caches")
    }

    @Test func innermostCategoryWinsRegardlessOfCatalogOrder() {
        func provider(_ id: String, _ root: String) -> ReportOnlyProvider {
            ReportOnlyProvider(category: StorageCategory(id: id, title: id, summary: "", risk: .reportOnly, roots: []),
                               paths: { [root] }, measurer: FixedSizeMeasurer())
        }
        for providers in [[provider("inner", "/a/b"), provider("outer", "/a")],
                          [provider("outer", "/a"), provider("inner", "/a/b")]] {
            let hints = OccupancyHints(providers: providers, timeMachineCandidates: [])
            #expect(hints.hint(forPath: "/a/b/c").category?.id == "inner")
            #expect(hints.hint(forPath: "/a/c").category?.id == "outer")
        }
    }

    /// Einträge, die eine Kategorie bewusst auslässt (versteckt, `com.apple.…`, eigene Ausnahmen), gehören nicht zu ihr –
    /// sonst hieße ein Ordner „über Speicher aufräumbar“, den Speicher nie anbietet.
    @Test func entriesTheCategoryLeavesOutAreNotAssigned() {
        #expect(categoryID("/home/Library/Caches/com.apple.Safari") == nil)
        #expect(categoryID("/home/Library/Caches/CloudKit/x") == nil)
        #expect(categoryID("/home/Library/Caches/.hidden") == nil)
        #expect(categoryID("/home/Library/Caches/JetBrains/IntelliJ") == nil)
    }

    /// Eine ausgelassene innere Kategorie fällt auf die nächste äußere zurück, die den Eintrag umfasst.
    @Test func excludedEntryFallsBackToOuterCategory() {
        let outer = ReportOnlyProvider(category: StorageCategory(id: "outer", title: "", summary: "", risk: .reportOnly,
                                                                 roots: []),
                                       paths: { ["/a"] }, measurer: FixedSizeMeasurer())
        let inner = PathCategoryProvider(category: StorageCategory(id: "inner", title: "", summary: "", risk: .low,
                                                                   roots: ["/a/b"]),
                                         excludedNames: ["keep"], measurer: FixedSizeMeasurer())
        let hints = OccupancyHints(providers: [inner, outer], timeMachineCandidates: [])
        #expect(hints.hint(forPath: "/a/b/cache").category?.id == "inner")
        #expect(hints.hint(forPath: "/a/b/keep/x").category?.id == "outer")
    }

    // MARK: Ordner ohne Kategorie

    @Test(arguments: [
        "/home/Documents", "/home", "/", "/home/Library", "/home/Library/CachesAlt", "/home/Library/Developer/Xcode",
        "/home/.cache", "/home/.npm", "/Applications/Xcode.app", "relativ/Library/Caches", "",
        // Build-Ordner alter Projekte hängen am Alter des Projekts; die Belegung behauptet sie nicht.
        "/home/Projects/app/node_modules", "/home/Projects",
    ])
    func folderWithoutCategoryHasNoHint(path: String) {
        let hint = hints.hint(forPath: path)
        #expect(hint.category == nil, "\(path)")
        #expect(!hint.isCleanable)
    }

    /// Ein Scan des ganzen Datenträgers liefert Pfade in der Schreibweise des Datenvolumes.
    @Test func dataVolumeSpellingMapsLikeFirmlinkedPath() {
        #expect(categoryID("/System/Volumes/Data/home/Library/Caches/com.example.App") == "caches")
        #expect(hints.hint(forPath: "/System/Volumes/Data/home/Library/Caches").timeMachineCandidate?.title == "Caches")
    }

    // MARK: Time-Machine-Vorschlag

    @Test func timeMachineCandidateCoversFolderAndItsSubfolders() throws {
        let caches = try #require(hints.hint(forPath: "/home/Library/Caches/com.example.App").timeMachineCandidate)
        #expect(caches.path == "/home/Library/Caches")
        #expect(caches.risk == .low)
        // Ohne Speicher-Kategorie, aber von Grantry zum Ausnehmen vorgeschlagen.
        #expect(hints.hint(forPath: "/home/.cache/huggingface").timeMachineCandidate?.path == "/home/.cache")
        #expect(hints.hint(forPath: "/Apps/World of Warcraft/Data/x").timeMachineCandidate?.risk == .medium)
        #expect(hints.hint(forPath: "/Apps/World of Warcraft/_retail_").timeMachineCandidate == nil)
        #expect(hints.hint(forPath: "/home/Documents").timeMachineCandidate == nil)
    }

    @Test func folderWithoutAnyHintIsEmpty() {
        #expect(hints.hint(forPath: "/home/Documents") == .empty)
    }

    // MARK: Time-Machine-Status

    private func status(of path: String, stub: (MockCommandRunner) -> Void) async -> (TimeMachineFolderStatus, [String]) {
        let runner = MockCommandRunner()
        stub(runner)
        let exclusions = TimeMachineExclusions(runner: runner, measurer: FixedSizeMeasurer(), canReadAppContainers: { true })
        return (await exclusions.status(of: path), runner.calls)
    }

    private static let chainCall = "/usr/bin/tmutil isexcluded /home/Library/Caches/x /home/Library/Caches /home/Library /home"

    private static func output(_ states: [(String, String)]) -> CommandResult {
        CommandResult(exitCode: 0, stdout: states.map { "[\($0.1)]  \($0.0)\n" }.joined())
    }

    @Test func folderIsIncludedOnlyWhenItAndAllParentsAre() async {
        let (status, calls) = await status(of: "/home/Library/Caches/x") { runner in
            runner.stub(Self.chainCall, Self.output([("/home/Library/Caches/x", "Included"),
                                                     ("/home/Library/Caches", "Included"),
                                                     ("/home/Library", "Included"), ("/home", "Included")]))
        }
        #expect(status == TimeMachineFolderStatus(state: .included, excludedFolder: nil))
        #expect(calls == [Self.chainCall])
    }

    /// Ein Ausschluss gilt für alles darunter; `tmutil isexcluded` meldet ihn aber nur am ausgenommenen Ordner selbst.
    @Test func excludedParentExcludesFolder() async {
        let (status, _) = await status(of: "/home/Library/Caches/x") { runner in
            runner.stub(Self.chainCall, Self.output([("/home/Library/Caches/x", "Included"),
                                                     ("/home/Library/Caches", "Excluded"),
                                                     ("/home/Library", "Included"), ("/home", "Included")]))
        }
        #expect(status == TimeMachineFolderStatus(state: .excluded, excludedFolder: "/home/Library/Caches"))
    }

    @Test func excludedFolderNamesItself() async {
        let (status, _) = await status(of: "/home/Library/Caches/x") { runner in
            runner.stub(Self.chainCall, Self.output([("/home/Library/Caches/x", "Excluded"),
                                                     ("/home/Library/Caches", "Excluded"),
                                                     ("/home/Library", "Included"), ("/home", "Included")]))
        }
        #expect(status == TimeMachineFolderStatus(state: .excluded, excludedFolder: "/home/Library/Caches/x"))
    }

    /// Fehlt eine Antwort oder scheitert `tmutil`, ist der Status unbekannt – nie „gesichert“.
    @Test func incompleteOrFailedAnswerIsUnknown() async {
        let (missing, _) = await status(of: "/home/Library/Caches/x") { runner in
            runner.stub(Self.chainCall, Self.output([("/home/Library/Caches/x", "Included"),
                                                     ("/home/Library/Caches", "Included"), ("/home", "UNKNOWN")]))
        }
        #expect(missing == .unknown)
        let (failed, _) = await status(of: "/home/Library/Caches/x") { runner in
            runner.stub(Self.chainCall, CommandResult(exitCode: 1, stdout: "", stderr: "kaputt"))
        }
        #expect(failed == .unknown)
    }

    @Test func dataVolumeSpellingIsQueriedFirmlinked() async {
        let (status, calls) = await status(of: "/System/Volumes/Data/home/Library/Caches/x") { runner in
            runner.stub(Self.chainCall, Self.output([("/home/Library/Caches/x", "Included"),
                                                     ("/home/Library/Caches", "Included"),
                                                     ("/home/Library", "Included"), ("/home", "Included")]))
        }
        #expect(status.state == .included)
        #expect(calls == [Self.chainCall])
    }

    @Test(arguments: ["", "relativ/pfad", "/", "/a//b", "-p"])
    func invalidPathIsUnknownWithoutRunningTmutil(path: String) async {
        let (status, calls) = await status(of: path) { _ in }
        #expect(status == .unknown)
        #expect(calls.isEmpty)
    }
}
