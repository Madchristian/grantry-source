import Darwin
import Foundation
import Testing
import TestSupport
@testable import ManagerKit

/// Der Belegungsscanner auf dem echten Dateisystem (temporäre Ordner): gleiche Größenregeln wie `FileSizeCalculator`,
/// keine Symlinks, Hardlinks einmal, gesperrte Ordner, FIFOs, deskriptorgebundene Prüfung.
@Suite struct LocalOccupancyFileSystemTests {
    private static let farFuture = ContinuousClock.now.advanced(by: .seconds(3_600))

    private func scan(_ directory: URL) async throws -> OccupancyTree {
        try await OccupancyScanner().scan(directory.path)
    }

    /// Dieselbe Summe wie `FileSizeCalculator` (DRY): allozierte Blöcke, Hardlinks einmal, Symlinks nicht.
    @Test func matchesFileSizeCalculator() async throws {
        try await ScratchDirectory.withCanonical(prefix: "occupancy") { directory in
            let tree = directory.appending(path: "tree")
            try FileManager.default.createDirectory(at: tree.appending(path: "a/b"), withIntermediateDirectories: true)
            try Data(count: 100_000).write(to: tree.appending(path: "a/one"))
            try Data(count: 5_000).write(to: tree.appending(path: "a/b/two"))
            try Data(count: 300_000).write(to: tree.appending(path: "shared"))
            #expect(link(tree.appending(path: "shared").path, tree.appending(path: "a/b/shared-link").path) == 0)
            try Data(count: 5_000_000).write(to: directory.appending(path: "outside"))
            try FileManager.default.createSymbolicLink(at: tree.appending(path: "a/link"),
                                                       withDestinationURL: directory.appending(path: "outside"))
            try FileManager.default.createSymbolicLink(at: tree.appending(path: "folder-link"), withDestinationURL: directory)

            let result = try await scan(tree)

            let expected = try #require(FileSizeCalculator.measurement(of: tree.path, deadline: Self.farFuture) { false }.bytes)
            #expect(result.root.allocatedBytes == expected)
            #expect(result.root.allocatedBytes < 5_000_000)
            #expect(result.root.fileCount == 4)
            #expect(result.root.isComplete)
            #expect(result.subfolders(of: result.root).map(\.name) == ["a"])
            let b = try #require(result.folder(atPath: tree.path + "/a/b"))
            #expect(b.largestFiles.map(\.name).sorted() == ["shared-link", "two"])
        }
    }

    @Test func lockedFolderIsUncapturedAndSiblingsCount() async throws {
        try await ScratchDirectory.withCanonical(prefix: "occupancy") { directory in
            let locked = directory.appending(path: "locked")
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            try Data(count: 1_000_000).write(to: locked.appending(path: "secret"))
            try Data(count: 8_192).write(to: directory.appending(path: "open"))
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

            let result = try await scan(directory)

            #expect(result.folder(atPath: locked.path)?.state == .uncaptured(.permissionDenied))
            #expect(result.root.uncapturedCount == 1)
            #expect((8_192..<1_000_000).contains(result.root.allocatedBytes))
        }
    }

    /// Der Scan öffnet keine Dateien: Eine FIFO im Baum blockiert nicht.
    @Test func fifoDoesNotBlock() async throws {
        try await ScratchDirectory.withCanonical(prefix: "occupancy") { directory in
            let fifo = try FIFOFixture.make(in: directory)
            let path = directory.path
            let completed = await FIFOFixture.completes(unblocking: fifo) {
                (try? await OccupancyScanner().scan(path)) != nil
            }
            #expect(completed == true)
        }
    }

    /// Eine Wurzel hinter einem Symlink (`/var` → `/private/var`) wird kanonisch aufgelöst.
    @Test func rootIsResolvedToItsCanonicalPath() async throws {
        try await ScratchDirectory.with(prefix: "occupancy") { directory in
            try Data(count: 4_096).write(to: directory.appending(path: "a"))
            let canonical = try #require(realpath(directory.path, nil).map { pointer in
                defer { free(pointer) }
                return String(cString: pointer)
            })

            let result = try await scan(directory)

            #expect(result.rootPath == canonical)
            #expect(result.root.fileCount == 1)
        }
    }

    @Test func missingRootIsUnavailable() async {
        await #expect(throws: OccupancyScanError.unavailable) {
            try await OccupancyScanner().scan("/nonexistent-\(UUID().uuidString)")
        }
    }

    @Test func fileAsRootIsUnavailable() async throws {
        try await ScratchDirectory.withCanonical(prefix: "occupancy") { directory in
            let file = directory.appending(path: "file")
            try Data(count: 1).write(to: file)
            await #expect(throws: OccupancyScanError.unavailable) { try await OccupancyScanner().scan(file.path) }
        }
    }

    /// Ein Ordner, der nach dem Lesen seines Elternordners ersetzt wurde, gilt als geändert.
    @Test func replacedFolderIsDetected() throws {
        try ScratchDirectory.withCanonical(prefix: "occupancy") { directory in
            let folder = directory.appending(path: "folder")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let fileSystem = LocalOccupancyFileSystem()
            let root = try fileSystem.root(at: directory.path)
            let stale = FileIdentity(device: root.identity.device, inode: 1, type: .directory)
            let outcome = fileSystem.readDirectory(at: folder.path, expected: stale, in: root, isCancelled: { false }) { _ in }
            #expect(outcome == .uncaptured(.changed))
        }
    }

    /// Ein Symlink irgendwo im Pfad wird nie verfolgt (`O_NOFOLLOW_ANY`).
    @Test func symlinkInThePathIsNotFollowed() throws {
        try ScratchDirectory.withCanonical(prefix: "occupancy") { directory in
            let real = directory.appending(path: "real/inner")
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: directory.appending(path: "alias"),
                                                       withDestinationURL: directory.appending(path: "real"))
            let fileSystem = LocalOccupancyFileSystem()
            let root = try fileSystem.root(at: directory.path)
            let identity = try #require(FileIdentity.of(real.path))
            let outcome = fileSystem.readDirectory(at: directory.path + "/alias/inner", expected: identity, in: root,
                                                   isCancelled: { false }) { _ in }
            #expect(outcome == .uncaptured(.changed))
        }
    }

    @Test func vanishedFolderIsReported() throws {
        try ScratchDirectory.withCanonical(prefix: "occupancy") { directory in
            let fileSystem = LocalOccupancyFileSystem()
            let root = try fileSystem.root(at: directory.path)
            let outcome = fileSystem.readDirectory(at: directory.path + "/gone", expected: root.identity, in: root,
                                                   isCancelled: { false }) { _ in }
            #expect(outcome == .vanished)
        }
    }

    /// Einhängepunkte unter der Wurzel erkennt das Dateisystem an der Mount-Tabelle, ohne sie anzufassen.
    @Test func mountPointsFromTheMountTableAreNotTouched() throws {
        try ScratchDirectory.withCanonical(prefix: "occupancy") { directory in
            try FileManager.default.createDirectory(at: directory.appending(path: "share"), withIntermediateDirectories: true)
            let volumes = [MountedVolume(path: "/", isLocal: true),
                           MountedVolume(path: directory.path + "/share", isLocal: false)]
            let fileSystem = LocalOccupancyFileSystem(volumes: { volumes })
            let root = try fileSystem.root(at: directory.path)
            #expect(root.mountPoints == [directory.path + "/share": false])
            var entries: [OccupancyEntry] = []
            let outcome = fileSystem.readDirectory(at: directory.path, expected: root.identity, in: root,
                                                   isCancelled: { false }) { entries.append($0) }
            #expect(outcome == .read(isComplete: true))
            #expect(entries == [.mountPoint(name: "share", isLocal: false)])
        }
    }

    /// Wurzel in der Schreibweise des Datenvolumes (ganzer Datenträger): Die Mount-Tabelle nennt Einhängepunkte darunter
    /// ohne das Präfix `/System/Volumes/Data`.
    @Test func mountPointsAreFoundBelowTheDataVolumeSpelling() throws {
        try ScratchDirectory.withCanonical(prefix: "occupancy") { directory in
            try FileManager.default.createDirectory(at: directory.appending(path: "share"), withIntermediateDirectories: true)
            let root = MountedVolume.dataVolumePrefix + directory.path
            let volumes = [MountedVolume(path: "/", isLocal: true), MountedVolume(path: MountedVolume.dataVolumePrefix, isLocal: true),
                           MountedVolume(path: directory.path + "/share", isLocal: false)]
            let fileSystem = LocalOccupancyFileSystem(volumes: { volumes })
            let resolved = try fileSystem.root(at: root)
            #expect(resolved.path == root)
            #expect(resolved.mountPoints == [root + "/share": false])
        }
    }

    @Test func rootOnANetworkVolumeIsRejected() throws {
        try ScratchDirectory.withCanonical(prefix: "occupancy") { directory in
            let volumes = [MountedVolume(path: "/", isLocal: true), MountedVolume(path: directory.path, isLocal: false)]
            let fileSystem = LocalOccupancyFileSystem(volumes: { volumes })
            #expect(throws: OccupancyScanError.networkVolume) { try fileSystem.root(at: directory.path) }
        }
    }
}
