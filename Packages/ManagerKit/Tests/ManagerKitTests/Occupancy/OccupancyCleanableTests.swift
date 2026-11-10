import Foundation
import Testing
import TestSupport
@testable import ManagerKit

/// Über Speicher aufräumbarer Platz im Belegungsbaum (TM-15.4, #403): Orte aufräumender Kategorien ohne ihre bewusst
/// ausgelassenen Einträge, verschachtelte Orte einmal, Nur-Bericht-Kategorien nie.
@Suite struct OccupancyCleanableTests {
    private static func category(_ id: String, risk: StorageRisk = .low, roots: [String]) -> StorageCategory {
        StorageCategory(id: id, title: id, summary: "", risk: risk, roots: roots)
    }

    /// `/fake/home/Library/Caches` räumt auf und lässt `keep` aus; `Homebrew` darin ist eine eigene Kategorie, `Models`
    /// nur ein Bericht.
    private static func hints(root: String = "/fake/home") -> OccupancyHints {
        let caches = PathCategoryProvider(category: category("caches", roots: [root + "/Library/Caches"]),
                                          excludedNames: ["keep", "Homebrew"], measurer: FixedSizeMeasurer())
        let homebrew = PathCategoryProvider(category: category("homebrew", risk: .medium,
                                                               roots: [root + "/Library/Caches/Homebrew"]),
                                            measurer: FixedSizeMeasurer())
        let models = ReportOnlyProvider(category: category("models", risk: .reportOnly, roots: []),
                                        paths: { [root + "/Models"] }, measurer: FixedSizeMeasurer())
        return OccupancyHints(providers: [caches, homebrew, models], timeMachineCandidates: [])
    }

    private static func tree() async throws -> (OccupancyTree, FakeOccupancyFileSystem) {
        let fileSystem = FakeOccupancyFileSystem()
        fileSystem.addFile("Library/Caches/app/a", bytes: 1_000)
        fileSystem.addFile("Library/Caches/app/deep/b", bytes: 500)
        fileSystem.addFile("Library/Caches/keep/c", bytes: 4_000)
        fileSystem.addFile("Library/Caches/Homebrew/d", bytes: 2_000)
        fileSystem.addFile("Library/Caches/loose", bytes: 100)
        fileSystem.addFile("Library/Prefs/e", bytes: 50)
        fileSystem.addFile("Models/m", bytes: 9_000)
        return (try await OccupancyScanner.testing(fileSystem).scan(fileSystem.rootPath), fileSystem)
    }

    @Test func sumsCleanableLocationsWithoutLeftOutEntries() async throws {
        let (tree, fileSystem) = try await Self.tree()
        let cleanable = Self.hints().cleanable(in: tree)

        // app 1 500 + lose Datei 100 + Homebrew 2 000; keep und der Bericht zählen nicht.
        #expect(cleanable.total == 3_600)
        func bytes(_ relative: String) throws -> Int64 {
            cleanable.bytes(in: try #require(tree.folder(atPath: fileSystem.path(relative))), of: tree)
        }
        #expect(try bytes("Library") == 3_600)
        #expect(try bytes("Library/Caches") == 3_600)
        #expect(try bytes("Library/Caches/app") == 1_500)
        #expect(try bytes("Library/Caches/app/deep") == 500)
        #expect(try bytes("Library/Caches/Homebrew") == 2_000)
        #expect(try bytes("Library/Caches/keep") == 0)
        #expect(try bytes("Library/Prefs") == 0)
        #expect(try bytes("Models") == 0)
    }

    /// Ein Scan des ganzen Datenträgers liefert Pfade in der Schreibweise des Datenvolumes; die Orte der Kategorien
    /// stehen als Firmlink.
    @Test func findsLocationsInDataVolumeSpelling() async throws {
        let fileSystem = FakeOccupancyFileSystem(rootPath: "/System/Volumes/Data")
        fileSystem.addFile("Users/me/Library/Caches/app/a", bytes: 700)
        let tree = try await OccupancyScanner.testing(fileSystem).scan(fileSystem.rootPath)

        #expect(Self.hints(root: "/Users/me").cleanable(in: tree).total == 700)
    }

    @Test func emptyWithoutCleanableLocations() async throws {
        let (tree, _) = try await Self.tree()
        let hints = OccupancyHints(providers: [], timeMachineCandidates: [])
        #expect(hints.cleanable(in: tree).total == 0)
        #expect(hints.cleanable(in: tree).bytes(in: tree.root, of: tree) == 0)
    }

    // MARK: Geschützte Orte

    /// Ohne Festplattenvollzugriff würde Lesen dieser Orte eine Rückfrage von macOS auslösen.
    @Test func protectedPlacesLieInTheHomeFolder() {
        let places = OccupancyProtectedPlaces.folders(inHome: "/Users/me")
        #expect(places.count == 11)
        #expect(places.contains("/Users/me/Desktop"))
        #expect(places.contains("/Users/me/Library/Containers"))
        #expect(places.allSatisfy { $0.hasPrefix("/Users/me/") })
    }

    /// Beim Scan des ganzen Datenträgers vergleicht der Scanner Pfade in der Schreibweise des Datenvolumes.
    @Test func protectedPlacesFollowTheScanRoot() {
        let home = OccupancyProtectedPlaces.folders(inHome: "/Users/me", scanRoot: "/Users/me")
        let volume = OccupancyProtectedPlaces.folders(inHome: "/Users/me", scanRoot: "/System/Volumes/Data")
        #expect(home.contains("/Users/me/Downloads"))
        #expect(volume.contains("/System/Volumes/Data/Users/me/Downloads"))
        #expect(volume.count == home.count)
    }
}
