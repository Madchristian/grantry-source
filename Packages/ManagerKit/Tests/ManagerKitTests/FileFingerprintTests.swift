import Foundation
import Testing
import TestSupport
@testable import ManagerKit

/// Review N6: Ein zurückgesetztes Änderungsdatum (`touch -r`) verbirgt einen Austausch nicht – der Fingerabdruck
/// enthält auch die Statusänderungszeit (ctime) und die Größe.
@Suite struct FileFingerprintTests {
    private static let oldDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// Schreibt `data` nach `url` und setzt das Änderungsdatum auf `oldDate` (wie `touch -r`).
    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Self.oldDate], ofItemAtPath: url.path)
    }

    /// Wartet, bis die ctime sicher weitergelaufen ist (Auflösung Nanosekunden, aber sicherheitshalber).
    private func tick() {
        Thread.sleep(forTimeInterval: 0.02)
    }

    @Test func resetModificationDateStillChangesTheFingerprint() throws {
        try ScratchDirectory.with(prefix: "fingerprint") { directory in
            let file = directory.appending(path: "tool")
            try write(Data([1, 2, 3]), to: file)
            let before = try #require(FileFingerprint(of: file.path))
            tick()
            // Gleiche Größe, gleiches Änderungsdatum, gleiche Inode – nur der Inhalt (und damit die ctime) ist neu.
            let handle = try FileHandle(forWritingTo: file)
            try handle.write(contentsOf: Data([9, 9, 9]))
            try handle.close()
            try FileManager.default.setAttributes([.modificationDate: Self.oldDate], ofItemAtPath: file.path)
            let after = try #require(FileFingerprint(of: file.path))
            #expect(after.modified == before.modified && after.fileNumber == before.fileNumber)
            #expect(after != before)
            #expect(!after.matches(before))
        }
    }

    @Test func sizeIsPartOfTheFingerprint() throws {
        try ScratchDirectory.with(prefix: "fingerprint") { directory in
            let file = directory.appending(path: "tool")
            try write(Data([1]), to: file)
            let before = try #require(FileFingerprint(of: file.path))
            #expect(before.size == 1)
            tick()
            try write(Data([1, 2]), to: file)
            #expect(FileFingerprint(of: file.path)?.size == 2)
            #expect(FileFingerprint(of: file.path) != before)
        }
    }

    @Test func bundleSealWithResetDateStillChangesTheFingerprint() throws {
        try ScratchDirectory.with(prefix: "fingerprint") { directory in
            let bundle = directory.appending(path: "Tool.app")
            let seal = bundle.appending(path: "Contents/_CodeSignature/CodeResources")
            try FileManager.default.createDirectory(at: seal.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(Data("alt".utf8), to: seal)
            let before = try #require(FileFingerprint(of: bundle.path))
            tick()
            try write(Data("neu".utf8), to: seal)
            let after = try #require(FileFingerprint(of: bundle.path))
            #expect(after.modified == before.modified)
            #expect(after != before)
        }
    }

    @Test func unchangedFileKeepsItsFingerprint() throws {
        try ScratchDirectory.with(prefix: "fingerprint") { directory in
            let file = directory.appending(path: "tool")
            try write(Data([1]), to: file)
            #expect(FileFingerprint(of: file.path) == FileFingerprint(of: file.path))
        }
    }

    /// Ältere Snapshots kennen ctime und Größe nicht: Sie zählen dann nicht, sonst gälte nach dem Update jedes
    /// Hauptprogramm einmal als ausgetauscht.
    @Test func storedFingerprintsWithoutNewFieldsStillMatch() throws {
        let legacy = try JSONDecoder().decode(FileFingerprint.self, from: Data(#"{"modified":0,"fileNumber":7}"#.utf8))
        #expect(legacy.statusChanged == nil && legacy.size == nil)
        let current = FileFingerprint(modified: legacy.modified, fileNumber: 7, statusChanged: Self.oldDate, size: 12)
        #expect(current.matches(legacy) && legacy.matches(current))
        let replaced = FileFingerprint(modified: legacy.modified, fileNumber: 8, statusChanged: Self.oldDate, size: 12)
        #expect(!replaced.matches(legacy))
    }
}
