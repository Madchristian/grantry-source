import Darwin
import Foundation
import Testing
import TestSupport
@testable import ManagerKit

/// Regressionstests (Audit 2026-10-09, Befund A3): Neben Identität und Symlinks muss `RemovalGuard` prüfen,
/// wer die Zwischenordner beschreiben darf. Ein anderer Benutzer mit Schreibrecht auf `/Applications/Vendor`
/// legt dort `Sub/Köder.app` ab; während der Finder beim Opfer nach dem Admin-Passwort fragt (Sekunden bis Minuten),
/// tauscht er `Sub` gegen einen Symlink auf `/Applications` – der Finder löst den Pfad erst danach auf und legt die
/// echte App mit Adminrecht in den Papierkorb. Der Tausch braucht nur Schreibrecht auf den Großelternordner.
@Suite struct PenetrationRemovalGuardTests {
    /// Ein `.app` unter einem für andere beschreibbaren Ordner ist kein sicheres Ziel.
    @Test func appBundleBelowAWorldWritableFolderIsNotAllowed() async throws {
        try await LibraryFixture.with { fixture in
            let app = try fixture.app("Decoy", bundleID: "com.example.decoy", subfolder: "Vendor/Sub")
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: fixture.system("Applications/Vendor"))
            let check = RemovalGuard(layout: fixture.layout)
            #expect(check.check(app) == .blocked("Ordner fremd beschreibbar"))
        }
    }

    @Test(arguments: ["Applications", "Applications/Vendor/Sub"])
    func worldWritableAppRootOrParentIsBlocked(directory: String) async throws {
        try await LibraryFixture.with { fixture in
            let app = try fixture.app("Decoy", bundleID: "com.example.decoy", subfolder: "Vendor/Sub")
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: fixture.system(directory))
            #expect(RemovalGuard(layout: fixture.layout).check(app) == .blocked("Ordner fremd beschreibbar"))
        }
    }

    @Test(arguments: ["group:everyone allow add_file,delete_child", "group:staff allow writesecurity"])
    func appBundleBelowAFolderWithForeignModificationACLIsBlocked(acl: String) async throws {
        try await LibraryFixture.with { fixture in
            let app = try fixture.app("Decoy", bundleID: "com.example.decoy", subfolder: "Vendor/Sub")
            try AccessControlFixture.grant(acl, to: fixture.system("Applications/Vendor"))
            #expect(RemovalGuard(layout: fixture.layout).check(app) == .blocked("Ordner fremd beschreibbar"))
        }
    }

    @Test(arguments: [false, true])
    func untrustedLeftoverLocationIsBlocked(usingACL: Bool) async throws {
        try await LibraryFixture.with { fixture in
            let directories = [fixture.system("Library/Application Support"), fixture.userLibrary("Caches"),
                               fixture.userLibrary("Preferences/ByHost")]
            for directory in directories {
                let item = try fixture.file(directory + "/com.example.tool")
                #expect(RemovalGuard(layout: fixture.layout).check(item) == .allowed)
                if usingACL {
                    try AccessControlFixture.grant("group:everyone allow add_file,delete_child", to: directory)
                } else {
                    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory)
                }
                #expect(RemovalGuard(layout: fixture.layout).check(item) == .blocked("Ordner fremd beschreibbar"))
            }
        }
    }

    @Test(arguments: ["group:everyone allow read,readattr", "group:everyone deny delete"])
    func nonModifyingACLStaysAllowed(acl: String) async throws {
        try await LibraryFixture.with { fixture in
            let app = try fixture.app("Tool", bundleID: "com.example.tool", subfolder: "Vendor/Sub")
            try AccessControlFixture.grant(acl, to: fixture.system("Applications/Vendor"))
            #expect(RemovalGuard(layout: fixture.layout).check(app) == .allowed)
        }
    }

    /// Metadatenfälle ohne privilegiertes `chown`: übliche Systemordner bleiben erlaubt, fremde Eigentümer und
    /// nicht privilegierte schreibberechtigte Gruppen werden abgelehnt.
    @Test func directoryOwnershipAndGroupPolicy() {
        let currentUser = geteuid()
        let cases: [(uid_t, gid_t, mode_t, Bool)] = [
            (0, 80, 0o775, true), (0, 0, 0o775, true), (0, 20, 0o755, true),
            (0, 20, 0o775, false), (0, 80, 0o777, false),
            (currentUser, 20, 0o700, true), (currentUser, 20, 0o755, true),
            (currentUser, 20, 0o775, false), (currentUser, 20, 0o777, false),
            (currentUser + 1, 20, 0o755, false), (currentUser + 1, 80, 0o775, false),
        ]
        for (owner, group, mode, allowed) in cases {
            var info = stat()
            info.st_uid = owner
            info.st_gid = group
            info.st_mode = mode | mode_t(S_IFDIR)
            #expect(RemovalGuard.hasTrustedDirectoryPermissions(info) == allowed)
        }
    }

    @Test func groupWritableUserOwnedFolderIsBlocked() async throws {
        try await LibraryFixture.with { fixture in
            let app = try fixture.app("Tool", bundleID: "com.example.tool", subfolder: "Vendor/Sub")
            try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: fixture.system("Applications/Vendor"))
            #expect(RemovalGuard(layout: fixture.layout).check(app) == .blocked("Ordner fremd beschreibbar"))
        }
    }

    @Test func combiningCharacterInOrdinaryFolderStaysAllowed() async throws {
        try await LibraryFixture.with { fixture in
            let app = try fixture.app("Tool", bundleID: "com.example.tool", subfolder: "Vendor/\u{301}Sub")
            #expect(RemovalGuard(layout: fixture.layout).check(app) == .allowed)
        }
    }

    /// Gegenprobe: Derselbe Aufbau mit üblichen Rechten bleibt erlaubt.
    @Test func appBundleBelowAnOrdinaryFolderStaysAllowed() async throws {
        try await LibraryFixture.with { fixture in
            let app = try fixture.app("Tool", bundleID: "com.example.tool", subfolder: "Vendor/Sub")
            #expect(RemovalGuard(layout: fixture.layout).check(app) == .allowed)
        }
    }
}
