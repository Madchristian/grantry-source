import Darwin
import Foundation

/// Ergebnis des Auflistens eines Verzeichnisses (`DirectoryReader`).
package enum DirectoryRead: Equatable, Sendable {
    /// Das Verzeichnis gibt es nachweislich nicht (`ENOENT`, `ENOTDIR`).
    case missing
    /// Namen der Einträge ohne `.` und `..`, unsortiert.
    case entries([String])
    /// Vorhanden oder nicht feststellbar, aber nicht auflistbar (etwa `EACCES` – auch auf einem übergeordneten
    /// Verzeichnis); Grund im Klartext.
    case unreadable(String)
}

/// Listet Verzeichnisse auf, ohne Fehler zu „gibt es nicht“ zu verschlucken: Nur `ENOENT` und `ENOTDIR` gelten als
/// fehlend. Alles andere – fehlende Rechte auf dem Verzeichnis oder einem übergeordneten, E/A-Fehler beim Lesen – ist
/// `unreadable`, damit Aufrufer fail-closed entscheiden können (#138, #139). `FileManager.fileExists(atPath:)` liefert
/// dagegen auch bei `EACCES` `false`.
package enum DirectoryReader {
    package static func entries(atPath path: String) -> DirectoryRead {
        guard let directory = opendir(path) else {
            let error = errno
            return error == ENOENT || error == ENOTDIR ? .missing : .unreadable(String(cString: strerror(error)))
        }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                let error = errno
                return error == 0 ? .entries(names) : .unreadable(String(cString: strerror(error)))
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { buffer in
                String(decoding: buffer.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != ".", name != ".." { names.append(name) }
        }
    }
}
