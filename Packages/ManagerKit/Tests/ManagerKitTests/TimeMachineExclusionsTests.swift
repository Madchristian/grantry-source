import Foundation
import GrantryShared
import Testing
import TestSupport
@testable import ManagerKit

/// Time-Machine-Ausschlüsse (#227). `tmutil` läuft nur als `MockCommandRunner`: Kein Test setzt einen echten Ausschluss.
@Suite struct TimeMachineExclusionsTests {
    private static let configuration = StorageCatalog.Configuration(home: "/home", codeRoots: [], minimumAgeDays: 30,
                                                                     applications: "/Apps")

    private func candidate(_ path: String, risk: StorageRisk = .low, categoryID: String? = nil,
                           needsFullDiskAccess: Bool = false) -> TimeMachineCandidate {
        TimeMachineCandidate(title: (path as NSString).lastPathComponent, path: path, risk: risk, categoryID: categoryID,
                             needsFullDiskAccess: needsFullDiskAccess)
    }

    private func exclusions(_ runner: MockCommandRunner, sizes: [String: FileSize] = [:],
                            fullDiskAccess: Bool = true) -> TimeMachineExclusions {
        TimeMachineExclusions(runner: runner, measurer: FixedSizeMeasurer(sizes), canReadAppContainers: { fullDiskAccess })
    }

    // MARK: Vorschläge

    @Test func suggestionsPreselectOnlyLowRisk() throws {
        let candidates = StorageCatalog.timeMachineCandidates(Self.configuration)
        let paths = candidates.map(\.path)
        #expect(Set(paths).count == paths.count)
        let preselected = Set(candidates.filter { $0.risk == .low }.map(\.path))
        for path in ["/home/Library/Caches", "/home/Library/Developer/Xcode/DerivedData",
                     "/home/Library/Developer/Xcode/iOS DeviceSupport",
                     "/home/Library/Containers/com.docker.docker/Data/vms", "/home/.npm", "/home/go/pkg/mod"] {
            #expect(preselected.contains(path), "\(path)")
        }
        for path in ["/home/Library/Developer/CoreSimulator/Devices", "/home/.ollama/models", "/home/.omlx",
                     "/Apps/World of Warcraft/Data", "/home/Library/Application Support/Claude/vm_bundles"] {
            let match = try #require(candidates.first { $0.path == path }, "\(path)")
            #expect(match.risk == .medium, "\(path)")
        }
    }

    @Test func gamesOfferOnlyTheirDataFolders() {
        let paths = StorageCatalog.timeMachineCandidates(Self.configuration).map(\.path)
        #expect(paths.filter { $0.contains("World of Warcraft") } == ["/Apps/World of Warcraft/Data"])
        #expect(!paths.contains { $0.contains("_retail_") || $0.contains("WTF") || $0.contains("Interface") })
    }

    /// Weitere Steam-Bibliotheken aus `libraryfolders.vdf` (#257): nur deren installierte Spiele (`steamapps/common`).
    /// Die Standardbibliothek nimmt Steam selbst aus; Manifeste, Workshop-Inhalte (Mods), Spielstände (`userdata`) und
    /// Einstellungen (`config`) bleiben gesichert.
    @Test func steamOffersOnlyGamesOfAdditionalLibraries() throws {
        try ScratchDirectory.with(prefix: "steam-libraries") { home in
            let steam = home.appending(path: "Library/Application Support/Steam")
            try FileManager.default.createDirectory(at: steam.appending(path: "steamapps"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: steam.appending(path: "config"), withIntermediateDirectories: true)
            try #"""
                "libraryfolders"
                {
                	"0"
                	{
                		"path"		"\#(steam.path)"
                		"apps"		{ "228980"		"0" }
                	}
                	"1"
                	{
                		"path"		"/Volumes/Spiele/SteamLibrary"
                		"label"		""
                	}
                	"2"
                	{
                		"path"		"/Users/x/Games/Steam \"Zwei\""
                	}
                	"3"
                	{
                		"path"		"relativ/SteamLibrary"
                	}
                	"4"
                	{
                		"path"		"\#(steam.path)/steamapps/../Nested"
                	}
                }
                """#.write(to: steam.appending(path: "steamapps/libraryfolders.vdf"), atomically: true, encoding: .utf8)
            try #"""
                "libraryfolders" { "1" { "path" "/Volumes/Spiele/SteamLibrary/" } }
                """#.write(to: steam.appending(path: "config/libraryfolders.vdf"), atomically: true, encoding: .utf8)
            let configuration = StorageCatalog.Configuration(home: home.path, codeRoots: [], minimumAgeDays: 30,
                                                             applications: "/Apps")
            let candidates = StorageCatalog.timeMachineCandidates(configuration).filter { $0.title.contains("Steam") }
            #expect(candidates.map(\.path) == ["/Volumes/Spiele/SteamLibrary/steamapps/common",
                                               "/Users/x/Games/Steam \"Zwei\"/steamapps/common"])
            #expect(candidates.allSatisfy { $0.risk == .medium })
            let paths = StorageCatalog.timeMachineCandidates(configuration).map(\.path)
            #expect(!paths.contains { $0.hasPrefix(steam.path) })
            #expect(!paths.contains { $0.hasSuffix("/steamapps") || $0.contains("workshop") || $0.contains("userdata")
                                      || $0.hasSuffix("/config") || $0.hasSuffix("SteamLibrary") })
        }
    }

    @Test func steamWithoutLibraryFoldersOffersNothing() throws {
        try ScratchDirectory.with(prefix: "steam-none") { home in
            let configuration = StorageCatalog.Configuration(home: home.path, codeRoots: [], minimumAgeDays: 30)
            #expect(!StorageCatalog.timeMachineCandidates(configuration).contains { $0.title.contains("Steam") })
        }
    }

    /// Dieselben Orte wie die Speicher-Kategorien, keine eigene Liste (DRY).
    @Test func suggestionsReuseTheStorageCategoryLocations() throws {
        let providers = StorageCatalog.providers(Self.configuration, measurer: FixedSizeMeasurer(),
                                                 runner: MockCommandRunner(),
                                                 locator: ToolLocator(home: "/home") { _ in false })
        let candidates = StorageCatalog.timeMachineCandidates(Self.configuration)
        let byCategory = Dictionary(grouping: candidates.filter { $0.categoryID != nil }, by: { $0.categoryID! })
        for id in ["derivedData", "caches", "deviceSupport"] {
            let provider = try #require(providers.first { $0.category.id == id })
            #expect(Set(byCategory[id]?.map(\.path) ?? []) == Set(provider.category.roots), "\(id)")
        }
        let models = try #require(providers.first { $0.category.id == "llmModels" } as? ReportOnlyProvider)
        #expect(Set(byCategory["llmModels"]?.map(\.path) ?? []) == Set(models.paths()))
        let devices = try #require(providers.first { $0.category.id == "simulatorDevices" } as? ReportOnlyProvider)
        #expect(byCategory["simulatorDevices"]?.map(\.path) == devices.paths())
        #expect(Set(byCategory.keys).isSubset(of: Set(providers.map(\.category.id))))
        let docker = try #require(candidates.first { $0.categoryID == "docker" })
        #expect(docker.needsFullDiskAccess)
    }

    // MARK: Status

    @Test func parsesIsExcludedOutput() {
        let states = TimeMachineExclusions.parse("""
            [Excluded]  /a b/c
            [Included]    /d
            [UNKNOWN]   /e
            noise
            """)
        #expect(states == ["/a b/c": .excluded, "/d": .included, "/e": .unknown])
    }

    @Test func scanQueriesExistingFoldersInOneCall() async throws {
        try await ScratchDirectory.withCanonical(prefix: "tm-scan") { scratch in
            let cache = scratch.appending(path: "cache").path, models = scratch.appending(path: "models").path
            let missing = scratch.appending(path: "missing").path, link = scratch.appending(path: "link").path
            for path in [cache, models] { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: cache)
            let runner = MockCommandRunner()
            runner.stub("/usr/bin/tmutil isexcluded \(cache) \(models)",
                        CommandResult(exitCode: 0, stdout: "[Included]  \(cache)\n[Excluded]  \(models)\n"))
            let report = await exclusions(runner, sizes: [cache: .bytes(7)])
                .scan([candidate(cache), candidate(models, risk: .medium), candidate(missing), candidate(link)])
            #expect(runner.calls == ["/usr/bin/tmutil isexcluded \(cache) \(models)"])
            #expect(report.failure == nil)
            #expect(report.suggestions.map(\.candidate.path) == [cache, models])
            #expect(report.suggestions.map(\.state) == [.included, .excluded])
            #expect(report.suggestions.map(\.size) == [.bytes(7), .unknown])
            #expect(report.suggestions.map(\.isPreselected) == [true, false])
        }
    }

    /// Größen aus dem Speicher-Scan werden übernommen statt große Ordner ein zweites Mal zu messen.
    @Test func scanReusesSizesFromStorageReports() async throws {
        try await ScratchDirectory.withCanonical(prefix: "tm-sizes") { scratch in
            let root = scratch.appending(path: "DerivedData").path, models = scratch.appending(path: "models").path
            for path in [root, models] { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
            func item(_ path: String, _ size: FileSize) -> StorageItem {
                StorageItem(id: path, title: path, path: path, size: size, removal: .delete, isPreselected: false)
            }
            let reports = [
                StorageCategoryReport(category: StorageCategory(id: "derivedData", title: "", summary: "", risk: .low,
                                                                roots: [root, scratch.appending(path: "other").path]),
                                      status: .available, items: [item(root + "/A", .bytes(2)), item(root + "/B", .bytes(3))]),
                StorageCategoryReport(category: StorageCategory(id: "llmModels", title: "", summary: "", risk: .reportOnly,
                                                                roots: []),
                                      status: .available, items: [item(models, .bytes(9))]),
                StorageCategoryReport(category: StorageCategory(id: "caches", title: "", summary: "", risk: .low,
                                                                roots: [scratch.path]),
                                      status: .available, items: [item(scratch.path + "/x", .unreadable)]),
            ]
            let known = TimeMachineExclusions.knownSizes(from: reports)
            #expect(known[root] == .bytes(5))
            #expect(known[models] == .bytes(9))
            #expect(known[scratch.path] == nil)
            let runner = MockCommandRunner()
            let report = await exclusions(runner, sizes: [root: .bytes(100)])
                .scan([candidate(root), candidate(models)], knownSizes: known)
            #expect(report.suggestions.map(\.size) == [.bytes(5), .bytes(9)])
        }
    }

    @Test func scanSkipsAppContainersWithoutFullDiskAccess() async throws {
        try await ScratchDirectory.withCanonical(prefix: "tm-fda") { scratch in
            let vms = scratch.appending(path: "vms").path
            try FileManager.default.createDirectory(atPath: vms, withIntermediateDirectories: true)
            let runner = MockCommandRunner()
            let report = await exclusions(runner, fullDiskAccess: false).scan([candidate(vms, needsFullDiskAccess: true)])
            #expect(report.suggestions.isEmpty)
            #expect(runner.calls.isEmpty)
        }
    }

    @Test func failedQueryKeepsFoldersWithUnknownState() async throws {
        try await ScratchDirectory.withCanonical(prefix: "tm-fail") { scratch in
            let cache = scratch.appending(path: "cache").path
            try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
            let runner = MockCommandRunner()
            runner.stub("/usr/bin/tmutil isexcluded \(cache)", CommandResult(exitCode: 1, stdout: "", stderr: "kaputt"))
            let report = await exclusions(runner).scan([candidate(cache)])
            #expect(report.failure == "kaputt")
            #expect(report.suggestions.map(\.state) == [.unknown])
            #expect(report.suggestions.map(\.isPreselected) == [false])
        }
    }

    // MARK: Nach dem Aufräumen (#285)

    private func report(_ category: String, root: String, items: [(String, FileSize)]) -> StorageCategoryReport {
        StorageCategoryReport(category: StorageCategory(id: category, title: "", summary: "", risk: .low, roots: [root]),
                              status: .available,
                              items: items.map { StorageItem(id: $0, title: $0, path: $0, size: $1, removal: .delete,
                                                             isPreselected: false) })
    }

    /// Nur die Vorschläge der aufgeräumten Kategorien werden neu gelesen, ihre Größen aus dem Nachscan; unbetroffene große
    /// Ordner werden weder gemessen noch abgefragt. Inzwischen fehlende Ordner fallen weg.
    @Test func refreshUpdatesOnlyCleanedCategories() async throws {
        try await ScratchDirectory.withCanonical(prefix: "tm-refresh") { scratch in
            let derived = scratch.appending(path: "DerivedData").path, models = scratch.appending(path: "models").path
            let caches = scratch.appending(path: "Caches").path
            for path in [derived, models] { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
            let before = TimeMachineReport(suggestions: [
                suggestion(derived, .included, categoryID: "derivedData", size: .bytes(10_000_000_000)),
                suggestion(caches, .included, categoryID: "caches", size: .bytes(4)),
                suggestion(models, .excluded, risk: .medium, categoryID: "llmModels", size: .bytes(50_000_000_000)),
            ], failure: nil)
            let runner = MockCommandRunner()
            runner.stub("/usr/bin/tmutil isexcluded \(derived)", CommandResult(exitCode: 0, stdout: "[Included]  \(derived)\n"))
            let refreshed = await exclusions(runner, sizes: [derived: .bytes(77), models: .bytes(1)])
                .refresh(before, categories: ["derivedData", "caches"],
                         reports: [report("derivedData", root: derived, items: [(derived + "/A", .bytes(3))])])
            #expect(runner.calls == ["/usr/bin/tmutil isexcluded \(derived)"])
            #expect(refreshed.failure == nil)
            #expect(refreshed.suggestions.map(\.candidate.path) == [derived, models])
            #expect(refreshed.suggestions.map(\.size) == [.bytes(3), .bytes(50_000_000_000)])
            #expect(refreshed.suggestions.map(\.state) == [.included, .excluded])
        }
    }

    /// Scheitert `tmutil` beim Nachlesen, sind nur die betroffenen Status unbekannt; ein geleerter Ordner ohne Einträge im
    /// Nachscan wird gemessen.
    @Test func refreshAfterFailedQueryKeepsUnaffectedSuggestions() async throws {
        try await ScratchDirectory.withCanonical(prefix: "tm-refresh-fail") { scratch in
            let derived = scratch.appending(path: "DerivedData").path, models = scratch.appending(path: "models").path
            for path in [derived, models] { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
            let before = TimeMachineReport(suggestions: [
                suggestion(derived, .included, categoryID: "derivedData", size: .bytes(10_000_000_000)),
                suggestion(models, .excluded, categoryID: "llmModels", size: .bytes(9)),
            ], failure: nil)
            let runner = MockCommandRunner()
            runner.stub("/usr/bin/tmutil isexcluded \(derived)", CommandResult(exitCode: 1, stdout: "", stderr: "kaputt"))
            let refreshed = await exclusions(runner, sizes: [derived: .bytes(0)])
                .refresh(before, categories: ["derivedData"], reports: [report("derivedData", root: derived, items: [])])
            #expect(refreshed.failure == "kaputt")
            #expect(refreshed.suggestions.map(\.size) == [.bytes(0), .bytes(9)])
            #expect(refreshed.suggestions.map(\.state) == [.unknown, .excluded])
        }
    }

    @Test func refreshWithoutAffectedSuggestionsQueriesNothing() async {
        let before = TimeMachineReport(suggestions: [suggestion("/m", .excluded, categoryID: "llmModels", size: .bytes(9))],
                                       failure: "alt")
        let runner = MockCommandRunner()
        let refreshed = await exclusions(runner).refresh(before, categories: ["derivedData"], reports: [])
        #expect(refreshed == before)
        #expect(runner.calls.isEmpty)
    }

    /// Bis zum Nachscan – und dauerhaft, wenn er abbricht – nennen Liste und Bestätigung für aufgeräumte Kategorien
    /// keine veraltete Größe.
    @Test func cleanedCategoriesLoseTheirStaleSizes() {
        let before = TimeMachineReport(suggestions: [
            suggestion("/d", .included, categoryID: "derivedData", size: .bytes(10_000_000_000)),
            suggestion("/m", .included, categoryID: "llmModels", size: .bytes(9)),
        ], failure: nil)
        let stale = before.invalidatingSizes(ofCategories: ["derivedData"])
        #expect(stale.suggestions.map(\.size) == [.unknown, .bytes(9)])
        #expect(stale.suggestions.map(\.state) == [.included, .included])
        let confirmation = TimeMachinePresentation.confirmation(.exclude, targets: Array(stale.suggestions.prefix(1)))
        #expect(confirmation.message?.hasSuffix("Größe unbekannt") == true)
    }

    // MARK: Ausnehmen und wieder sichern

    /// Stubt die Nachprüfung nach einer Änderung: `isexcluded` für den Ordner und seine übergeordneten Ordner.
    private func stubVerification(_ runner: MockCommandRunner, _ path: String,
                                  _ states: [String: TimeMachineBackupState] = [:], default fallback: String) {
        let chain = TimeMachineExclusions.pathWithAncestors(path)
        let lines = chain.map { entry -> String in
            let label = switch states[entry] {
            case .excluded: "Excluded"
            case .included: "Included"
            case .unknown: "UNKNOWN"
            case nil: entry == path ? fallback : "Included"
            }
            return "[\(label)]  \(entry)"
        }
        runner.stub("/usr/bin/tmutil isexcluded " + chain.joined(separator: " "),
                    CommandResult(exitCode: 0, stdout: lines.joined(separator: "\n")))
    }

    @Test func pathWithAncestorsStopsBelowRoot() {
        #expect(TimeMachineExclusions.pathWithAncestors("/Users/a/.cache/m")
                == ["/Users/a/.cache/m", "/Users/a/.cache", "/Users/a", "/Users"])
    }

    @Test func excludeRunsAddExclusionOnlyForIncludedFolders() async throws {
        try await ScratchDirectory.withCanonical(prefix: "tm-exclude") { scratch in
            let a = scratch.appending(path: "a").path, b = scratch.appending(path: "b").path
            let c = scratch.appending(path: "c").path
            for path in [a, b, c] { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
            let runner = MockCommandRunner()
            runner.stub("/usr/bin/tmutil isexcluded \(a) \(b) \(c)", CommandResult(exitCode: 0, stdout: """
                [Included]  \(a)
                [Excluded]  \(b)
                [Included]  \(c)
                """))
            runner.stub("/usr/bin/tmutil addexclusion \(a)", CommandResult(exitCode: 0, stdout: ""))
            runner.stub("/usr/bin/tmutil addexclusion \(c)", CommandResult(exitCode: 1, stdout: "", stderr: "nein"))
            stubVerification(runner, a, default: "Excluded")
            let tm = exclusions(runner)
            let report = await tm.scan([a, b, c].map { candidate($0) })
            let outcomes = await tm.apply(.exclude, to: report.suggestions)
            #expect(runner.calls.filter { $0.contains("addexclusion") || $0.contains("removeexclusion") }
                    == ["/usr/bin/tmutil addexclusion \(a)", "/usr/bin/tmutil addexclusion \(c)"])
            #expect(outcomes.map(\.target) == [a, b, c])
            #expect(outcomes.map(\.method) == [.timeMachineExclude, .timeMachineExclude, .timeMachineExclude])
            #expect(outcomes.map(\.result) == [.removed, .skipped("Bereits ausgenommen"), .failed("Exit 1: nein")])
            #expect(outcomes.allSatisfy { $0.categoryID == TimeMachineExclusions.categoryID && $0.freedBytes == nil })
        }
    }

    @Test func includeRunsRemoveExclusionAndSkipsChangedFolders() async throws {
        try await ScratchDirectory.withCanonical(prefix: "tm-include") { scratch in
            let a = scratch.appending(path: "a").path, b = scratch.appending(path: "b").path
            for path in [a, b] { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
            let runner = MockCommandRunner()
            runner.stub("/usr/bin/tmutil isexcluded \(a) \(b)",
                        CommandResult(exitCode: 0, stdout: "[Excluded]  \(a)\n[Excluded]  \(b)\n"))
            runner.stub("/usr/bin/tmutil removeexclusion \(a)", CommandResult(exitCode: 0, stdout: ""))
            stubVerification(runner, a, default: "Included")
            let tm = exclusions(runner)
            let report = await tm.scan([a, b].map { candidate($0) })
            // Nach dem Scan durch etwas anderes ersetzt: kein Aufruf.
            try FileManager.default.removeItem(atPath: b)
            try FileManager.default.createDirectory(atPath: b, withIntermediateDirectories: true)
            let outcomes = await tm.apply(.include, to: report.suggestions)
            #expect(runner.calls.contains("/usr/bin/tmutil removeexclusion \(a)"))
            #expect(!runner.calls.contains("/usr/bin/tmutil removeexclusion \(b)"))
            #expect(outcomes.map(\.method) == [.timeMachineInclude, .timeMachineInclude])
            #expect(outcomes.map(\.result) == [.removed, .skipped("Geändert seit Scan")])
        }
    }

    /// Regression (#253-Review): `~/.cache` ausgenommen, `~/.cache/lm-studio/models` wieder sichern – `removeexclusion`
    /// endet mit 0, der Ordner bleibt über den Elternordner ausgenommen. Kein Erfolg, sondern ein verständlicher Grund.
    @Test func includeUnderExcludedParentIsNotReportedAsSuccess() async throws {
        try await ScratchDirectory.withCanonical(prefix: "tm-parent") { scratch in
            let parent = scratch.appending(path: ".cache").path
            let models = scratch.appending(path: ".cache/lm-studio/models").path
            try FileManager.default.createDirectory(atPath: models, withIntermediateDirectories: true)
            let runner = MockCommandRunner()
            runner.stub("/usr/bin/tmutil isexcluded \(models)", CommandResult(exitCode: 0, stdout: "[Excluded]  \(models)"))
            runner.stub("/usr/bin/tmutil removeexclusion \(models)", CommandResult(exitCode: 0, stdout: ""))
            stubVerification(runner, models, [parent: .excluded], default: "Included")
            let tm = exclusions(runner)
            let outcomes = await tm.apply(.include, to: await tm.scan([candidate(models)]).suggestions)
            #expect(outcomes.map(\.result) == [.failed("Weiter ausgenommen: übergeordneter Ordner \(parent) ist ausgenommen")])
        }
    }

    /// Fester Pfadausschluss (`addexclusion -p`) bleibt nach `removeexclusion`; ebenso ein Ausschluss, der nicht greift,
    /// und eine Nachprüfung, die scheitert: jeweils kein Erfolg.
    @Test func changeWithoutConfirmedTargetStateFails() async throws {
        try await ScratchDirectory.withCanonical(prefix: "tm-verify") { scratch in
            let fixed = scratch.appending(path: "fixed").path, stubborn = scratch.appending(path: "stubborn").path
            let silent = scratch.appending(path: "silent").path
            for path in [fixed, stubborn, silent] {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            }
            let runner = MockCommandRunner()
            runner.stub("/usr/bin/tmutil isexcluded \(fixed)", CommandResult(exitCode: 0, stdout: "[Excluded]  \(fixed)"))
            runner.stub("/usr/bin/tmutil isexcluded \(stubborn) \(silent)",
                        CommandResult(exitCode: 0, stdout: "[Included]  \(stubborn)\n[Included]  \(silent)"))
            for (verb, path) in [("removeexclusion", fixed), ("addexclusion", stubborn), ("addexclusion", silent)] {
                runner.stub("/usr/bin/tmutil \(verb) \(path)", CommandResult(exitCode: 0, stdout: ""))
            }
            stubVerification(runner, fixed, default: "Excluded")
            stubVerification(runner, stubborn, default: "Included")
            let tm = exclusions(runner)
            let included = await tm.apply(.include, to: await tm.scan([candidate(fixed)]).suggestions)
            #expect(included.map(\.result)
                    == [.failed("Weiter ausgenommen: fester Pfadausschluss, nur mit „sudo tmutil removeexclusion -p“ aufhebbar")])
            let excluded = await tm.apply(.exclude, to: await tm.scan([candidate(stubborn), candidate(silent)]).suggestions)
            #expect(excluded.map(\.result) == [
                .failed("Weiter gesichert: Time Machine hat den Ausschluss nicht übernommen"),
                .failed("Status nicht bestätigt: not stubbed: /usr/bin/tmutil isexcluded "
                        + TimeMachineExclusions.pathWithAncestors(silent).joined(separator: " ")),
            ])
        }
    }

    @Test func outcomesRoundTripThroughCleanupLog() throws {
        try ScratchDirectory.withCanonical(prefix: "tm-log") { scratch in
            let log = CleanupLog(url: scratch.appending(path: "CleanupLog.jsonl"))
            let outcome = StorageCleanOutcome(categoryID: TimeMachineExclusions.categoryID, target: "/a",
                                              method: .timeMachineExclude, freedBytes: nil, result: .removed)
            try log.append([outcome], at: Date(timeIntervalSince1970: 1))
            #expect(log.read().map(\.outcome) == [outcome])
        }
    }

    // MARK: Darstellung

    private func suggestion(_ path: String, _ state: TimeMachineBackupState, risk: StorageRisk = .low,
                            categoryID: String? = nil, size: FileSize = .unknown) -> TimeMachineSuggestion {
        TimeMachineSuggestion(candidate: candidate(path, risk: risk, categoryID: categoryID), size: size, state: state,
                              identity: nil)
    }

    @Test func categoryNoteSummarizesBackupState() {
        let suggestions = [suggestion("/a", .included, categoryID: "x"), suggestion("/b", .excluded, categoryID: "x"),
                           suggestion("/c", .excluded, categoryID: "y"), suggestion("/d", .included, categoryID: "z"),
                           suggestion("/e", .unknown, categoryID: "u"),
                           suggestion("/f", .included, categoryID: "iu"), suggestion("/g", .unknown, categoryID: "iu"),
                           suggestion("/h", .excluded, categoryID: "eu"), suggestion("/i", .unknown, categoryID: "eu"),
                           suggestion("/j", .included, categoryID: "ieu"), suggestion("/k", .excluded, categoryID: "ieu"),
                           suggestion("/l", .unknown, categoryID: "ieu")]
        #expect(TimeMachinePresentation.categoryNote("x", in: suggestions) == "Time Machine: teilweise gesichert")
        #expect(TimeMachinePresentation.categoryNote("y", in: suggestions) == "Time Machine: ausgenommen")
        #expect(TimeMachinePresentation.categoryNote("z", in: suggestions) == "Time Machine: gesichert")
        #expect(TimeMachinePresentation.categoryNote("u", in: suggestions) == "Time Machine: Status unbekannt")
        for categoryID in ["iu", "eu", "ieu"] {
            #expect(TimeMachinePresentation.categoryNote(categoryID, in: suggestions)
                == "Time Machine: Status teilweise unbekannt")
        }
        #expect(TimeMachinePresentation.categoryNote("none", in: suggestions) == nil)
    }

    @Test func confirmationListsOnlyFoldersThatChange() {
        let suggestions = [suggestion("/a", .included, size: .bytes(2_000_000_000)), suggestion("/b", .excluded),
                           suggestion("/c", .included)]
        let targets = TimeMachinePresentation.targets(of: .exclude, in: suggestions, selection: ["/a", "/b"])
        #expect(targets.map(\.id) == ["/a"])
        let confirmation = TimeMachinePresentation.confirmation(.exclude, targets: targets)
        #expect(confirmation.title == "1 Ordner aus Time Machine ausnehmen?")
        #expect(confirmation.message?.contains("/a") == true)
        #expect(confirmation.confirmTitle == "Ausnehmen")
        #expect(!confirmation.isDestructive)
        let include = TimeMachinePresentation.confirmation(
            .include, targets: TimeMachinePresentation.targets(of: .include, in: suggestions, selection: ["/a", "/b"]))
        #expect(include.title == "1 Ordner wieder sichern?")
    }

    @Test func outcomeTextsNameTheChange() {
        func outcome(_ method: StorageCleanOutcome.Method, _ result: StorageCleanOutcome.Result) -> StorageCleanOutcome {
            StorageCleanOutcome(categoryID: "tm", target: "/a", method: method, freedBytes: nil, result: result)
        }
        #expect(StoragePresentation.resultText(outcome(.timeMachineExclude, .removed)) == "aus Time Machine ausgenommen")
        #expect(StoragePresentation.resultText(outcome(.timeMachineInclude, .removed)) == "wieder von Time Machine gesichert")
        #expect(StoragePresentation.methodText(StorageCleanOutcome.Method.timeMachineExclude) == "Time-Machine-Ausschluss")
        #expect(StoragePresentation.summary([outcome(.timeMachineExclude, .removed), outcome(.timeMachineExclude, .removed),
                                             outcome(.timeMachineInclude, .removed),
                                             outcome(.timeMachineExclude, .failed("x"))])
                == "2 aus Time Machine ausgenommen, 1 wieder gesichert, 1 fehlgeschlagen")
    }

    @Test func snapshotNoteAfterCleaningWithLocalSnapshots() throws {
        let snapshots = StorageCategoryReport(
            category: TimeMachineSnapshotsProvider(runner: MockCommandRunner()).category, status: .available,
            items: [StorageItem(id: "s", title: "2026-10-20-120000", path: nil, size: .unknown, removal: .none,
                                isPreselected: false)])
        let freed = [StorageCleanOutcome(categoryID: "caches", target: "/a", method: .delete, freedBytes: 3_000_000_000,
                                         result: .removed),
                     StorageCleanOutcome(categoryID: "logs", target: "/b", method: .trash, freedBytes: 5, result: .removed)]
        let note = try #require(TimeMachinePresentation.snapshotNote(after: freed, reports: [snapshots]))
        #expect(note.text.contains("1 lokaler Snapshot"))
        #expect(note.text.contains(AppTexts.formattedSize(3_000_000_000)))
        #expect(note.command == "sudo tmutil thinlocalsnapshots / 3000000000 4")
        #expect(TimeMachinePresentation.snapshotNote(after: freed, reports: []) == nil)
        let trashOnly = [freed[1]]
        #expect(TimeMachinePresentation.snapshotNote(after: trashOnly, reports: [snapshots]) == nil)
    }
}
