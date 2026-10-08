import Darwin
import Foundation

/// Ergebnis des gefahrlosen Lesens einer Datei (`RegularFileReader`).
package enum RegularFileRead: Equatable, Sendable {
    /// Die Datei gibt es nicht – auch ein ins Leere zeigender Symlink.
    case missing
    /// Inhalt und POSIX-Rechte (`0o644` …).
    case contents(Data, mode: UInt16)
    /// Vorhanden, aber nicht gelesen; Grund im Klartext ohne Inhalt.
    case unreadable(String)
}

/// Liest Dateien, ohne an Sonderdateien hängen zu bleiben: nur reguläre Dateien (keine FIFO, kein Gerät, kein
/// Socket, kein Verzeichnis), höchstens `maximumSize` Bytes. Symlinks werden gefolgt.
///
/// Ohne Rennen zwischen Prüfung und Lesen: Die Datei wird zuerst geöffnet (`O_NONBLOCK` – eine FIFO blockiert nicht,
/// `O_NOCTTY`), Art, Größe und Rechte liefert `fstat` am Deskriptor, gelesen wird vom selben Deskriptor. Ein Austausch
/// der Datei nach der Prüfung ändert nichts mehr. Eine unverbindliche Vorprüfung per `stat` öffnet Geräte, FIFOs und
/// Sockets gar nicht erst.
///
/// Genutzt für Agenten-Konfigurationen (`AgentConfigReader`) und launchd-Plists (`LaunchdSource`,
/// `PrivilegedOperationPolicy.ensureLabelIsUnique`).
package enum RegularFileReader {
    /// Grund für Lesefehler ohne nähere Ursache (`RegularFileRead.unreadable`).
    package static let unreadableText = "nicht lesbar"
    package static let notRegularText = "keine reguläre Datei"

    /// Liest `path`. `verifyOpened` prüft den geöffneten Deskriptor, bevor Art und Größe zählen, und liefert einen
    /// Ablehnungsgrund oder `nil` (etwa: aufgelöstes Ziel liegt außerhalb eines erlaubten Ordners).
    package static func read(
        atPath path: String, maximumSize: Int, verifyOpened: (_ descriptor: Int32) -> String? = { _ in nil }
    ) -> RegularFileRead {
        var preliminary = stat()
        if stat(path, &preliminary) == 0, isSpecialFile(mode: preliminary.st_mode) { return .unreadable(notRegularText) }
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        guard descriptor >= 0 else { return failedOpen(errno) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return .unreadable(unreadableText) }
        if let reason = verifyOpened(descriptor) { return .unreadable(reason) }
        guard info.st_mode & S_IFMT == S_IFREG else { return .unreadable(notRegularText) }
        guard Int(info.st_size) <= maximumSize else { return .unreadable(sizeLimitText(maximumSize)) }
        let mode = UInt16(info.st_mode & 0o777)
        // Ein Byte mehr als angekündigt lesen: Wächst die Datei inzwischen über die Grenze, fällt es auf.
        guard let data = contents(of: descriptor, maximumLength: min(Int(info.st_size), maximumSize) + 1) else {
            return .unreadable(unreadableText)
        }
        guard data.count <= maximumSize else { return .unreadable(sizeLimitText(maximumSize)) }
        return .contents(data, mode: mode)
    }

    /// FIFO, Socket oder Gerät – Dateiarten, deren Öffnen blockieren oder Nebenwirkungen haben kann.
    package static func isSpecialFile(mode: mode_t) -> Bool {
        switch mode & S_IFMT {
        case S_IFIFO, S_IFSOCK, S_IFCHR, S_IFBLK: true
        default: false
        }
    }

    /// „größer als 5 MB“ – Einheit nach der Grenze (MB, KB oder Bytes, ganzzahlig).
    package static func sizeLimitText(_ maximumSize: Int) -> String {
        let megabyte = 1024 * 1024
        if maximumSize >= megabyte, maximumSize.isMultiple(of: megabyte) { return "größer als \(maximumSize / megabyte) MB" }
        if maximumSize >= 1024, maximumSize.isMultiple(of: 1024) { return "größer als \(maximumSize / 1024) KB" }
        return "größer als \(maximumSize) Bytes"
    }

    /// Höchstens `maximumLength` Bytes vom Deskriptor; `nil` bei einem Lesefehler.
    package static func contents(of descriptor: Int32, maximumLength: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: maximumLength)
        var count = 0
        while count < maximumLength {
            let chunk = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress! + count, maximumLength - count) }
            if chunk < 0, errno == EINTR { continue }
            guard chunk >= 0 else { return nil }
            guard chunk > 0 else { break }
            count += chunk
        }
        return Data(buffer.prefix(count))
    }

    private static func failedOpen(_ error: Int32) -> RegularFileRead {
        switch error {
        // Auch ein ins Leere zeigender Symlink: Die Datei gibt es nicht.
        case ENOENT, ENOTDIR: .missing
        case ELOOP: .unreadable("Symlink-Schleife")
        default: .unreadable(unreadableText)
        }
    }
}
