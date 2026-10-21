import Foundation
import Testing
import TestSupport
@testable import ManagerKit

/// Der Zweig „Einhängepunkt“ ist über die eigenen Tests von `RemovalGuard.isMountPoint` abgedeckt (`RemovalGuardTests`).
@Suite struct StoragePathGuardTests {
    private func makeGuard(_ scratch: URL) -> StoragePathGuard {
        StoragePathGuard(layout: LibraryLayout(home: scratch.path, systemRoot: scratch.path))
    }

    private func directory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func allowsEntryBelowRoot() throws {
        try ScratchDirectory.withCanonical(prefix: "storage-guard") { scratch in
            let root = try directory(scratch.appending(path: "DerivedData"))
            let entry = try directory(root.appending(path: "App-abc"))
            let identity = FileIdentity.of(entry.path)
            #expect(makeGuard(scratch).check(entry.path, identity: identity, roots: [root.path]) == .allowed)
        }
    }

    @Test func allowsHiddenBuildFolder() throws {
        try ScratchDirectory.withCanonical(prefix: "storage-guard") { scratch in
            let root = try directory(scratch.appending(path: "Projects"))
            let entry = try directory(root.appending(path: "Tool/.build"))
            #expect(makeGuard(scratch).check(entry.path, identity: FileIdentity.of(entry.path), roots: [root.path]) == .allowed)
        }
    }

    @Test(arguments: ["", "Project", "Project/build"], [0o777, 0o775])
    func blocksForeignWritableRootAndParents(folder: String, mode: Int) throws {
        try ScratchDirectory.withCanonical(prefix: "storage-guard") { scratch in
            let root = try directory(scratch.appending(path: "Caches"))
            let entry = try directory(root.appending(path: "Project/build/.cache"))
            let parent = folder.isEmpty ? root : root.appending(path: folder)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: parent.path)
            #expect(makeGuard(scratch).check(entry.path, identity: FileIdentity.of(entry.path), roots: [root.path])
                    == .blocked("Ordner fremd beschreibbar"))
        }
    }

    @Test(arguments: ["", "Project", "Project/build"],
          ["group:everyone allow add_file,delete_child", "group:staff allow writesecurity"])
    func blocksForeignModificationACLOnRootAndParents(folder: String, acl: String) throws {
        try ScratchDirectory.withCanonical(prefix: "storage-guard") { scratch in
            let root = try directory(scratch.appending(path: "Caches"))
            let entry = try directory(root.appending(path: "Project/build/.cache"))
            let parent = folder.isEmpty ? root : root.appending(path: folder)
            try AccessControlFixture.grant(acl, to: parent.path)
            #expect(makeGuard(scratch).check(entry.path, identity: FileIdentity.of(entry.path), roots: [root.path])
                    == .blocked("Ordner fremd beschreibbar"))
        }
    }

    @Test(arguments: ["group:everyone allow read,readattr", "group:everyone deny delete"])
    func allowsNonModifyingACL(acl: String) throws {
        try ScratchDirectory.withCanonical(prefix: "storage-guard") { scratch in
            let root = try directory(scratch.appending(path: "Caches"))
            let entry = try directory(root.appending(path: "App/cache"))
            try AccessControlFixture.grant(acl, to: root.path)
            #expect(makeGuard(scratch).check(entry.path, identity: FileIdentity.of(entry.path), roots: [root.path]) == .allowed)
        }
    }

    @Test func onlyChecksPermissionsStartingAtAllowedRoot() throws {
        try ScratchDirectory.withCanonical(prefix: "storage-guard") { scratch in
            let root = try directory(scratch.appending(path: "Caches"))
            let entry = try directory(root.appending(path: "App"))
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: scratch.path)
            #expect(makeGuard(scratch).check(entry.path, identity: FileIdentity.of(entry.path), roots: [root.path]) == .allowed)
        }
    }

    @Test func blocksRootItselfAndOutsidePaths() throws {
        try ScratchDirectory.withCanonical(prefix: "storage-guard") { scratch in
            let root = try directory(scratch.appending(path: "DerivedData"))
            let outside = try directory(scratch.appending(path: "Other/x"))
            let check = makeGuard(scratch)
            #expect(check.check(root.path, identity: FileIdentity.of(root.path), roots: [root.path])
                    == .blocked("Außerhalb der erlaubten Orte"))
            #expect(check.check(outside.path, identity: FileIdentity.of(outside.path), roots: [root.path])
                    == .blocked("Außerhalb der erlaubten Orte"))
        }
    }

    @Test func blocksSymlinkEntryAndSymlinkInPath() throws {
        try ScratchDirectory.withCanonical(prefix: "storage-guard") { scratch in
            let root = try directory(scratch.appending(path: "Caches"))
            let target = try directory(scratch.appending(path: "Target/inner"))
            let link = root.appending(path: "link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target.deletingLastPathComponent())
            let check = makeGuard(scratch)
            #expect(check.check(link.path, identity: FileIdentity.of(link.path), roots: [root.path])
                    == .blocked("Symbolischer Link"))
            let through = link.appending(path: "inner").path
            #expect(check.check(through, identity: FileIdentity.of(through), roots: [root.path])
                    == .blocked("Symbolischer Link im Pfad"))
        }
    }

    @Test func blocksReplacedEntry() throws {
        try ScratchDirectory.withCanonical(prefix: "storage-guard") { scratch in
            let root = try directory(scratch.appending(path: "Logs"))
            let entry = try directory(root.appending(path: "App"))
            let identity = FileIdentity.of(entry.path)
            try FileManager.default.removeItem(at: entry)
            _ = try directory(entry)
            #expect(makeGuard(scratch).check(entry.path, identity: identity, roots: [root.path])
                    == .blocked("Geändert seit Scan"))
        }
    }

    @Test func blocksMissingScanIdentity() throws {
        try ScratchDirectory.withCanonical(prefix: "storage-guard") { scratch in
            let root = try directory(scratch.appending(path: "Logs"))
            let entry = try directory(root.appending(path: "App"))
            #expect(makeGuard(scratch).check(entry.path, identity: nil, roots: [root.path]) == .blocked("Kein Scan-Beleg"))
        }
    }

    /// Wurzel in anderer Schreibweise als auf der Platte (`Code` gegen `code`) ist kein Symlink im Pfad.
    @Test func allowsRootSpelledInDifferentCase() throws {
        try ScratchDirectory.withCanonical(prefix: "storage-guard") { scratch in
            _ = try directory(scratch.appending(path: "code/App/.build"))
            let root = scratch.appending(path: "Code")
            // Nur auf Volumes ohne Groß-/Kleinschreibung sinnvoll.
            guard FileManager.default.fileExists(atPath: root.path) else { return }
            let entry = root.appending(path: "App/.build").path
            #expect(makeGuard(scratch).check(entry, identity: FileIdentity.of(entry), roots: [root.path]) == .allowed)
        }
    }

    /// #229: Eine Wurzel unterhalb eines Sperrorts (`/private/tmp/claude-<uid>` unter `/private`) gibt nur ihre eigenen
    /// Einträge frei; der Sperrort selbst und alles daneben bleiben gesperrt.
    @Test func rootBelowBlockedPlaceAllowsOnlyItsEntries() throws {
        try ScratchDirectory.withCanonical(prefix: "storage-guard") { scratch in
            let root = try directory(scratch.appending(path: "private/tmp/claude-501"))
            let entry = try directory(root.appending(path: "-Users-x/session"))
            let beside = try directory(scratch.appending(path: "private/tmp/other"))
            let check = makeGuard(scratch)
            #expect(check.check(entry.path, identity: FileIdentity.of(entry.path), roots: [root.path]) == .allowed)
            #expect(check.check(beside.path, identity: FileIdentity.of(beside.path), roots: [root.path])
                    == .blocked("Geschützter Ort"))
            let privateRoot = scratch.appending(path: "private").path
            #expect(check.check(root.path, identity: FileIdentity.of(root.path), roots: [privateRoot])
                    == .blocked("Geschützter Ort"))
        }
    }

    /// Sperrorte (`LibraryLayout.blockedPaths`, hier `~/Library/Mail`) bleiben gesperrt, auch unter einer erlaubten Wurzel.
    @Test func blocksBlockedPlacesBelowRoot() throws {
        try ScratchDirectory.withCanonical(prefix: "storage-guard") { scratch in
            let mail = scratch.appending(path: "Library/Mail")
            let entry = try directory(mail.appending(path: "x"))
            let check = makeGuard(scratch)
            #expect(check.check(entry.path, identity: FileIdentity.of(entry.path), roots: [scratch.path])
                    == .blocked("Geschützter Ort"))
            #expect(check.check(mail.path, identity: FileIdentity.of(mail.path), roots: [scratch.path])
                    == .blocked("Geschützter Ort"))
        }
    }
}
