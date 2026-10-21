import Darwin
import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct StorageTreeRemoverTests {
    /// Der Volumenwechsel wird an der echten fts-Metadaten-Grenze simuliert: kein Mount und keine Adminrechte nötig.
    /// Ohne Geräteprüfung würde die echte Löschung sowohl den Marker als auch den restlichen Cache entfernen.
    @Test func rejectsNestedMountBeforeRemovingAnyFiles() throws {
        try ScratchDirectory.withCanonical(prefix: "storage-tree") { scratch in
            let cache = scratch.appending(path: "cache")
            let mount = cache.appending(path: "nested/volume")
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            let marker = mount.appending(path: "keep")
            let sibling = cache.appending(path: "ordinary")
            try Data("volume data".utf8).write(to: marker)
            try Data("cache data".utf8).write(to: sibling)
            let mountInode = try #require(FileIdentity.of(mount.path)).inode
            let remover = StorageTreeRemover(deviceOf: { info in
                info.st_ino == mountInode ? ~info.st_dev : info.st_dev
            })
            #expect(throws: (any Error).self) {
                try remover.remove(cache.path, identity: try #require(FileIdentity.of(cache.path)))
            }
            #expect(try Data(contentsOf: marker) == Data("volume data".utf8))
            #expect(try Data(contentsOf: sibling) == Data("cache data".utf8))
        }
    }

    @Test func rejectsMountAppearingAfterPreflight() throws {
        try ScratchDirectory.withCanonical(prefix: "storage-tree") { scratch in
            let cache = scratch.appending(path: "cache")
            let mount = cache.appending(path: "volume")
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            let marker = mount.appending(path: "keep")
            try Data("keep".utf8).write(to: marker)
            let mountInode = try #require(FileIdentity.of(mount.path)).inode
            let visits = Mutex(0)
            let remover = StorageTreeRemover(deviceOf: { info in
                guard info.st_ino == mountInode else { return info.st_dev }
                let visit = visits.withLock { count in count += 1; return count }
                // Vorprüfung besucht den Ordner vor und nach seinen Kindern; erst danach kommt das Volume hinzu.
                return visit > 2 ? ~info.st_dev : info.st_dev
            })
            #expect(throws: (any Error).self) {
                try remover.remove(cache.path, identity: try #require(FileIdentity.of(cache.path)))
            }
            #expect(try Data(contentsOf: marker) == Data("keep".utf8))
        }
    }

    @Test func rejectsUnreadableSubtreeBeforeDeletingSiblings() throws {
        try ScratchDirectory.withCanonical(prefix: "storage-tree") { scratch in
            let cache = scratch.appending(path: "cache")
            let locked = cache.appending(path: "locked")
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            let sibling = cache.appending(path: "keep")
            try Data("keep".utf8).write(to: sibling)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
            #expect(throws: (any Error).self) {
                try StorageTreeRemover().remove(cache.path, identity: try #require(FileIdentity.of(cache.path)))
            }
            #expect(try Data(contentsOf: sibling) == Data("keep".utf8))
        }
    }

    @Test func removesRegularFile() throws {
        try ScratchDirectory.withCanonical(prefix: "storage-tree") { scratch in
            let file = scratch.appending(path: "cache.log")
            try Data("cache".utf8).write(to: file)
            try StorageTreeRemover().remove(file.path, identity: try #require(FileIdentity.of(file.path)))
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func removesTreeWithoutFollowingSymlinks() throws {
        try ScratchDirectory.withCanonical(prefix: "storage-tree") { scratch in
            let cache = scratch.appending(path: "cache")
            let nested = cache.appending(path: "nested/.hidden")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let outside = scratch.appending(path: "keep")
            try Data("outside".utf8).write(to: outside)
            try Data("cache".utf8).write(to: nested.appending(path: "file"))
            try FileManager.default.createSymbolicLink(at: cache.appending(path: "link"), withDestinationURL: scratch)
            try FileManager.default.createSymbolicLink(atPath: cache.appending(path: "dangling").path,
                                                      withDestinationPath: scratch.appending(path: "absent").path)
            try StorageTreeRemover().remove(cache.path, identity: try #require(FileIdentity.of(cache.path)))
            #expect(!FileManager.default.fileExists(atPath: cache.path))
            #expect(try Data(contentsOf: outside) == Data("outside".utf8))
        }
    }

    @Test func rejectsReplacedRoot() throws {
        try ScratchDirectory.withCanonical(prefix: "storage-tree") { scratch in
            let cache = scratch.appending(path: "cache")
            try Data("keep".utf8).write(to: cache)
            let identity = try #require(FileIdentity.of(cache.path))
            // Bewusst falscher Scan-Beleg, ohne von Inode-Wiederverwendung abhängig zu sein.
            let old = FileIdentity(device: identity.device, inode: identity.inode + 1, type: identity.type)
            #expect(throws: (any Error).self) { try StorageTreeRemover().remove(cache.path, identity: old) }
            #expect(try Data(contentsOf: cache) == Data("keep".utf8))
        }
    }
}
