import CryptoKit
import Darwin
import Foundation
import GrantryShared
import os

/// Schlüsseldatei der Fingerabdrücke (`SecretFingerprinter`, #137) – eine vertrauliche private Datei (`PrivateFile`,
/// Schutz `.confidential`):
/// - Ordner und Datei werden ohne Symlink-Auflösung geöffnet und geprüft wie die Instanzsperre (`BoundDirectory`,
///   `PrivateFile.trustedDirectory`, `O_NOFOLLOW`); ein nicht vertrauenswürdiger Ordner bricht ab, ohne etwas anzulegen.
/// - Gültig ist nur eine reguläre Datei des Benutzers mit genau einem Namen, genau `length` Bytes, ohne Gruppen- und
///   Weltrechte und ohne ACL-Allow-Einträge.
/// - Jede andere vorgefundene Datei – Symlink, zu weite Rechte, Hardlink, falsche Länge, FIFO, fremder Eigentümer – wird
///   nicht gelesen, sondern ersetzt: Ein Schlüssel, den andere lesen konnten, ist verbraucht. Der neue entsteht in einer
///   temporären Datei (`openat` mit `O_CREAT | O_EXCL | O_NOFOLLOW`, `0600`, ACL entfernt), die nach dem Schreiben
///   geprüft und per `renameat` an ihren Platz gebracht wird – ein Symlink unter dem Namen wird dabei ersetzt, nie
///   verfolgt. Danach wird die Datei unter ihrem Namen erneut geöffnet und geprüft.
/// - Auch ein bestehender Schlüssel wird (erneut) vom Backup ausgenommen.
enum SecretFingerprintKeyFile {
    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "secrets")

    /// Liest den Schlüssel oder legt ihn an.
    /// - Throws: `PrivateFileRefusal.untrustedDirectory`, `POSIXError` (auch `ELOOP` für einen Symlink im Ordnerpfad),
    ///   `PrivateFileRefusal`, wenn selbst der neu angelegte Schlüssel die Prüfung nicht besteht.
    static func loadOrCreate(at url: URL, length: Int) throws -> Data {
        let directory = try PrivateFile.trustedDirectory(
            at: url.deletingLastPathComponent().path(percentEncoded: false), creatingMissingWith: PrivateFile.directoryMode
        )
        let name = url.lastPathComponent
        let key: Data
        do {
            key = try read(name, in: directory, length: length)
        } catch let refusal as Replaceable {
            logger.notice("Schlüsseldatei wird ersetzt: \(refusal.reason, privacy: .public)")
            try create(name, in: directory, length: length)
            key = try read(name, in: directory, length: length)
        }
        excludeFromBackup(url)
        return key
    }

    /// Grund, die vorgefundene Datei durch einen neuen Schlüssel zu ersetzen.
    private struct Replaceable: Error {
        let reason: String
    }

    /// Öffnet `name` ohne Symlink-Auflösung und liest ihn nach der Prüfung am Deskriptor.
    /// - Throws: `Replaceable` für eine fehlende oder unzulässige Datei, sonst den Lesefehler.
    private static func read(_ name: String, in directory: BoundDirectory, length: Int) throws -> Data {
        let descriptor = openat(directory.descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            // `ELOOP`: Symlink; `ENOENT`: fehlt.
            guard code == ENOENT || code == ELOOP else { throw BoundDirectory.posixError(code) }
            throw Replaceable(reason: code == ELOOP ? "Symlink" : "fehlt")
        }
        defer { close(descriptor) }
        let info: stat
        do {
            info = try PrivateFile.check(descriptor, protection: .confidential)
        } catch let refusal as PrivateFileRefusal {
            throw Replaceable(reason: refusal.localizedDescription)
        }
        guard info.st_size == off_t(length) else { throw Replaceable(reason: "Länge \(info.st_size)") }
        let bytes = try PrivateFile.read(descriptor, limit: length + 1)
        guard bytes.count == length else { throw Replaceable(reason: "Länge \(bytes.count)") }
        return Data(bytes)
    }

    /// Schreibt einen neuen Zufallsschlüssel atomar unter `name` (`PrivateFile.writeAtomically`).
    private static func create(_ name: String, in directory: BoundDirectory, length: Int) throws {
        let key = SymmetricKey(size: SymmetricKeySize(bitCount: length * 8)).withUnsafeBytes { Array($0) }
        try PrivateFile.writeAtomically(key, named: name, in: directory)
    }

    /// Nimmt die Schlüsseldatei vom Backup aus (Time Machine); ein Fehler wird nur protokolliert. Erst nach der Prüfung
    /// aufgerufen – der Ordner ist vertrauenswürdig, nur der Benutzer kann den Namen austauschen.
    private static func excludeFromBackup(_ url: URL) {
        // Frischer `URL`-Wert ohne zwischengespeicherte Ressourcenwerte: geschrieben wird der Stand auf der Platte.
        var target = URL(filePath: url.path(percentEncoded: false))
        target.removeAllCachedResourceValues()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try target.setResourceValues(values)
        } catch {
            logger.error("Schlüsseldatei nicht vom Backup ausgenommen: \(error.readableDescription, privacy: .public)")
        }
    }
}
