import Darwin
import Foundation

/// Ergebnis des Lesens einer Agenten-Konfiguration (`RegularFileRead`).
typealias AgentConfigRead = RegularFileRead

/// Liest Konfigurationsdateien gefahrlos (Spec §3, Härtungen wie #98/#103): nur reguläre Dateien (keine FIFO), höchstens
/// `maximumFileSize` Bytes, und eine Datei im Benutzerordner nur, wenn auch ihr aufgelöstes Ziel dort liegt – ein
/// Symlink (oder `..`) aus dem Home heraus wird nicht gelesen.
///
/// Ohne Rennen zwischen Prüfung und Lesen: Die Datei wird zuerst geöffnet (`O_NONBLOCK` – eine FIFO blockiert nicht,
/// `O_NOCTTY`), Art, Größe und Rechte liefert `fstat` am Deskriptor, das aufgelöste Ziel `F_GETPATH` am Deskriptor, und
/// gelesen wird vom selben Deskriptor. Ein Austausch der Datei nach der Prüfung ändert nichts mehr.
enum AgentConfigReader {
    static let maximumFileSize = 5 * 1024 * 1024
    /// Grund für Lesefehler ohne nähere Ursache (`unreadable`).
    static let unreadableText = RegularFileReader.unreadableText

    /// Benutzerordner, einmal aufgelöst – pro Scan wiederverwendbar.
    struct Home: Sendable {
        let path: String
        /// `nil`, wenn der Ordner fehlt oder sich nicht auflösen lässt; dann gilt jede Datei darin als nicht lesbar
        /// (fail-closed) – ohne aufgelöstes Home ließe sich ein Symlink hinaus nicht erkennen.
        let canonicalPath: String?

        /// Aufgelöst wie die gelesenen Dateien (`F_GETPATH` am geöffneten Ordner), damit beide Seiten dieselbe
        /// Schreibweise haben – `realpath` behielte etwa `/System/Volumes/Data/…`, `F_GETPATH` nicht. Fallback `realpath`.
        init(_ path: String) {
            self.init(path: path, canonicalPath: AgentConfigReader.openedDirectoryPath(path) ?? AgentConfigReader.canonicalPath(path))
        }

        init(path: String, canonicalPath: String?) {
            self.path = path
            self.canonicalPath = canonicalPath
        }

        /// `true`, wenn `path` wörtlich im Home liegt (wie angegeben oder aufgelöst).
        func contains(literal path: String) -> Bool {
            AgentConfigReader.isInside(path, self.path) || canonicalPath.map { AgentConfigReader.isInside(path, $0) } == true
        }
    }

    /// Liest `path` über `RegularFileReader`; liegt der Pfad wörtlich im Home, muss auch sein aufgelöstes Ziel dort liegen.
    static func read(path: String, home: Home, maximumSize: Int = maximumFileSize) -> AgentConfigRead {
        RegularFileReader.read(atPath: path, maximumSize: maximumSize) { descriptor in
            guard home.contains(literal: path) else { return nil }
            guard let canonicalHome = home.canonicalPath, let target = resolvedPath(of: descriptor) else { return unreadableText }
            return isInside(target, canonicalHome) ? nil : "verweist aus dem Benutzerordner heraus"
        }
    }

    /// „größer als 5 MB“ (`RegularFileReader.sizeLimitText`).
    static func sizeLimitText(_ maximumSize: Int) -> String {
        RegularFileReader.sizeLimitText(maximumSize)
    }

    /// Pfad des Ordners `path`, geöffnet und per `F_GETPATH` aufgelöst; `nil`, wenn er sich nicht öffnen lässt.
    private static func openedDirectoryPath(_ path: String) -> String? {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        return resolvedPath(of: descriptor)
    }

    /// Pfad der geöffneten Datei (`F_GETPATH`, Symlinks und `..` aufgelöst).
    private static func resolvedPath(of descriptor: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// Höchstens `maximumLength` Bytes vom Deskriptor (`RegularFileReader.contents`).
    static func contents(of descriptor: Int32, maximumLength: Int) -> Data? {
        RegularFileReader.contents(of: descriptor, maximumLength: maximumLength)
    }

    /// `realpath`; `nil`, wenn der Pfad (oder ein Link-Ziel) fehlt.
    static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func isInside(_ path: String, _ directory: String) -> Bool {
        path.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
    }
}
