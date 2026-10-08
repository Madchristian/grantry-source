import Foundation
import GrantryShared

/// Ablageort der dauerhaften Daten der App (Verlauf, Wiederherstellungsbelege, Benutzer-Backups). Standard ist
/// `~/Library/Application Support/Grantry`; eine zweite Instanz (nur Entwicklung) nutzt einen Unterordner, damit
/// nie zwei Prozesse in dieselben Dateien schreiben.
///
/// Nicht Teil des Ablageorts und daher mit einer zweiten Instanz geteilt: die System-Backups des Helpers
/// (`PlistBackupStore.system`, root-eigen) und die `UserDefaults` der App (z. B. „Onboarding erledigt“).
public struct StorageLocation: Hashable, Sendable {
    /// Verzeichnis aller Dateien dieses Ablageorts.
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/Grantry`.
    public static var standard: StorageLocation {
        StorageLocation(directory: URL.applicationSupportDirectory.appending(path: "Grantry", directoryHint: .isDirectory))
    }

    /// Ablageort in einem Unterordner dieses Ablageorts.
    public func subdirectory(_ name: String) -> StorageLocation {
        StorageLocation(directory: directory.appending(path: name, directoryHint: .isDirectory))
    }

    /// SwiftData-Ablage des Verlaufs.
    public var historyStoreURL: URL { directory.appending(path: "History.store") }

    /// Wiederherstellungsbelege (`ReceiptStore`).
    public var receiptsURL: URL { directory.appending(path: "Receipts.json") }

    /// Backups entfernter Benutzer-LaunchAgents (`PlistBackupStore.user(root:)`).
    public var backupsDirectory: URL { directory.appending(path: "Backups", directoryHint: .isDirectory) }

    /// Speicher für Backups aus `~/Library/LaunchAgents` in `backupsDirectory`.
    public var userBackups: PlistBackupStore { .user(root: backupsDirectory) }

    /// Sperrdatei der Instanz, die diesen Ablageort nutzt (`InstanceLock`).
    public var instanceLockURL: URL { directory.appending(path: "Instance.lock") }
}
