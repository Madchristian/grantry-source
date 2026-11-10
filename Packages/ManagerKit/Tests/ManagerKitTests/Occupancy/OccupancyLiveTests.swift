import Darwin
import Foundation
import Testing
import TestSupport
@testable import ManagerKit

/// Opt-in gegen das echte System (`MANAGERKIT_LIVE=1`), rein lesend: FSEvents-Änderungsprotokoll und Abnahmekriterium 3
/// von #401 – Scan des eigenen Benutzerordners mit Dauer, CPU und Spitzen-Speicher. Für belastbare Werte allein laufen
/// lassen: `MANAGERKIT_LIVE=1 swift test -c release --filter OccupancyLiveTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MANAGERKIT_LIVE"] == "1"), .serialized)
struct OccupancyLiveTests {
    /// CPU-Zeit des Prozesses (Benutzer und System) und Spitzen-Speicher (`ru_maxrss`, Byte).
    private static func usage() -> (cpu: Duration, peakMemory: Int) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func duration(_ time: timeval) -> Duration { .seconds(time.tv_sec) + .microseconds(time.tv_usec) }
        return (duration(usage.ru_utime) + duration(usage.ru_stime), Int(usage.ru_maxrss))
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Ohne Festplattenvollzugriff würde das Lesen dieser Orte eine Rückfrage von macOS auf den Bildschirm bringen; der
    /// Test lässt sie dann aus (sie zählen als nicht erfassbar).
    private static func promptingFolders(in home: String) -> Set<String> {
        let probe = home + "/Library/Application Support/com.apple.TCC/TCC.db"
        let descriptor = open(probe, O_RDONLY | O_NONBLOCK)
        if descriptor >= 0 {
            close(descriptor)
            return []
        }
        return OccupancyProtectedPlaces.folders(inHome: home)
    }

    @Test func scansTheHomeFolder() async throws {
        let excluded = Self.promptingFolders(in: NSHomeDirectory())
        print("Belegung live: ohne Festplattenvollzugriff ausgelassen: \(excluded.sorted())")
        let scanner = OccupancyScanner(excluding: excluded)
        let before = Self.usage()
        let start = ContinuousClock.now
        let tree = try await scanner.scan(NSHomeDirectory())
        let elapsed = ContinuousClock.now - start
        let after = Self.usage()
        let cpu = after.cpu - before.cpu
        print("""
            Belegung live: Benutzerordner \(tree.root.fileCount) Dateien, \(tree.folderCount) Ordner, \
            \(tree.root.allocatedBytes / 1_000_000) MB belegt, \(tree.root.uncapturedCount) nicht erfassbar
            Belegung live: Dauer \(elapsed), CPU \(cpu) (\(Int(Self.seconds(cpu) / Self.seconds(elapsed) * 100)) % eines Kerns), \
            Spitzen-Speicher \(after.peakMemory / 1_000_000) MB (vorher \(before.peakMemory / 1_000_000) MB), \
            Ergebnis geschätzt \(tree.estimatedMemory / 1_000_000) MB
            """)

        let rescanStart = ContinuousClock.now
        let rescanUsage = Self.usage()
        let rescan = try await scanner.scan(NSHomeDirectory(), reusing: tree)
        let rescanElapsed = ContinuousClock.now - rescanStart
        print("""
            Belegung live: erneuter Scan \(rescanElapsed), CPU \(Self.usage().cpu - rescanUsage.cpu), \
            \(rescan.root.fileCount) Dateien
            """)
        #expect(tree.root.fileCount > 0)
    }

    /// FSEvents meldet den Ordner einer gewachsenen Datei, obwohl sich dessen Änderungsdatum nicht ändert.
    @Test func journalReportsAppendedFiles() async throws {
        try await ScratchDirectory.withCanonical(prefix: "occupancy-live") { directory in
            let folder = directory.appending(path: "a/b")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: "file")
            try Data(count: 100).write(to: file)
            let journal = FSEventsOccupancyJournal()
            let identity = try #require(FileIdentity.of(directory.path))
            let mark = try #require(journal.mark(forDevice: identity.device))

            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(count: 100_000))
            try handle.close()

            let changes = try #require(await journal.changes(since: mark, under: directory.path, device: identity.device))
            #expect(changes.folders.contains(folder.path))
            #expect(!changes.folders.contains(directory.path + "/elsewhere"))
        }
    }
}

/// Ohne Wartezeit prüfbar: Das Protokoll gilt nur für dasselbe Volume und denselben Ereignisstrom.
@Suite struct FSEventsOccupancyJournalTests {
    @Test func refusesAMarkOfAnotherEventStream() async throws {
        let journal = FSEventsOccupancyJournal()
        let identity = try #require(FileIdentity.of(NSTemporaryDirectory()))
        let mark = OccupancyChangeMark(journal: "00000000-0000-0000-0000-000000000000", eventID: 1)
        #expect(await journal.changes(since: mark, under: NSTemporaryDirectory(), device: identity.device) == nil)
    }

    @Test func marksTheCurrentEventOfTheVolume() throws {
        let journal = FSEventsOccupancyJournal()
        let identity = try #require(FileIdentity.of(NSTemporaryDirectory()))
        let first = try #require(journal.mark(forDevice: identity.device))
        let second = try #require(journal.mark(forDevice: identity.device))
        #expect(first.journal == second.journal)
        #expect(first.eventID <= second.eventID)
    }
}
