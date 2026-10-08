import Darwin
import Foundation
import Testing
import TestSupport
@testable import GrantryShared

@Suite struct BoundDirectoryTests {
    /// Pfade ohne Symlink (`/var` → `/private/var`), damit das komponentenweise Öffnen nicht daran scheitert.
    private func withCanonicalScratch(_ body: (String) throws -> Void) throws {
        try ScratchDirectory.withCanonical(prefix: "bound") { try body($0.path) }
    }

    @Test func opensTheDirectoryObjectAndReportsEachComponent() throws {
        try withCanonicalScratch { root in
            try FileManager.default.createDirectory(atPath: root + "/a/b", withIntermediateDirectories: true)
            var visited: [String] = []
            let bound = try BoundDirectory(path: root + "/a//b/") { _, path in visited.append(path) }
            #expect(bound.path == root + "/a/b")
            #expect(visited.first == "/" && visited.last == root + "/a/b")
            var info = stat()
            try #require(fstat(bound.descriptor, &info) == 0)
            #expect((info.st_mode & S_IFMT) == S_IFDIR)
        }
    }

    @Test func refusesRelativePathsAndDotComponents() {
        for path in ["relativ", "", "./a", "/a/./b", "/a/../b", "/..", "/a/b/.."] {
            #expect(throws: POSIXError(.EINVAL), "\(path)") { try BoundDirectory(path: path) }
        }
    }

    @Test func refusesSymlinksAndMissingComponents() throws {
        try withCanonicalScratch { root in
            try FileManager.default.createDirectory(atPath: root + "/real", withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: root + "/real")
            #expect(throws: POSIXError(.ELOOP)) { try BoundDirectory(path: root + "/link") }
            #expect(throws: POSIXError(.ENOENT)) { try BoundDirectory(path: root + "/fehlt") }
            try Data().write(to: URL(filePath: root + "/datei"))
            #expect(throws: POSIXError(.ENOTDIR)) { try BoundDirectory(path: root + "/datei") }
        }
    }

    @Test func createsMissingComponentsWithTheGivenModeAndInspectsThem() throws {
        try withCanonicalScratch { root in
            var visited: [String] = []
            let bound = try BoundDirectory(path: root + "/neu/tiefer", creatingMissingWith: 0o700) { _, path in
                visited.append(path)
            }
            #expect(bound.path == root + "/neu/tiefer")
            #expect(visited.suffix(2) == [root + "/neu", root + "/neu/tiefer"])
            var info = stat()
            try #require(fstat(bound.descriptor, &info) == 0)
            #expect((info.st_mode & S_IFMT) == S_IFDIR && (info.st_mode & 0o077) == 0)
        }
    }

    @Test func creatingMissingComponentsStillRefusesSymlinks() throws {
        try withCanonicalScratch { root in
            try FileManager.default.createDirectory(atPath: root + "/real", withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: root + "/real")
            #expect(throws: POSIXError(.ELOOP)) { try BoundDirectory(path: root + "/link/neu", creatingMissingWith: 0o700) }
            #expect(!FileManager.default.fileExists(atPath: root + "/real/neu"))
            try FileManager.default.createSymbolicLink(atPath: root + "/leer", withDestinationPath: root + "/fehlt")
            #expect(throws: POSIXError(.ELOOP)) { try BoundDirectory(path: root + "/leer", creatingMissingWith: 0o700) }
            #expect(!FileManager.default.fileExists(atPath: root + "/fehlt"))
        }
    }
}
