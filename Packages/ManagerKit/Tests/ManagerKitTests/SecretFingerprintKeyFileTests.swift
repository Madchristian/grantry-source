import Darwin
import Foundation
import Testing
@testable import ManagerKit
import TestSupport

/// #137: Die Schlüsseldatei der Fingerabdrücke ist eine vertrauliche private Datei – nie über Symlinks, Hardlinks oder
/// mit zu weiten Rechten genutzt; unzulässige Dateien werden ersetzt, ohne ihr Ziel zu berühren.
@Suite struct SecretFingerprintKeyFileTests {
    private static let foreignContents = Data("fremder Inhalt".utf8)

    private func withKeyURL(_ body: (URL, URL) throws -> Void) throws {
        try ScratchDirectory.withCanonical(prefix: "fingerprint-key") { directory in
            try body(directory, directory.appending(path: "Grantry/SecretFingerprint.key"))
        }
    }

    /// Modus, Größe, Eigentümer und Linkanzahl der Datei unter `url` (ohne Symlink-Auflösung).
    private func status(of url: URL) throws -> stat {
        var info = stat()
        try #require(lstat(url.path, &info) == 0)
        return info
    }

    /// Backup-Ausschluss frisch vom Dateisystem – `URL` cacht Ressourcenwerte, die ein anderer `URL`-Wert gesetzt hat.
    private func isExcludedFromBackup(_ url: URL) throws -> Bool {
        var fresh = URL(filePath: url.path)
        fresh.removeAllCachedResourceValues()
        return try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    }

    private func expectPrivateKeyFile(at url: URL) throws {
        let info = try status(of: url)
        #expect((info.st_mode & S_IFMT) == S_IFREG)
        #expect((info.st_mode & 0o777) == 0o600)
        #expect(info.st_size == off_t(SecretFingerprinter.keyLength))
        #expect(info.st_nlink == 1)
        #expect(!AccessControlList.grantsAccess(atPath: url.path))
    }

    @Test func keyIsCreatedPrivatelyReusedAndExcludedFromBackup() throws {
        try withKeyURL { _, url in
            let first = SecretFingerprinter.persistent(at: url)
            try expectPrivateKeyFile(at: url)
            #expect(SecretFingerprinter.persistent(at: url).keyID == first.keyID)
            #expect(SecretFingerprinter.persistent(at: url).fingerprint(of: ["x"]) == first.fingerprint(of: ["x"]))
            #expect(try isExcludedFromBackup(url))
        }
    }

    @Test func existingKeyIsExcludedFromBackupAgain() throws {
        try withKeyURL { _, url in
            let first = SecretFingerprinter.persistent(at: url)
            var target = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = false
            try target.setResourceValues(values)
            #expect(SecretFingerprinter.persistent(at: url).keyID == first.keyID)
            #expect(try isExcludedFromBackup(url))
        }
    }

    /// Ein lesbarer Schlüssel gilt als verbraucht: Er wird nicht nur nachgebessert, sondern ersetzt.
    @Test(arguments: [0o644, 0o640, 0o604, 0o660] as [mode_t])
    func keyReadableOrWritableByOthersIsReplaced(mode: mode_t) throws {
        try withKeyURL { _, url in
            let first = SecretFingerprinter.persistent(at: url)
            try #require(chmod(url.path, mode) == 0)
            let replaced = SecretFingerprinter.persistent(at: url)
            #expect(replaced.keyID != first.keyID)
            try expectPrivateKeyFile(at: url)
            #expect(SecretFingerprinter.persistent(at: url).keyID == replaced.keyID)
        }
    }

    @Test func symlinkedKeyIsReplacedWithoutTouchingItsTarget() throws {
        try withKeyURL { directory, url in
            let target = directory.appending(path: "fremd.key")
            try Data(repeating: 7, count: SecretFingerprinter.keyLength).write(to: target)
            try #require(chmod(target.path, 0o600) == 0)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)

            let fingerprinter = SecretFingerprinter.persistent(at: url)
            #expect(fingerprinter.keyID != SecretFingerprinter(key: Data(repeating: 7, count: SecretFingerprinter.keyLength)).keyID)
            try expectPrivateKeyFile(at: url)
            #expect(try Data(contentsOf: target) == Data(repeating: 7, count: SecretFingerprinter.keyLength))
            #expect(SecretFingerprinter.persistent(at: url).keyID == fingerprinter.keyID)
        }
    }

    @Test func danglingSymlinkIsReplacedWithoutCreatingItsTarget() throws {
        try withKeyURL { directory, url in
            let target = directory.appending(path: "fehlt.key")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            _ = SecretFingerprinter.persistent(at: url)
            try expectPrivateKeyFile(at: url)
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
    }

    @Test func hardLinkedKeyIsReplacedAndTheOtherNameStaysUnchanged() throws {
        try withKeyURL { directory, url in
            let first = SecretFingerprinter.persistent(at: url)
            let other = directory.appending(path: "zweiter-name.key")
            try #require(link(url.path, other.path) == 0)
            let before = try Data(contentsOf: other)
            #expect(SecretFingerprinter.persistent(at: url).keyID != first.keyID)
            try expectPrivateKeyFile(at: url)
            #expect(try Data(contentsOf: other) == before)
        }
    }

    @Test func keyWithAccessControlEntryIsReplaced() throws {
        try withKeyURL { _, url in
            let first = SecretFingerprinter.persistent(at: url)
            try AccessControlFixture.grant("group:staff allow read", to: url.path)
            #expect(SecretFingerprinter.persistent(at: url).keyID != first.keyID)
            try expectPrivateKeyFile(at: url)
        }
    }

    @Test func keyOfWrongLengthIsReplaced() throws {
        try withKeyURL { _, url in
            let first = SecretFingerprinter.persistent(at: url)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 6)
            try handle.close()
            #expect(SecretFingerprinter.persistent(at: url).keyID != first.keyID)
            try expectPrivateKeyFile(at: url)
        }
    }

    /// Ein Symlink im Ordnerpfad wird nicht verfolgt und nichts angelegt: flüchtiger Schlüssel je Aufruf.
    @Test func symlinkedDirectoryFallsBackToEphemeralKeyWithoutWriting() throws {
        try withKeyURL { directory, _ in
            let real = directory.appending(path: "echt")
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            let link = directory.appending(path: "link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            let url = link.appending(path: "SecretFingerprint.key")
            #expect(SecretFingerprinter.persistent(at: url).keyID != SecretFingerprinter.persistent(at: url).keyID)
            #expect(try FileManager.default.contentsOfDirectory(atPath: real.path).isEmpty)
        }
    }

    @Test func untrustedDirectoryFallsBackToEphemeralKeyWithoutWriting() throws {
        try withKeyURL { directory, _ in
            let shared = directory.appending(path: "geteilt")
            try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
            try #require(chmod(shared.path, 0o777) == 0)
            let url = shared.appending(path: "SecretFingerprint.key")
            #expect(throws: PrivateFileRefusal.untrustedDirectory(path: shared.path)) {
                try SecretFingerprintKeyFile.loadOrCreate(at: url, length: SecretFingerprinter.keyLength)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: shared.path).isEmpty)
        }
    }
}
