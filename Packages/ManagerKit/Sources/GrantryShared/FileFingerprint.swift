import Darwin
import Foundation

/// Änderungsdatum, Statusänderungszeit (ctime), Größe und Inode eines Ziels – ändert sich bei In-Place-Updates und
/// beim Austausch des Bundles. Grundlage aller Caches, die ein Prüfergebnis pro Pfad so lange behalten, wie sich das
/// Ziel nicht ändert, und der Bindung einer zu löschenden Plist an den Stand aus dem Scan (#156).
///
/// Das Änderungsdatum eines Bundle-Verzeichnisses ändert sich nur, wenn sich seine direkten Einträge ändern –
/// In-Place-Updates (App Store, `ditto`, `rsync`) blieben unbemerkt. Für Bundles zählen daher Datum, ctime und Größe von
/// `Contents/_CodeSignature/CodeResources` (fällt zurück auf `Contents/Info.plist`), zusammen mit der Inode des
/// Bundle-Verzeichnisses, die einen Austausch des ganzen Bundles verrät (`init?(of:)` in ManagerKit). Die ctime lässt
/// sich – anders als das Änderungsdatum (`touch -r`, `utimes`) – nicht zurücksetzen (Review N6). Eine nachträglich
/// veränderte Ressource ohne neue Signatur ändert den Fingerabdruck dagegen nicht.
///
/// Gespeichert wird er für das Hauptprogramm installierter Apps (`InstalledApp.executableFingerprint`) und für
/// launchd-Plists (`AutostartItem.plistFingerprint`). Ältere Snapshots kennen ctime und Größe nicht (`nil`); dafür
/// vergleicht `matches(_:)` nur, was beide Seiten kennen.
///
/// Liegt in GrantryShared, weil auch der Helper eine Plist nur löscht, wenn sie noch den Fingerabdruck aus dem Scan
/// trägt (`PlistBackupStore.backupForRemoval(_:expecting:)`); über XPC reist er JSON-kodiert.
public struct FileFingerprint: Hashable, Sendable, Codable {
    package let modified: Date?
    package let fileNumber: UInt64?
    /// Statusänderungszeit (`st_ctimespec`) der Datei, deren Datum `modified` ist.
    package let statusChanged: Date?
    /// Größe in Bytes der Datei, deren Datum `modified` ist.
    package let size: Int64?

    package init(modified: Date?, fileNumber: UInt64?, statusChanged: Date? = nil, size: Int64? = nil) {
        self.modified = modified
        self.fileNumber = fileNumber
        self.statusChanged = statusChanged
        self.size = size
    }

    /// Fingerabdruck aus einem `stat`-Ergebnis – über einen Pfad (`lstat`) wie über einen geöffneten Deskriptor
    /// (`fstat`) gleich. Das Änderungsdatum wird genau so umgerechnet wie in `FileManager.attributesOfItem`
    /// (`.modificationDate`), damit gespeicherte Fingerabdrücke vergleichbar bleiben.
    package init(status: stat) {
        let modified = status.st_mtimespec
        let changed = status.st_ctimespec
        self.init(
            modified: Date(
                timeIntervalSinceReferenceDate: (TimeInterval(modified.tv_sec) - Date.timeIntervalBetween1970AndReferenceDate)
                    + 1.0e-9 * TimeInterval(modified.tv_nsec)
            ),
            fileNumber: UInt64(status.st_ino),
            statusChanged: Date(
                timeIntervalSince1970: TimeInterval(changed.tv_sec) + TimeInterval(changed.tv_nsec) / 1_000_000_000
            ),
            size: Int64(status.st_size)
        )
    }

    /// Gleich bis auf Felder, die eine Seite nicht kennt (ctime und Größe fehlen in älteren Snapshots).
    public func matches(_ other: FileFingerprint) -> Bool {
        modified == other.modified && fileNumber == other.fileNumber
            && Self.knownValuesMatch(statusChanged, other.statusChanged) && Self.knownValuesMatch(size, other.size)
    }

    private static func knownValuesMatch<Value: Equatable>(_ lhs: Value?, _ rhs: Value?) -> Bool {
        guard let lhs, let rhs else { return true }
        return lhs == rhs
    }
}
