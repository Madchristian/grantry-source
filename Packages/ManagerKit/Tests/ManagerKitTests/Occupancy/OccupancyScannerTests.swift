import Darwin
import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

/// Belegungsscanner mit Fake-Dateisystem (TM-15.2, #401): Summen, größte Dateien, Hardlinks, Symlinks, Volumegrenzen,
/// fehlende Rechte, Abbruch, Drosselung und Fortschritt.
@Suite struct OccupancyScannerTests {
    @Test func sumsAllocatedBytesPerFolder() async throws {
        let fileSystem = FakeOccupancyFileSystem()
        fileSystem.addFile("Library/Caches/a", bytes: 4_096)
        fileSystem.addFile("Library/b", bytes: 8_192)
        fileSystem.addFile("c", bytes: 100)

        let tree = try await OccupancyScanner.testing(fileSystem).scan(fileSystem.rootPath)

        #expect(tree.rootPath == fileSystem.rootPath)
        #expect(tree.root.allocatedBytes == 12_388)
        #expect(tree.root.fileCount == 3)
        #expect(tree.root.state == .complete)
        #expect(tree.root.isComplete)
        let library = try #require(tree.folder(atPath: fileSystem.path("Library")))
        #expect(library.allocatedBytes == 12_288)
        #expect(library.fileCount == 2)
        #expect(tree.path(of: library) == fileSystem.path("Library"))
        let caches = try #require(tree.folder(atPath: fileSystem.path("Library/Caches")))
        #expect(caches.allocatedBytes == 4_096)
        #expect(tree.parent(of: caches) == library)
        #expect(tree.parent(of: tree.root) == nil)
        #expect(tree.folder(atPath: fileSystem.path("missing")) == nil)
        #expect(tree.folder(atPath: "/elsewhere") == nil)
    }

    @Test func subfoldersAreSortedBySizeThenName() async throws {
        let fileSystem = FakeOccupancyFileSystem()
        fileSystem.addFile("small/a", bytes: 10)
        fileSystem.addFile("big/a", bytes: 1_000)
        fileSystem.addFile("beta/a", bytes: 500)
        fileSystem.addFile("alpha/a", bytes: 500)

        let tree = try await OccupancyScanner.testing(fileSystem).scan(fileSystem.rootPath)

        #expect(tree.subfolders(of: tree.root).map(\.name) == ["big", "alpha", "beta", "small"])
        #expect(tree.root.subfolderCount == 4)
        #expect(tree.folderCount == 5)
    }

    /// Je Ordner nur die größten 20 Dateien, absteigend, bei Gleichstand nach Name.
    @Test func keepsTheTwentyLargestFilesPerFolder() async throws {
        let fileSystem = FakeOccupancyFileSystem()
        for index in 0..<25 { fileSystem.addFile(String(format: "f%02d", index), bytes: Int64(index % 22) * 1_000) }

        let tree = try await OccupancyScanner.testing(fileSystem).scan(fileSystem.rootPath)

        let largest = tree.root.largestFiles
        #expect(largest.count == OccupancyScanner.largestFileCount)
        #expect(largest.first == OccupancyFile(name: "f21", allocatedBytes: 21_000))
        #expect(largest.prefix(3).map(\.name) == ["f21", "f20", "f19"])
        #expect(largest.map(\.allocatedBytes) == largest.map(\.allocatedBytes).sorted(by: >))
        // f02 und f24 haben je 2 000 Byte, nur einer passt noch hinein: bei Gleichstand zählt der Name.
        #expect(largest.suffix(2).map(\.name) == ["f03", "f02"])
        #expect(!largest.contains { $0.name == "f24" })
        #expect(tree.root.fileCount == 25)
    }

    /// Ein Hardlink (dieselbe Datei unter zwei Namen) zählt im Baum genau einmal.
    @Test func hardlinksCountOnce() async throws {
        let fileSystem = FakeOccupancyFileSystem()
        fileSystem.addFile("a/shared", bytes: 1_000_000, inode: 77, links: 2)
        fileSystem.addFile("b/shared", bytes: 1_000_000, inode: 77, links: 2)
        fileSystem.addFile("b/own", bytes: 10)

        let tree = try await OccupancyScanner.testing(fileSystem).scan(fileSystem.rootPath)

        #expect(tree.root.allocatedBytes == 1_000_010)
        let folders = tree.subfolders(of: tree.root)
        #expect(folders.map(\.allocatedBytes).reduce(0, +) == tree.root.allocatedBytes)
        #expect(folders.filter { $0.allocatedBytes >= 1_000_000 }.count == 1)
        // Als Datei erscheint er in beiden Ordnern.
        #expect(folders.allSatisfy { $0.largestFiles.contains { $0.name == "shared" } })
    }

    @Test func symlinksAreNeitherFollowedNorCounted() async throws {
        let fileSystem = FakeOccupancyFileSystem()
        fileSystem.addFile("real/a", bytes: 4_096)
        fileSystem.addSymlink("link")

        let tree = try await OccupancyScanner.testing(fileSystem).scan(fileSystem.rootPath)

        #expect(tree.root.allocatedBytes == 4_096)
        #expect(tree.root.fileCount == 1)
        #expect(tree.subfolders(of: tree.root).map(\.name) == ["real"])
        #expect(!fileSystem.reads.contains(fileSystem.path("link")))
    }

    /// Andere Volumes (Einhängepunkte, auch Netzlaufwerke) werden nicht betreten.
    @Test func doesNotCrossVolumeBoundaries() async throws {
        let fileSystem = FakeOccupancyFileSystem()
        fileSystem.addFolder("External", device: 9)
        fileSystem.addFile("External/huge", bytes: 1 << 40)
        fileSystem.addMountPoint("Share", isLocal: false)
        fileSystem.addFile("own", bytes: 100)

        let tree = try await OccupancyScanner.testing(fileSystem).scan(fileSystem.rootPath)

        #expect(tree.root.allocatedBytes == 100)
        let external = try #require(tree.folder(atPath: fileSystem.path("External")))
        #expect(external.state == .otherVolume(isLocal: true))
        #expect(external.allocatedBytes == 0)
        let share = try #require(tree.folder(atPath: fileSystem.path("Share")))
        #expect(share.state == .otherVolume(isLocal: false))
        #expect(fileSystem.reads == [fileSystem.rootPath])
        // Ausgelassene Volumes sind keine Lücke.
        #expect(tree.root.uncapturedCount == 0)
    }

    /// Nicht lesbare Ordner zählen als nicht erfassbar; die Summen enthalten das Lesbare.
    @Test func unreadableFoldersAreUncapturedButSummed() async throws {
        let fileSystem = FakeOccupancyFileSystem()
        fileSystem.addFolder("Library/Private", isReadable: false)
        fileSystem.addFile("Library/Private/secret", bytes: 1 << 30)
        fileSystem.addFile("Library/Public/a", bytes: 2_048)
        fileSystem.addFile("Documents/b", bytes: 1_024)

        let tree = try await OccupancyScanner.testing(fileSystem).scan(fileSystem.rootPath)

        #expect(tree.root.allocatedBytes == 3_072)
        #expect(tree.root.uncapturedCount == 1)
        #expect(!tree.root.isComplete)
        let library = try #require(tree.folder(atPath: fileSystem.path("Library")))
        #expect(library.uncapturedCount == 1)
        #expect(library.state == .complete)
        let locked = try #require(tree.folder(atPath: fileSystem.path("Library/Private")))
        #expect(locked.state == .uncaptured(.permissionDenied))
        #expect(locked.allocatedBytes == 0)
        let documents = try #require(tree.folder(atPath: fileSystem.path("Documents")))
        #expect(documents.isComplete)
        #expect(tree.uncapturedFolders().map { tree.path(of: $0) } == [fileSystem.path("Library/Private")])
    }

    @Test func folderWithUnreadableEntriesIsIncomplete() async throws {
        let fileSystem = FakeOccupancyFileSystem()
        fileSystem.addFile("mixed/a", bytes: 500)
        fileSystem.addUnstatableEntry("mixed/b")

        let tree = try await OccupancyScanner.testing(fileSystem).scan(fileSystem.rootPath)

        let mixed = try #require(tree.folder(atPath: fileSystem.path("mixed")))
        #expect(mixed.state == .uncaptured(.incomplete))
        #expect(mixed.allocatedBytes == 500)
        #expect(tree.root.uncapturedCount == 1)
    }

    /// iCloud-Platzhalter belegen lokal nichts und werden nicht nachgeladen.
    @Test func cloudOnlyFoldersAreNotEntered() async throws {
        let fileSystem = FakeOccupancyFileSystem()
        fileSystem.addFolder("Cloud", isDataless: true)
        fileSystem.addFile("Cloud/remote", bytes: 1 << 30)

        let tree = try await OccupancyScanner.testing(fileSystem).scan(fileSystem.rootPath)

        let cloud = try #require(tree.folder(atPath: fileSystem.path("Cloud")))
        #expect(cloud.state == .cloudOnly)
        #expect(cloud.allocatedBytes == 0)
        #expect(fileSystem.reads == [fileSystem.rootPath])
        #expect(tree.root.isComplete)
    }

    @Test func excludedFoldersAreNotEntered() async throws {
        let fileSystem = FakeOccupancyFileSystem()
        fileSystem.addFile("Library/Containers/x", bytes: 1 << 20)
        fileSystem.addFile("Library/y", bytes: 10)

        let tree = try await OccupancyScanner.testing(fileSystem, excluded: [fileSystem.path("Library/Containers")])
            .scan(fileSystem.rootPath)

        let containers = try #require(tree.folder(atPath: fileSystem.path("Library/Containers")))
        #expect(containers.state == .uncaptured(.excluded))
        #expect(tree.root.allocatedBytes == 10)
        #expect(!fileSystem.reads.contains(fileSystem.path("Library/Containers")))
    }

    /// Ein Ordner, der zwischen dem Lesen seines Elternordners und seinem eigenen verschwindet, fehlt im Ergebnis.
    @Test func vanishedFoldersAreDropped() async throws {
        let fileSystem = FakeOccupancyFileSystem()
        fileSystem.addFile("gone/a", bytes: 100)
        fileSystem.addFile("kept/a", bytes: 200)
        fileSystem.makeVanish("gone")

        let tree = try await OccupancyScanner.testing(fileSystem).scan(fileSystem.rootPath)

        #expect(tree.subfolders(of: tree.root).map(\.name) == ["kept"])
        #expect(tree.root.allocatedBytes == 200)
    }

    @Test func replacedFoldersAreUncaptured() async throws {
        let fileSystem = FakeOccupancyFileSystem()
        fileSystem.addFile("swapped/a", bytes: 100)
        // Ersetzt, nachdem der Elternordner ihn gelistet hat, bevor er selbst gelesen wird.
        fileSystem.onRead { path in
            if path == fileSystem.path("swapped") { fileSystem.replaceFolder("swapped") }
        }

        let tree = try await OccupancyScanner.testing(fileSystem).scan(fileSystem.rootPath)

        #expect(tree.folder(atPath: fileSystem.path("swapped"))?.state == .uncaptured(.changed))
    }

    @Test func networkRootIsRejected() async {
        let fileSystem = FakeOccupancyFileSystem(networkRoots: ["/Volumes/Share"])
        await #expect(throws: OccupancyScanError.networkVolume) {
            try await OccupancyScanner.testing(fileSystem).scan("/Volumes/Share")
        }
        #expect(fileSystem.reads.isEmpty)
    }

    @Test func missingRootIsUnavailable() async {
        let fileSystem = FakeOccupancyFileSystem()
        await #expect(throws: OccupancyScanError.unavailable) {
            try await OccupancyScanner.testing(fileSystem).scan("/fake/other")
        }
    }

    @Test func vanishedRootIsUnavailable() async {
        let fileSystem = FakeOccupancyFileSystem()
        fileSystem.makeVanish("")
        await #expect(throws: OccupancyScanError.unavailable) {
            try await OccupancyScanner.testing(fileSystem).scan(fileSystem.rootPath)
        }
    }

    /// Abbruch: Der Scan endet mit `CancellationError`; nach dem Abbruch liest kein Leser einen weiteren Ordner.
    @Test(.timeLimit(.minutes(1))) func cancellationStopsReading() async throws {
        let fileSystem = FakeOccupancyFileSystem()
        for index in 0..<50 { fileSystem.addFile("folder\(index)/a", bytes: 10) }
        let reached = Latch(), proceed = Latch()
        fileSystem.onRead { path in
            guard path != fileSystem.rootPath else { return }
            reached.release()
            proceed.wait()
        }
        let scanner = OccupancyScanner.testing(fileSystem)
        let scan = Task { try await scanner.scan(fileSystem.rootPath) }
        // Beide Leser hängen in ihrem ersten Unterordner.
        await onOwnThread {
            reached.wait()
            reached.wait()
        }
        scan.cancel()
        proceed.release(50)

        await #expect(throws: CancellationError.self) { try await scan.value }
        #expect(fileSystem.reads.count == 1 + OccupancyScanner.maximumReaders)
    }

    @Test func cancelledTaskReadsNothing() async throws {
        let fileSystem = FakeOccupancyFileSystem()
        fileSystem.addFile("a/b", bytes: 1)
        let scanner = OccupancyScanner.testing(fileSystem)
        let scan = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await scanner.scan(fileSystem.rootPath)
        }
        await #expect(throws: CancellationError.self) { try await scan.value }
        #expect(fileSystem.reads.isEmpty)
    }

    /// Höchstens zwei Leser gleichzeitig, beide mit gedrosselter E/A, ohne iCloud-Nachladen und mit der CPU-Priorität
    /// von QoS utility.
    @Test(.timeLimit(.minutes(1))) func readsWithTwoThrottledUtilityThreads() async throws {
        let fileSystem = FakeOccupancyFileSystem()
        for index in 0..<40 { fileSystem.addFile("folder\(index)/sub/a", bytes: 10) }
        let barrier = ThreadBarrier(parties: 2)
        fileSystem.onRead { path in
            if path != fileSystem.rootPath { barrier.arriveAndWait() }
        }

        let tree = try await OccupancyScanner.testing(fileSystem).scan(fileSystem.rootPath)

        #expect(tree.root.fileCount == 40)
        #expect(fileSystem.maximumConcurrentReads == 2)
        #expect(fileSystem.readerPolicies == [.throttledUtility])
    }

    /// Fortschritt höchstens einmal je Sekunde (#530): Jeder gelesene Ordner stellt die Testuhr um 10 ms vor.
    @Test func reportsProgressAtMostOncePerSecond() async throws {
        let fileSystem = FakeOccupancyFileSystem()
        for index in 0..<199 { fileSystem.addFile("folder\(index)/a", bytes: 1_000) }
        let clock = TestClock()
        fileSystem.onRead { _ in clock.advance(by: .milliseconds(10)) }
        let reports = Mutex<[OccupancyProgress]>([])

        let tree = try await OccupancyScanner.testing(fileSystem, clock: clock)
            .scan(fileSystem.rootPath) { progress in reports.withLock { $0.append(progress) } }

        let progress = reports.withLock { $0 }
        // 200 Ordner zu je 10 ms sind 2 s: höchstens zwei Meldungen.
        #expect(OccupancyScanner.progressInterval == .seconds(1))
        #expect((1...2).contains(progress.count))
        #expect(progress.map(\.folders) == progress.map(\.folders).sorted())
        let last = try #require(progress.last)
        #expect(last.files <= tree.root.fileCount)
        #expect(last.allocatedBytes <= tree.root.allocatedBytes)
    }
}

@Suite struct OccupancyProgressReporterTests {
    @Test func reportsOncePerIntervalAtMost() {
        let now = Mutex(Duration.zero)
        let reports = Mutex<[OccupancyProgress]>([])
        let reporter = OccupancyProgressReporter(interval: .milliseconds(250), elapsed: { now.withLock { $0 } }) { progress in
            reports.withLock { $0.append(progress) }
        }
        reporter.add(folders: 1, files: 2, bytes: 100)
        now.withLock { $0 = .milliseconds(249) }
        reporter.add(folders: 1, files: 0, bytes: 0)
        #expect(reports.withLock { $0 }.isEmpty)
        now.withLock { $0 = .milliseconds(250) }
        reporter.add(folders: 1, files: 1, bytes: 50)
        now.withLock { $0 = .milliseconds(400) }
        reporter.add(folders: 1, files: 1, bytes: 50)
        now.withLock { $0 = .milliseconds(500) }
        reporter.add(folders: 1, files: 0, bytes: 0)
        #expect(reports.withLock { $0 } == [
            OccupancyProgress(folders: 3, files: 3, allocatedBytes: 150),
            OccupancyProgress(folders: 5, files: 4, allocatedBytes: 200),
        ])
    }
}

/// CPU-Budget der Leser (Spec § 4.4: Scan höchstens ein Kern im Mittel; die Leser bekommen 90 % davon, #530).
@Suite struct OccupancyCPUBudgetTests {
    @Test func pausesOnlyBeyondNinetyPercentOfOneCoreOnAverage() {
        let now = Mutex(Duration.zero)
        let budget = OccupancyCPUBudget(elapsed: { now.withLock { $0 } })
        now.withLock { $0 = .seconds(1) }
        // Zwei Leser mit 600 und 500 ms in 1 s: 1 100 ms CPU, erlaubt sind 900 ms plus 200 ms Spielraum.
        #expect(budget.charge(.milliseconds(600)) == .zero)
        #expect(budget.charge(.milliseconds(500)) == .zero)
        #expect(budget.charge(.milliseconds(50)) == .milliseconds(50))
        // Höchstens 100 ms Pause am Stück.
        #expect(budget.charge(.milliseconds(400)) == .milliseconds(100))
        now.withLock { $0 = .seconds(2) }
        #expect(budget.charge(.milliseconds(10)) == .zero)
    }
}
