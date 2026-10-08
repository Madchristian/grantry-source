import Foundation
import Testing
import GrantryShared
import ManagerKit
import TestSupport

@Suite struct StorageLocationTests {
    @Test func standardLocationIsInApplicationSupport() {
        let standard = StorageLocation.standard
        #expect(standard.historyStoreURL.path.hasSuffix("Library/Application Support/Grantry/History.store"))
        #expect(standard.receiptsURL.path.hasSuffix("Library/Application Support/Grantry/Receipts.json"))
        #expect(ReceiptStore.defaultURL == standard.receiptsURL)
        #expect(standard.instanceLockURL.path.hasSuffix("Library/Application Support/Grantry/Instance.lock"))
    }

    /// Die Benutzer-Backups liegen im Ablageort; der Standard entspricht `PlistBackupStore.user()`.
    @Test func backupsLiveInTheStorageLocation() {
        #expect(StorageLocation.standard.backupsDirectory.standardizedFileURL == PlistBackupStore.user().root.standardizedFileURL)
        let debug = StorageLocation.standard.subdirectory("Debug-Zweitinstanz")
        #expect(debug.backupsDirectory.path.hasSuffix("Grantry/Debug-Zweitinstanz/Backups"))
        #expect(debug.userBackups.root == debug.backupsDirectory)
    }

    @Test func subdirectoryKeepsFilesApart() {
        let debug = StorageLocation.standard.subdirectory("Debug-Zweitinstanz")
        #expect(debug.historyStoreURL.path.hasSuffix("Grantry/Debug-Zweitinstanz/History.store"))
        #expect(debug.receiptsURL.path.hasSuffix("Grantry/Debug-Zweitinstanz/Receipts.json"))
        #expect(debug.historyStoreURL != StorageLocation.standard.historyStoreURL)
    }

    @Test func liveStoreOpensInTheGivenLocation() async throws {
        try await ScratchDirectory.withCanonical(prefix: "storage") { directory in
            let location = StorageLocation(directory: directory.appending(path: "nested", directoryHint: .isDirectory))
            let store = try SwiftDataSnapshotStore.live(in: location)
            #expect(try await store.latestSnapshot() == nil)
            #expect(FileManager.default.fileExists(atPath: location.historyStoreURL.path))
        }
    }
}
