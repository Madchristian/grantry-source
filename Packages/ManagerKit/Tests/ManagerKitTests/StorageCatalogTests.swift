import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct StorageCatalogTests {
    @Test func preferencesDefaultToExistingCodeFoldersAndThirtyDays() throws {
        try ScratchDirectory.withCanonical(prefix: "catalog") { home in
            try FileManager.default.createDirectory(at: home.appending(path: "Projects"), withIntermediateDirectories: true)
            let preferences = StoragePreferences(store: InMemorySettingsStore(), home: home.path)
            #expect(preferences.codeRoots == [home.appending(path: "Projects").path])
            #expect(preferences.minimumAgeDays == 30)
            preferences.codeRoots = ["/a"]
            preferences.minimumAgeDays = 0
            #expect(preferences.codeRoots == ["/a"])
            #expect(preferences.minimumAgeDays == 1)
        }
    }

    @Test func catalogHasUniqueIDsAndAllSpecCategories() {
        let providers = StorageCatalog.providers(
            StorageCatalog.Configuration(home: "/home", codeRoots: ["/home/Projects"], minimumAgeDays: 30),
            measurer: FixedSizeMeasurer(), runner: MockCommandRunner(), locator: ToolLocator(home: "/home") { _ in false })
        let ids = providers.map(\.category.id)
        #expect(Set(ids).count == ids.count)
        #expect(Set(ids) == ["derivedData", "caches", "uv", "homebrew", "npm", "pnpm", "unavailableSimulators",
                             "deviceSupport", "archives", "logs", "projectArtifacts", "docker", "simulatorRuntimes",
                             "simulatorDevices", "simulatorDyldCache", "webKitWAL", "timeMachine", "llmModels",
                             "virtualMachines", "virtualBuddyDownloads", "steam", "agentWorktrees", "orcaWorktrees", "agentWorkdirs", "trash"])
    }

    /// Codex-Review #226: Nach einem Nachscan steht „Nicht verfügbare Simulatoren“ hinten; aufgeräumt wird trotzdem vor
    /// dem Löschen von Laufzeiten, damit `simctl delete unavailable` deren Geräte nicht mitlöscht.
    @Test func unavailableSimulatorsAreCleanedBeforeRuntimes() {
        let order = catalog().map(\.category.id)
        func report(_ id: String) -> StorageCategoryReport {
            StorageCategoryReport(category: StorageCategory(id: id, title: id, summary: "", risk: .low, roots: []),
                                  status: .available, items: [])
        }
        let arrived = ["simulatorRuntimes", "unknown", "caches", "unavailableSimulators"].map(report)
        #expect(StorageCatalog.ordered(arrived, by: order).map(\.id)
                == ["caches", "unavailableSimulators", "simulatorRuntimes", "unknown"])
    }

    @Test func derivedDataIsLockedByRunningBuilds() throws {
        let derivedData = try #require(catalog().first { $0.category.id == "derivedData" } as? PathCategoryProvider)
        #expect(derivedData.category.processLock?.processes == ["xcodebuild", "SWBBuildService", "XCBBuildService"])
        #expect(catalog().filter { $0.category.processLock != nil }.map(\.category.id) == ["derivedData", "agentWorkdirs"])
        let lock = try #require(derivedData.category.processLock)
        #expect(!lock.isShared("Grantry-azvkmficvosdguallwvtkongfdne"))
        for shared in ["ModuleCache.noindex", "SDKStatCaches.noindex", "CompilationCache.noindex", "Grantry-short"] {
            #expect(lock.isShared(shared))
        }
    }

    @Test func runtimesNeedSimulatorDevicesAndDyldCacheIsOnlyReported() throws {
        let runtimes = try #require(catalog().first { $0.category.id == "simulatorRuntimes" } as? SimulatorRuntimesProvider)
        #expect(runtimes.requiredPath == "/home/Library/Developer/CoreSimulator/Devices")
        let dyld = try #require(catalog().first { $0.category.id == "simulatorDyldCache" } as? ReportOnlyProvider)
        #expect(dyld.paths() == ["/Library/Developer/CoreSimulator/Caches/dyld"])
    }

    @Test func virtualBuddyDownloadsAreSeparateFromMachines() async throws {
        try await ScratchDirectory.withCanonical(prefix: "catalog") { home in
            let library = home.appending(path: "Library/Application Support/VirtualBuddy")
            for name in ["_Downloads", "Seahorse.vbvm", ".hidden"] {
                try FileManager.default.createDirectory(at: library.appending(path: name), withIntermediateDirectories: true)
            }
            let providers = StorageCatalog.providers(
                StorageCatalog.Configuration(home: home.path, codeRoots: [], minimumAgeDays: 30),
                measurer: FixedSizeMeasurer(), runner: MockCommandRunner(), locator: ToolLocator(home: home.path) { _ in false },
                openFiles: FakeOpenFileProbe(), fullDiskAccess: { false })
            let machines = try #require(providers.first { $0.category.id == "virtualMachines" } as? ReportOnlyProvider)
            #expect(machines.paths().filter { $0.contains("VirtualBuddy") } == [library.path + "/Seahorse.vbvm"])
            let downloads = try #require(
                providers.first { $0.category.id == "virtualBuddyDownloads" } as? DownloadedInstallersProvider)
            #expect(downloads.category.roots == [library.path + "/_Downloads"])
            #expect(downloads.category.risk == .low && downloads.minimumAgeDays == 90 && downloads.extensions == ["ipsw"])
        }
    }

    /// #229: Claude Code nur im Ordner der eigenen UID, Codex unter `~/.codex/.tmp`; jeder eigene Prozess sperrt.
    @Test func agentWorkdirsCoverOwnClaudeAndCodexFolders() throws {
        let workdirs = try #require(catalog().first { $0.category.id == "agentWorkdirs" } as? AgentWorkdirsProvider)
        #expect(workdirs.category.roots == ["/private/tmp/claude-\(getuid())", "/home/.codex/.tmp"])
        #expect(workdirs.category.risk == .low && workdirs.category.processLock == .anyProcess)
        #expect(workdirs.minimumAgeDays == 2)
    }

    /// #255: Orca-Worktrees nur als Bericht aus Orcas Standard-Arbeitsordner, ohne Sperre und Löschweg.
    @Test func orcaWorktreesAreOnlyReported() throws {
        let worktrees = try #require(catalog().first { $0.category.id == "orcaWorktrees" } as? OrcaWorktreesProvider)
        #expect(worktrees.category.roots == ["/home/orca/workspaces"])
        #expect(worktrees.category.risk == .reportOnly && worktrees.category.processLock == nil)
    }

    @Test func dockerNeverPrunesVolumes() throws {
        let providers = StorageCatalog.providers(
            StorageCatalog.Configuration(home: "/home", codeRoots: [], minimumAgeDays: 30),
            measurer: FixedSizeMeasurer(), runner: MockCommandRunner(), locator: ToolLocator(home: "/home") { _ in false })
        let docker = try #require(providers.first { $0.category.id == "docker" } as? CommandCategoryProvider)
        #expect(docker.arguments == ["system", "prune", "-f"])
        #expect(docker.category.risk == .medium)
        #expect(!docker.category.summary.contains("\n") && docker.category.summary.hasSuffix("nie Volumes."))
    }

    @Test func cachesExcludeOwnCategoriesAndNonRebuildableData() throws {
        let caches = try #require(catalog().first { $0.category.id == "caches" } as? PathCategoryProvider)
        #expect(caches.excludedNames.isSuperset(of: [
            "Homebrew", "CloudKit", "llama.cpp", "JetBrains", "pypoetry", "ms-playwright", "Cypress", "Google",
        ]))
        if let ownIdentifier = Bundle.main.bundleIdentifier {
            #expect(caches.excludedNames.contains(ownIdentifier))
        }
    }

    @Test func simulatorsUseOnlyTheSystemTool() throws {
        let simulators = try #require(
            catalog().first { $0.category.id == "unavailableSimulators" } as? CommandCategoryProvider)
        #expect(simulators.candidates == ["/usr/bin/xcrun"])
        // Ohne Simulator-Geräte (kein Xcode) nicht anbieten, sonst öffnet der xcrun-Shim den CLT-Dialog.
        #expect(simulators.requiredPath == "/home/Library/Developer/CoreSimulator/Devices")
        #expect(simulators.requiredCompanions.isEmpty)
    }

    @Test func nodeScriptsRequireNodeBesideThem() throws {
        for id in ["npm", "pnpm"] {
            let provider = try #require(catalog().first { $0.category.id == id } as? CommandCategoryProvider)
            #expect(provider.requiredCompanions == ["node"])
            #expect(provider.requiredPath == nil)
        }
        let docker = try #require(catalog().first { $0.category.id == "docker" } as? CommandCategoryProvider)
        #expect(docker.requiredCompanions.isEmpty && docker.requiredPath == nil)
    }

    @Test func homebrewCleanupNeedsAConsciousChoice() throws {
        let homebrew = try #require(catalog().first { $0.category.id == "homebrew" } as? CommandCategoryProvider)
        #expect(homebrew.category.risk == .medium)
        #expect(homebrew.arguments == ["cleanup", "-s"])
    }

    @Test func modelReportCoversTheExcludedLlamaCppCache() throws {
        let models = try #require(catalog().first { $0.category.id == "llmModels" } as? ReportOnlyProvider)
        #expect(models.paths().contains("/home/Library/Caches/llama.cpp"))
    }

    private func catalog() -> [any StorageCategoryProvider] {
        StorageCatalog.providers(
            StorageCatalog.Configuration(home: "/home", codeRoots: [], minimumAgeDays: 30),
            measurer: FixedSizeMeasurer(), runner: MockCommandRunner(), locator: ToolLocator(home: "/home") { _ in false },
            openFiles: FakeOpenFileProbe(), fullDiskAccess: { false })
    }
}
