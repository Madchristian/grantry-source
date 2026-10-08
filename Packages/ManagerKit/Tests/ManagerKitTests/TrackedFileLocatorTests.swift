import Foundation
import Testing
import TestSupport
@testable import ManagerKit

// Nur ein Scratch-„.Trash“ – kein echter Papierkorb.

/// Ohne Deskriptor nicht ermittelbar – wie `FSGetPathLocator`, wenn TCC den Papierkorb verweigert.
private struct DeniedLocation: FileLocating {
    func locate(_ identity: FileIdentity) -> FileLocation { .unknown }
}

private func candidate(_ url: URL, kind: LeftoverKind = .caches) -> LeftoverCandidate {
    LeftoverCandidate(path: url.path, kind: kind, confidence: .safe, identity: FileIdentity.of(url.path))
}

private func makeTrash(in directory: URL) throws -> URL {
    let trash = directory.appending(path: ".Trash")
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    return trash
}

@Suite("Originale über offene Deskriptoren wiederfinden (F_GETPATH)")
struct TrackedFileLocatorTests {
    /// Datei und Bundle-Ordner folgen dem Inode in den Papierkorb – unabhängig von der pfadbasierten Auflösung.
    @Test(arguments: [false, true])
    func followsTheOriginalIntoTheTrash(isDirectory: Bool) throws {
        try ScratchDirectory.with(prefix: "tracked") { directory in
            let trash = try makeTrash(in: directory)
            let url = directory.appending(path: isDirectory ? "Grantry.app" : "Grantry.plist")
            if isDirectory {
                try FileManager.default.createDirectory(at: url.appending(path: "Contents"), withIntermediateDirectories: true)
            } else {
                try Data([1]).write(to: url)
            }
            let original = candidate(url)
            let locator = TrackedFileLocator(fallback: DeniedLocation())
            locator.track([original])

            let moved = trash.appending(path: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: moved)
            // Ein Ersatzobjekt am alten Pfad ändert nichts am Ort des Originals.
            try Data([2]).write(to: url)

            guard case .found(let path, let hasOtherNames) = locator.locate(try #require(original.identity)) else {
                Issue.record("nicht gefunden")
                return
            }
            #expect(FinderTrash.isInTrashFolder(path))
            #expect((path as NSString).lastPathComponent == url.lastPathComponent)
            #expect(!hasOtherNames)
        }
    }

    @Test func deletedOriginalIsGone() throws {
        try ScratchDirectory.with(prefix: "tracked") { directory in
            let url = directory.appending(path: "file")
            try Data([1]).write(to: url)
            let original = candidate(url)
            let locator = TrackedFileLocator(fallback: DeniedLocation())
            locator.track([original])
            try FileManager.default.removeItem(at: url)
            #expect(locator.locate(try #require(original.identity)) == .gone)
        }
    }

    @Test func hardLinkedOriginalHasOtherNames() throws {
        try ScratchDirectory.with(prefix: "tracked") { directory in
            let trash = try makeTrash(in: directory)
            let url = directory.appending(path: "file")
            try Data([1]).write(to: url)
            let original = candidate(url)
            let locator = TrackedFileLocator(fallback: DeniedLocation())
            locator.track([original])
            try FileManager.default.linkItem(at: url, to: directory.appending(path: "second"))
            try FileManager.default.moveItem(at: url, to: trash.appending(path: "file"))
            guard case .found(_, let hasOtherNames) = locator.locate(try #require(original.identity)) else {
                Issue.record("nicht gefunden")
                return
            }
            #expect(hasOtherNames)
        }
    }

    /// Eine FIFO ohne Schreiber als Kandidat hält `track` nicht fest – sie wird nie geöffnet, es gilt der bisherige Weg.
    @Test(.timeLimit(.minutes(2))) func fifoCandidateIsNotOpened() async throws {
        try await ScratchDirectory.with(prefix: "tracked") { directory in
            let fifo = try FIFOFixture.make(in: directory)
            let original = candidate(fifo)
            let locator = TrackedFileLocator(fallback: DeniedLocation())
            let done = await FIFOFixture.completes(unblocking: fifo) { locator.track([original]); return true }
            #expect(done == true)
            #expect(locator.locate(try #require(original.identity)) == .unknown)
        }
    }

    /// Nach der Bestätigung wird der Originalpfad durch eine FIFO ersetzt: `track` blockiert nicht und hält das fremde
    /// Objekt nicht fest.
    @Test(.timeLimit(.minutes(2))) func originalReplacedByFIFOIsNotOpened() async throws {
        try await ScratchDirectory.with(prefix: "tracked") { directory in
            let url = directory.appending(path: "Grantry.plist")
            try Data([1]).write(to: url)
            let original = candidate(url)
            try FileManager.default.removeItem(at: url)
            let fifo = try FIFOFixture.make(in: directory, named: "Grantry.plist")
            let locator = TrackedFileLocator(fallback: DeniedLocation())
            let done = await FIFOFixture.completes(unblocking: fifo) { locator.track([original]); return true }
            #expect(done == true)
            #expect(locator.locate(try #require(original.identity)) == .unknown)
        }
    }

    @Test func onlyRegularFilesAndDirectoriesAreTrackable() {
        #expect(TrackedFileLocator.isTrackable(.regularFile))
        #expect(TrackedFileLocator.isTrackable(.directory))
        #expect(!TrackedFileLocator.isTrackable(.symbolicLink))
        #expect(!TrackedFileLocator.isTrackable(.other))
    }

    /// Kein Deskriptor – Ersatzobjekt am Pfad, Symlink, nicht verfolgt oder freigegeben – heißt: bisheriger Weg.
    @Test func withoutDescriptorTheFallbackDecides() throws {
        try ScratchDirectory.with(prefix: "tracked") { directory in
            let url = directory.appending(path: "file"), link = directory.appending(path: "link")
            try Data([1]).write(to: url)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            let original = candidate(url), symlink = candidate(link)
            let replaced = LeftoverCandidate(
                path: url.path, kind: .caches, confidence: .safe, identity: FileIdentity(device: 1, inode: 1, type: .regularFile)
            )
            let locator = TrackedFileLocator(fallback: DeniedLocation())
            locator.track([replaced, symlink])
            #expect(locator.locate(try #require(replaced.identity)) == .unknown)
            #expect(locator.locate(try #require(symlink.identity)) == .unknown)

            locator.track([original])
            #expect(locator.locate(try #require(original.identity)) != .unknown)
            locator.release()
            #expect(locator.locate(try #require(original.identity)) == .unknown)
        }
    }
}
