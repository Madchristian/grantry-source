import Darwin
import Foundation
import Testing
import GrantryShared
import TestSupport
@testable import ManagerKit

/// Private Ablage von Verlauf und Belegen (#141): Ordner `0700`, Dateien `0600`; vorhandene Ablagen werden nur dort
/// verschärft, wo es gefahrlos geht.
@Suite struct PrivateStorageTests {
    private let receipt = RemovalReceipt(
        label: "com.vendor.agent", backupPath: "/backups/1/LaunchAgents/com.vendor.agent.plist",
        isPrivileged: false, wasEnabled: true, wasLoaded: true
    )

    private func mode(_ url: URL) throws -> mode_t {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return info.st_mode & 0o7777
    }

    private func write(_ text: String, to url: URL, mode: mode_t = 0o644) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func makeDirectory(_ url: URL, mode: mode_t = 0o755) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    /// Eine Ablage wie von einer älteren Version: Ordner `0755`, Dateien `0644`, externe Daten im Unterordner.
    private func makeLegacyStorage(in directory: URL) throws -> StorageLocation {
        let location = StorageLocation(directory: directory.appending(path: "Grantry", directoryHint: .isDirectory))
        try makeDirectory(location.directory)
        for name in ["History.store", "History.store-wal", "History.store-shm", "Receipts.json"] {
            try write(name, to: location.directory.appending(path: name))
        }
        let external = location.directory.appending(path: ".History_SUPPORT/_EXTERNAL_DATA", directoryHint: .isDirectory)
        try makeDirectory(external)
        try makeDirectory(external.deletingLastPathComponent())
        try write("blob", to: external.appending(path: "blob"))
        return location
    }

    // MARK: Neuanlage

    @Test func newStorageDirectoriesArePrivate() throws {
        try ScratchDirectory.withCanonical(prefix: "private") { directory in
            let target = directory.appending(path: "Support/Grantry", directoryHint: .isDirectory)
            let storage = try PrivateDirectory(at: target)
            #expect(try mode(target) == 0o700)
            #expect(try mode(target.deletingLastPathComponent()) == 0o700)
            #expect(storage.restrictions.isEmpty)
        }
    }

    @Test func liveStoreCreatesPrivateFilesIncludingWALAndSHM() async throws {
        try await ScratchDirectory.withCanonical(prefix: "private") { directory in
            let location = StorageLocation(directory: directory.appending(path: "Grantry", directoryHint: .isDirectory))
            let store = try SwiftDataSnapshotStore.live(in: location)
            _ = try await store.record(TestData.snapshot(items: [TestData.item()]), events: [])

            #expect(try mode(location.directory) == 0o700)
            #expect(try mode(location.historyStoreURL) == 0o600)
            for suffix in ["-wal", "-shm"] {
                let file = URL(filePath: location.historyStoreURL.path + suffix)
                #expect(try mode(file) == 0o600)
            }
        }
    }

    @Test func newReceiptsArePrivate() async throws {
        try await ScratchDirectory.withCanonical(prefix: "private") { directory in
            let url = directory.appending(path: "Grantry/Receipts.json")
            _ = try await ReceiptStore(url: url).add(receipt, label: "A", removedAt: TestData.date)
            #expect(try mode(url) == 0o600)
            #expect(try mode(url.deletingLastPathComponent()) == 0o700)
        }
    }

    // MARK: Vorhandene Ablage

    @Test func openingHardensAnExistingStorage() throws {
        try ScratchDirectory.withCanonical(prefix: "private") { directory in
            let location = try makeLegacyStorage(in: directory)
            let support = location.directory.appending(path: ".History_SUPPORT", directoryHint: .isDirectory)

            let storage = try location.openPrivately()

            #expect(storage.restrictions.isEmpty)
            #expect(try mode(location.directory) == 0o700)
            for name in ["History.store", "History.store-wal", "History.store-shm", "Receipts.json"] {
                #expect(try mode(location.directory.appending(path: name)) == 0o600)
            }
            #expect(try mode(support) == 0o700)
            #expect(try mode(support.appending(path: "_EXTERNAL_DATA")) == 0o700)
            #expect(try mode(support.appending(path: "_EXTERNAL_DATA/blob")) == 0o600)
        }
    }

    @Test func liveStoreHardensAnExistingStore() async throws {
        try await ScratchDirectory.withCanonical(prefix: "private") { directory in
            let location = StorageLocation(directory: directory.appending(path: "Grantry", directoryHint: .isDirectory))
            try makeDirectory(location.directory)
            do {
                let store = try SwiftDataSnapshotStore(url: location.historyStoreURL)
                _ = try await store.record(TestData.snapshot(), events: [])
            }
            try makeDirectory(location.directory)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: location.historyStoreURL.path)

            _ = try SwiftDataSnapshotStore.live(in: location)

            #expect(try mode(location.directory) == 0o700)
            #expect(try mode(location.historyStoreURL) == 0o600)
        }
    }

    /// Eine unlesbare Ablage wird beiseitegelegt; die frische entsteht ebenfalls privat, die beiseitegelegte bleibt es.
    @Test func recoveredStoreIsPrivate() async throws {
        try await ScratchDirectory.withCanonical(prefix: "private") { directory in
            let location = StorageLocation(directory: directory.appending(path: "Grantry", directoryHint: .isDirectory))
            try makeDirectory(location.directory)
            try write(String(repeating: "kaputt", count: 1_000), to: location.historyStoreURL)

            let store = try SwiftDataSnapshotStore.live(in: location)
            _ = try await store.record(TestData.snapshot(), events: [])

            #expect(try mode(location.historyStoreURL) == 0o600)
            let setAside = try FileManager.default.contentsOfDirectory(atPath: location.directory.path)
                .filter { $0.hasPrefix("History.store.defekt-") }
            #expect(setAside.count == 1)
            for name in setAside { #expect(try mode(location.directory.appending(path: name)) == 0o600) }
        }
    }

    /// Andere Unterordner – etwa die Benutzer-Backups mit ihren eigenen Rechteregeln – bleiben unberührt.
    @Test func openingLeavesOtherSubdirectoriesAlone() throws {
        try ScratchDirectory.withCanonical(prefix: "private") { directory in
            let location = try makeLegacyStorage(in: directory)
            let backup = location.backupsDirectory.appending(path: "20260101-000000-000/LaunchAgents", directoryHint: .isDirectory)
            try makeDirectory(backup)
            try write("plist", to: backup.appending(path: "com.vendor.agent.plist"))

            _ = try location.openPrivately()

            #expect(try mode(backup) == 0o755)
            #expect(try mode(backup.appending(path: "com.vendor.agent.plist")) == 0o644)
        }
    }

    @Test func existingReceiptsBecomePrivateWhenRewritten() async throws {
        try await ScratchDirectory.withCanonical(prefix: "private") { directory in
            let folder = directory.appending(path: "Grantry", directoryHint: .isDirectory)
            try makeDirectory(folder)
            let url = folder.appending(path: "Receipts.json")
            try write("[]", to: url)

            _ = try await ReceiptStore(url: url).add(receipt, label: "A", removedAt: TestData.date)

            #expect(try mode(url) == 0o600)
            #expect(try mode(folder) == 0o700)
        }
    }

    // MARK: Nicht blind verändern

    /// Echte Startreihenfolge (Verlauf öffnen, dann Fingerprinter laden): Ein offengelegter Schlüssel wird nicht per
    /// Härtung „repariert“, sondern von `SecretFingerprintKeyFile` ersetzt – die `keyID` wechselt.
    @Test(arguments: [false, true])
    func exposedFingerprintKeyIsRotatedNotRepaired(viaACL: Bool) throws {
        try ScratchDirectory.withCanonical(prefix: "private") { directory in
            let location = StorageLocation(directory: directory.appending(path: "Grantry", directoryHint: .isDirectory))
            let original = location.secretFingerprinter().keyID
            let key = location.secretFingerprintKeyURL
            if viaACL {
                try AccessControlFixture.grant("group:everyone allow read", to: key.path)
            } else {
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: key.path)
            }

            _ = try SwiftDataSnapshotStore.live(in: location)
            let reloaded = location.secretFingerprinter()

            #expect(reloaded.keyID != original)
            #expect(try mode(key) == 0o600)
            #expect(!AccessControlList.grantsAccess(atPath: key.path))
        }
    }

    /// Auch die Instanzsperre prüft selbst; die Härtung lässt sie unverändert.
    @Test func instanceLockIsLeftToItsOwnCheck() throws {
        try ScratchDirectory.withCanonical(prefix: "private") { directory in
            let location = try makeLegacyStorage(in: directory)
            try write("running 1\n", to: location.instanceLockURL, mode: 0o664)

            let storage = try location.openPrivately()

            #expect(try mode(location.instanceLockURL) == 0o664)
            #expect(storage.restrictions.isEmpty)
        }
    }

    @Test func symlinkIsReportedAndItsTargetLeftUnchanged() throws {
        try ScratchDirectory.withCanonical(prefix: "private") { directory in
            let location = try makeLegacyStorage(in: directory)
            let outside = directory.appending(path: "outside.txt")
            try write("fremd", to: outside)
            let link = location.directory.appending(path: "History.store-wal")
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

            let storage = try location.openPrivately()

            #expect(try mode(outside) == 0o644)
            #expect(storage.restrictions == [.init(path: link.path, reason: .symbolicLink)])
            #expect(try mode(location.historyStoreURL) == 0o600)
        }
    }

    @Test func hardLinkedFileIsReportedAndLeftUnchanged() throws {
        try ScratchDirectory.withCanonical(prefix: "private") { directory in
            let location = try makeLegacyStorage(in: directory)
            let outside = directory.appending(path: "outside.txt")
            try write("fremd", to: outside)
            let linked = location.directory.appending(path: "History.store-shm")
            try FileManager.default.removeItem(at: linked)
            try FileManager.default.linkItem(at: outside, to: linked)

            let storage = try location.openPrivately()

            #expect(try mode(outside) == 0o644)
            #expect(storage.restrictions == [.init(path: linked.path, reason: .multipleLinks)])
        }
    }

    /// Gehört ein Eintrag einem anderen Benutzer, wird nichts verändert, nur gemeldet (als fremder Eigentümer gilt hier
    /// der Testbenutzer selbst, weil Tests keine Dateien anderer Benutzer anlegen können).
    @Test func foreignOwnerIsReportedAndLeftUnchanged() throws {
        try ScratchDirectory.withCanonical(prefix: "private") { directory in
            let location = try makeLegacyStorage(in: directory)

            let storage = try location.openPrivately(owner: geteuid() + 1)

            #expect(try mode(location.directory) == 0o755)
            #expect(try mode(location.historyStoreURL) == 0o644)
            #expect(try mode(location.receiptsURL) == 0o644)
            #expect(storage.restrictions.contains(.init(path: location.directory.path, reason: .foreignOwner)))
            #expect(storage.restrictions.contains(.init(path: location.historyStoreURL.path, reason: .foreignOwner)))
            #expect(storage.restrictions.allSatisfy { $0.reason == .foreignOwner })
        }
    }

    @Test func symlinkedStorageDirectoryIsRefused() throws {
        try ScratchDirectory.withCanonical(prefix: "private") { directory in
            let real = directory.appending(path: "real", directoryHint: .isDirectory)
            try makeDirectory(real)
            let link = directory.appending(path: "Grantry")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

            #expect(throws: POSIXError(.ELOOP)) { try PrivateDirectory(at: link) }
            #expect(try mode(real) == 0o755)
        }
    }
}
