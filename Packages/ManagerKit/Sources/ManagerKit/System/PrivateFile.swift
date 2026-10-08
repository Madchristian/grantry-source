import Darwin
import Foundation
import GrantryShared

/// Grund, eine vorgefundene private Datei oder ihren Ordner abzulehnen (Symlinks melden `POSIXError(.ELOOP)`).
public enum PrivateFileRefusal: Error, Equatable, Sendable, LocalizedError {
    /// Ein Ordner im Pfad gehört einem anderen Benutzer, ist ohne Sticky-Bit für andere beschreibbar oder gewährt
    /// anderen per ACL Änderungsrechte.
    case untrustedDirectory(path: String)
    /// Die Datei ist keine reguläre Datei (etwa eine FIFO oder ein Gerät).
    case notRegularFile
    /// Die Datei gehört einem anderen Benutzer.
    case foreignOwner
    /// Die Datei hat mehrere Namen (Hardlink).
    case multipleLinks
    /// Die Datei ist für Gruppe oder andere beschreibbar oder ihre ACL gewährt anderen Änderungsrechte.
    case modifiableByOthers
    /// Die vertrauliche Datei ist für Gruppe oder andere zugänglich (Modusbits) oder hat eine ACL mit Allow-Einträgen.
    case accessibleByOthers

    public var errorDescription: String? {
        switch self {
        case .untrustedDirectory(let path):
            "Der Ordner \(path) gehört einem anderen Benutzer oder ist für andere beschreibbar"
        case .notRegularFile: "Die Datei ist keine reguläre Datei"
        case .foreignOwner: "Die Datei gehört einem anderen Benutzer"
        case .multipleLinks: "Die Datei hat mehrere Namen (Hardlink)"
        case .modifiableByOthers: "Die Datei ist für andere änderbar"
        case .accessibleByOthers: "Die Datei ist für andere zugänglich"
        }
    }
}

/// Dateien der App im Ablageort, die nie auf eine fremde Datei umgelenkt oder von anderen verändert werden dürfen
/// (Instanzsperre, #136; Schlüssel der Fingerabdrücke, #137):
/// - Der Ordner wird ab `/` Komponente für Komponente ohne Symlink-Auflösung geöffnet und als Deskriptor gehalten
///   (`BoundDirectory`). Jeder Ordner der Kette gehört dem Benutzer oder root, ist für Gruppe und andere nur mit
///   Sticky-Bit beschreibbar und gewährt anderen Prinzipalen per ACL keine Änderungsrechte
///   (`AccessControlList.grantsModification`) – sonst könnte ein anderer Benutzer Einträge darin austauschen.
/// - Die Datei wird relativ zu diesem Deskriptor mit `O_NOFOLLOW` geöffnet und am Deskriptor geprüft (`check`):
///   reguläre Datei des Benutzers mit genau einem Namen (ein Hardlink könnte auf eine andere Datei zeigen), je nach
///   `Protection` nicht änderbar bzw. gar nicht zugänglich für andere.
enum PrivateFile {
    /// Was anderen Benutzern verwehrt sein muss.
    enum Protection: Sendable {
        /// Nicht änderbar (Modusbits `0o022`, ACL-Änderungsrechte): Der Inhalt darf sichtbar sein, aber nicht gefälscht
        /// werden (Instanzsperre).
        case writeProtected
        /// Weder les- noch änderbar (Modusbits `0o077`, jeder ACL-Allow-Eintrag): Geheimnisse wie Schlüssel.
        case confidential
    }

    /// Rechte neu angelegter Ordner und Dateien.
    static let directoryMode: mode_t = 0o700
    static let fileMode: mode_t = 0o600

    /// Öffnet `path` gebunden (`BoundDirectory`), jeder Ordner der Kette geprüft; fehlende legt es mit `creationMode`
    /// an, ohne ihn nur lesend. `prepare` erhält den Zielordner selbst (Deskriptor und Pfad) vor seiner Prüfung – etwa
    /// um ihn zu härten (`PrivateDirectory`).
    /// - Throws: `PrivateFileRefusal.untrustedDirectory`, `POSIXError` (`ELOOP` für einen Symlink im Pfad).
    static func trustedDirectory(
        at path: String,
        creatingMissingWith creationMode: mode_t? = nil,
        preparing prepare: (_ descriptor: Int32, _ path: String) -> Void = { _, _ in }
    ) throws -> BoundDirectory {
        let target = "/" + path.split(separator: "/").joined(separator: "/")
        return try BoundDirectory(path: path, creatingMissingWith: creationMode) { descriptor, current in
            if current == target { prepare(descriptor, current) }
            try checkTrusted(directory: descriptor, at: current)
        }
    }

    /// Ersetzt `name` in `directory` atomar durch eine vertrauliche Datei mit `data`: Sie entsteht als temporäre Datei
    /// (`createConfidential` – privat vor dem ersten Byte), wird geschrieben, mit `fsync` gesichert und per `renameat`
    /// an ihren Platz gebracht; ein Symlink unter dem Namen wird dabei ersetzt, nie verfolgt. Scheitert etwas, wird sie
    /// entfernt.
    static func writeAtomically(_ data: [UInt8], named name: String, in directory: BoundDirectory) throws {
        let temporary = ".\(name).\(UUID().uuidString)"
        let descriptor = try createConfidential(named: temporary, in: directory)
        var isRenamed = false
        defer {
            close(descriptor)
            if !isRenamed { unlinkat(directory.descriptor, temporary, 0) }
        }
        try writeFully(data, to: descriptor)
        guard fsync(descriptor) == 0 else { throw BoundDirectory.posixError() }
        guard renameat(directory.descriptor, temporary, directory.descriptor, name) == 0 else {
            throw BoundDirectory.posixError()
        }
        isRenamed = true
    }

    /// Prüft die geöffnete Datei (siehe Typbeschreibung) und liefert ihren Status.
    /// - Throws: `PrivateFileRefusal`, `POSIXError`, wenn `fstat` scheitert.
    @discardableResult
    static func check(_ descriptor: Int32, protection: Protection) throws -> stat {
        let info = try status(of: descriptor)
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw PrivateFileRefusal.notRegularFile }
        guard info.st_uid == geteuid() else { throw PrivateFileRefusal.foreignOwner }
        guard info.st_nlink == 1 else { throw PrivateFileRefusal.multipleLinks }
        guard (info.st_mode & 0o022) == 0,
              !AccessControlList.grantsModification(toOthersThan: geteuid(), descriptor: descriptor) else {
            throw PrivateFileRefusal.modifiableByOthers
        }
        if protection == .confidential {
            guard (info.st_mode & 0o077) == 0, !AccessControlList.grantsAccess(descriptor: descriptor) else {
                throw PrivateFileRefusal.accessibleByOthers
            }
        }
        return info
    }

    /// Legt `name` in `directory` neu und leer als vertrauliche Datei an und liefert ihren Deskriptor (zum Schreiben):
    /// `openat` mit `O_CREAT | O_EXCL | O_NOFOLLOW` – nie eine vorhandene Datei, nie über einen Symlink –, dann `0600`
    /// unabhängig von der umask und ohne geerbte ACL, geprüft (`.confidential`). Scheitert die Prüfung, wird die Datei
    /// entfernt.
    /// - Throws: `POSIXError` (`EEXIST`, wenn `name` schon existiert), `PrivateFileRefusal`.
    static func createConfidential(named name: String, in directory: BoundDirectory) throws -> Int32 {
        let descriptor = openat(
            directory.descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NOCTTY | O_CLOEXEC, fileMode
        )
        guard descriptor >= 0 else { throw BoundDirectory.posixError() }
        do {
            guard fchmod(descriptor, fileMode) == 0, AccessControlList.remove(from: descriptor) else {
                throw BoundDirectory.posixError()
            }
            try check(descriptor, protection: .confidential)
            return descriptor
        } catch {
            close(descriptor)
            unlinkat(directory.descriptor, name, 0)
            throw error
        }
    }

    /// Schreibt `data` vollständig ab Offset 0 (`pwrite`); bei `EINTR` wird wiederholt, jeder andere Fehler geworfen.
    static func writeFully(_ data: [UInt8], to descriptor: Int32) throws {
        var written = 0
        while written < data.count {
            let count = data.withUnsafeBytes { bytes in
                pwrite(descriptor, bytes.baseAddress! + written, bytes.count - written, off_t(written))
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw count < 0 ? BoundDirectory.posixError() : POSIXError(.EIO) }
            written += count
        }
    }

    /// Liest höchstens `limit` Bytes ab Offset 0.
    static func read(_ descriptor: Int32, limit: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: limit)
        while true {
            let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw BoundDirectory.posixError() }
            return Array(buffer.prefix(count))
        }
    }

    static func status(of descriptor: Int32) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw BoundDirectory.posixError() }
        return info
    }

    /// Ein Ordner der Kette gehört dem Benutzer oder root; für Gruppe oder andere beschreibbar nur mit Sticky-Bit
    /// (dort kann niemand die Einträge anderer umbenennen oder löschen); seine ACL gewährt anderen keine
    /// Änderungsrechte.
    private static func checkTrusted(directory descriptor: Int32, at path: String) throws {
        let info = try status(of: descriptor)
        let hasTrustedOwner = info.st_uid == geteuid() || info.st_uid == 0
        let isWritableByOthers = (info.st_mode & 0o022) != 0
        let isSticky = (info.st_mode & S_ISVTX) != 0
        guard hasTrustedOwner, !isWritableByOthers || isSticky,
              !AccessControlList.grantsModification(toOthersThan: geteuid(), descriptor: descriptor) else {
            throw PrivateFileRefusal.untrustedDirectory(path: path)
        }
    }
}
