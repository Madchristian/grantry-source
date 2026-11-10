import CoreServices
import Foundation
import Testing
@testable import ManagerKit

/// Erneuter Scan (TM-15.2, #401): Unveränderte Ordner werden übersprungen. Was sich geändert hat, meldet das
/// Änderungsprotokoll (FSEvents, auch Dateiinhalte); das Änderungsdatum eines Ordners sichert zusätzlich ab.
@Suite struct OccupancyIncrementalTests {
    private let fileSystem = FakeOccupancyFileSystem()
    private let journal = FakeOccupancyJournal()

    init() {
        fileSystem.addFile("a/b/c/deep", bytes: 1_000)
        fileSystem.addFile("a/b/file", bytes: 2_000)
        fileSystem.addFile("a/top", bytes: 4_000)
        fileSystem.addFile("x/y/z", bytes: 8_000)
    }

    private var scanner: OccupancyScanner { .testing(fileSystem, journal: journal) }

    private func firstScan() async throws -> OccupancyTree {
        let tree = try await scanner.scan(fileSystem.rootPath)
        fileSystem.resetReads()
        return tree
    }

    private func changes(folders: [String] = [], subtrees: [String] = []) -> OccupancyChanges {
        OccupancyChanges(folders: Set(folders.map(fileSystem.path)), subtrees: Set(subtrees.map(fileSystem.path)))
    }

    @Test func rescanReadsOnlyChangedFolders() async throws {
        let first = try await firstScan()
        fileSystem.addFile("a/b/new", bytes: 16_000)
        journal.report(changes(folders: ["a/b"]))

        let second = try await scanner.scan(fileSystem.rootPath, reusing: first)

        #expect(fileSystem.reads == [fileSystem.path("a/b")])
        #expect(second.root.allocatedBytes == 31_000)
        #expect(second.folder(atPath: fileSystem.path("a/b"))?.allocatedBytes == 19_000)
        #expect(second.folder(atPath: fileSystem.path("a/b/c"))?.allocatedBytes == 1_000)
        #expect(second.folder(atPath: fileSystem.path("x/y"))?.allocatedBytes == 8_000)
        // Das erste Ergebnis bleibt unverändert.
        #expect(first.root.allocatedBytes == 15_000)
    }

    @Test func rescanWithoutChangesReadsNothing() async throws {
        let first = try await firstScan()
        let second = try await scanner.scan(fileSystem.rootPath, reusing: first)
        #expect(fileSystem.reads.isEmpty)
        #expect(second.root.allocatedBytes == first.root.allocatedBytes)
        #expect(second.folderCount == first.folderCount)
    }

    /// Eine gewachsene Datei ändert das Änderungsdatum ihres Ordners nicht – das Protokoll meldet den Ordner trotzdem.
    @Test func picksUpGrownFilesReportedByTheJournal() async throws {
        let first = try await firstScan()
        fileSystem.addFile("x/y/z", bytes: 80_000)
        journal.report(changes(folders: ["x/y"]))

        let second = try await scanner.scan(fileSystem.rootPath, reusing: first)

        #expect(second.folder(atPath: fileSystem.path("x"))?.allocatedBytes == 80_000)
        #expect(fileSystem.reads == [fileSystem.path("x/y")])
    }

    /// Absicherung über das Änderungsdatum: Unterordner eines neu gelesenen Ordners mit neuem Datum werden gelesen,
    /// auch wenn das Protokoll sie nicht nennt.
    @Test func readsSubfoldersWhoseModificationChanged() async throws {
        let first = try await firstScan()
        fileSystem.addFile("a/b/late", bytes: 32_000)
        fileSystem.setModification(of: "a/b", to: 99)
        journal.report(changes(folders: ["a"]))

        let second = try await scanner.scan(fileSystem.rootPath, reusing: first)

        #expect(Set(fileSystem.reads) == [fileSystem.path("a"), fileSystem.path("a/b")])
        #expect(second.folder(atPath: fileSystem.path("a/b"))?.allocatedBytes == 35_000)
    }

    @Test func newFoldersAreReadCompletely() async throws {
        let first = try await firstScan()
        fileSystem.addFile("n/m/file", bytes: 500)
        journal.report(changes(folders: [""]))

        let second = try await scanner.scan(fileSystem.rootPath, reusing: first)

        #expect(Set(fileSystem.reads) == [fileSystem.rootPath, fileSystem.path("n"), fileSystem.path("n/m")])
        #expect(second.root.allocatedBytes == 15_500)
    }

    @Test func removedFoldersDisappear() async throws {
        let first = try await firstScan()
        fileSystem.remove("x")
        journal.report(changes(folders: [""]))

        let second = try await scanner.scan(fileSystem.rootPath, reusing: first)

        #expect(second.folder(atPath: fileSystem.path("x")) == nil)
        #expect(second.root.allocatedBytes == 7_000)
        #expect(fileSystem.reads == [fileSystem.rootPath])
    }

    /// `MustScanSubDirs`: Der ganze Unterbaum wird neu gelesen.
    @Test func changedSubtreesAreReadCompletely() async throws {
        let first = try await firstScan()
        journal.report(changes(subtrees: ["a"]))

        _ = try await scanner.scan(fileSystem.rootPath, reusing: first)

        #expect(Set(fileSystem.reads) == Set(["a", "a/b", "a/b/c"].map(fileSystem.path)))
    }

    @Test func journalWithoutAnswerMeansFullScan() async throws {
        let first = try await firstScan()
        journal.report(nil)

        _ = try await scanner.scan(fileSystem.rootPath, reusing: first)

        #expect(fileSystem.reads.count == first.folderCount)
    }

    @Test func treeWithoutMarkMeansFullScan() async throws {
        journal.setAvailable(false)
        let first = try await firstScan()
        journal.setAvailable(true)

        _ = try await scanner.scan(fileSystem.rootPath, reusing: first)

        #expect(fileSystem.reads.count == first.folderCount)
        #expect(!journal.calls.contains("changes"))
    }

    @Test func replacedRootMeansFullScan() async throws {
        let first = try await firstScan()
        fileSystem.replaceFolder("")

        _ = try await scanner.scan(fileSystem.rootPath, reusing: first)

        #expect(fileSystem.reads.count == first.folderCount)
    }

    @Test func treeOfAnotherRootIsNotReused() async throws {
        let other = FakeOccupancyFileSystem(rootPath: "/fake/other")
        other.addFile("a", bytes: 1)
        let foreign = try await OccupancyScanner.testing(other, journal: journal).scan(other.rootPath)

        _ = try await scanner.scan(fileSystem.rootPath, reusing: foreign)

        #expect(fileSystem.reads.count == 6)
    }

    /// Ordner, die beim letzten Mal nicht lesbar waren, werden immer erneut versucht (etwa nach dem Erteilen des
    /// Festplattenvollzugriffs).
    @Test func uncapturedFoldersAreRetried() async throws {
        fileSystem.addFolder("x/locked", isReadable: false)
        fileSystem.addFile("x/locked/data", bytes: 64_000)
        let first = try await firstScan()
        #expect(first.root.uncapturedCount == 1)
        fileSystem.setReadable("x/locked", true)

        let second = try await scanner.scan(fileSystem.rootPath, reusing: first)

        #expect(fileSystem.reads == [fileSystem.path("x/locked")])
        #expect(second.root.uncapturedCount == 0)
        #expect(second.root.allocatedBytes == 79_000)
    }

    /// Hardlinks bleiben auch nach einem Teilscan einmal gezählt.
    @Test func hardlinksStayCountedOnceAfterRescan() async throws {
        fileSystem.addFile("a/link", bytes: 100_000, inode: 900, links: 2)
        fileSystem.addFile("x/link", bytes: 100_000, inode: 900, links: 2)
        let first = try await firstScan()
        #expect(first.root.allocatedBytes == 115_000)
        fileSystem.remove("a/link")
        fileSystem.addFile("x/link", bytes: 100_000, inode: 900, links: 1)
        journal.report(changes(folders: ["a"]))

        let second = try await scanner.scan(fileSystem.rootPath, reusing: first)

        #expect(second.folder(atPath: fileSystem.path("a"))?.allocatedBytes == 7_000)
        #expect(second.folder(atPath: fileSystem.path("x"))?.allocatedBytes == 108_000)
        #expect(second.root.allocatedBytes == 115_000)
    }

    /// Die neue Marke entsteht vor der Abfrage der Änderungen: Was währenddessen geschieht, meldet der nächste Scan.
    @Test func marksBeforeAskingForChanges() async throws {
        let first = try await firstScan()
        _ = try await scanner.scan(fileSystem.rootPath, reusing: first)
        #expect(journal.calls == ["mark", "mark", "changes"])
        #expect(journal.queriedMarks == [OccupancyChangeMark(journal: "fake", eventID: 1)])
    }
}

/// Aus FSEvents-Ereignissen werden geänderte Ordner (Inhalt) und Unterbäume (`MustScanSubDirs`).
@Suite struct OccupancyChangesTests {
    private let root = "/Users/someone"

    @Test func foldersBelowTheRootAreCollected() throws {
        let changes = try #require(OccupancyChanges(events: [
            (path: "/Users/someone/Library/Caches/", flags: 0),
            (path: "/Users/someone/", flags: 0),
            (path: "/Users/", flags: 0),
            (path: "/Users/someoneelse/x/", flags: 0),
            (path: "/Users/someone", flags: UInt32(kFSEventStreamEventFlagHistoryDone)),
        ], root: root))
        #expect(changes.folders == ["/Users/someone/Library/Caches", "/Users/someone"])
        #expect(changes.subtrees.isEmpty)
    }

    @Test func mustScanSubDirsMarksTheSubtree() throws {
        let changes = try #require(OccupancyChanges(events: [
            (path: "/Users/someone/Library/", flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs)),
        ], root: root))
        #expect(changes.subtrees == ["/Users/someone/Library"])
    }

    @Test func mustScanSubDirsAboveTheRootMarksTheRoot() throws {
        let changes = try #require(OccupancyChanges(events: [
            (path: "/Users/", flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs)),
        ], root: root))
        #expect(changes.subtrees == [root])
    }

    @Test(arguments: [
        kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagEventIdsWrapped,
        kFSEventStreamEventFlagRootChanged, kFSEventStreamEventFlagMount, kFSEventStreamEventFlagUnmount,
    ])
    func lostOrStructuralEventsRequireAFullScan(flag: Int) {
        #expect(OccupancyChanges(events: [(path: "/Users/someone/a/", flags: UInt32(flag))], root: root) == nil)
    }

    /// Schreibweisen (Groß-/Kleinschreibung, Unicode-Normalform) werden vorsichtig gleich behandelt.
    @Test func planMatchesSpellingsConservatively() {
        let plan = OccupancyRescanPlan(OccupancyChanges(
            folders: ["/Users/someone/Ca\u{0308}fe"], subtrees: ["/Users/someone/BIG"]
        ))
        #expect(plan.isListingChanged("/Users/someone/c\u{00E4}fe"))
        #expect(plan.hasChanges(atOrBelow: "/Users/someone"))
        #expect(plan.hasChanges(atOrBelow: "/users/someone/big"))
        #expect(plan.isSubtreeChanged("/Users/someone/big"))
        #expect(!plan.hasChanges(atOrBelow: "/Users/someone/other"))
        #expect(!plan.isListingChanged("/Users/someone"))
    }
}

/// Ausnahmen beim erneuten Scan: Was ausgenommen wird, ändert sich mit dem Scanner, nicht mit dem Protokoll.
@Suite struct OccupancyIncrementalExclusionTests {
    @Test func newlyExcludedFoldersAreNotReused() async throws {
        let fileSystem = FakeOccupancyFileSystem(), journal = FakeOccupancyJournal()
        fileSystem.addFile("Library/Containers/app/data", bytes: 1_000)
        fileSystem.addFile("Library/other", bytes: 10)
        let first = try await OccupancyScanner.testing(fileSystem, journal: journal).scan(fileSystem.rootPath)
        journal.report(OccupancyChanges(folders: [fileSystem.path("Library")]))

        let second = try await OccupancyScanner.testing(fileSystem, journal: journal,
                                                        excluded: [fileSystem.path("Library/Containers")])
            .scan(fileSystem.rootPath, reusing: first)

        #expect(second.folder(atPath: fileSystem.path("Library/Containers"))?.state == .uncaptured(.excluded))
        #expect(second.root.allocatedBytes == 10)
    }

    @Test func formerlyExcludedFoldersAreReadOnceAllowed() async throws {
        let fileSystem = FakeOccupancyFileSystem(), journal = FakeOccupancyJournal()
        fileSystem.addFile("Library/Containers/app/data", bytes: 1_000)
        let excluded: Set = [fileSystem.path("Library/Containers")]
        let first = try await OccupancyScanner.testing(fileSystem, journal: journal, excluded: excluded)
            .scan(fileSystem.rootPath)
        #expect(first.root.uncapturedCount == 1)
        fileSystem.resetReads()

        let second = try await OccupancyScanner.testing(fileSystem, journal: journal).scan(fileSystem.rootPath, reusing: first)

        #expect(Set(fileSystem.reads) == Set(["Library/Containers", "Library/Containers/app"].map(fileSystem.path)))
        #expect(second.root.allocatedBytes == 1_000)
        #expect(second.root.isComplete)
    }

    /// Ein unvollständig gelesener Ordner wird erneut gelesen, seine unveränderten Unterordner bleiben übernommen.
    @Test func incompleteFoldersAreRereadButKeepTheirSubfolders() async throws {
        let fileSystem = FakeOccupancyFileSystem(), journal = FakeOccupancyJournal()
        fileSystem.addFile("mixed/sub/deep", bytes: 100)
        fileSystem.addUnstatableEntry("mixed/broken")
        let first = try await OccupancyScanner.testing(fileSystem, journal: journal).scan(fileSystem.rootPath)
        fileSystem.resetReads()

        _ = try await OccupancyScanner.testing(fileSystem, journal: journal).scan(fileSystem.rootPath, reusing: first)

        #expect(fileSystem.reads == [fileSystem.path("mixed")])
    }
}
