import Darwin
import Foundation

/// Ein Verzeichnis, Komponente für Komponente ab `/` ohne Symlink-Auflösung geöffnet und als Deskriptor gehalten.
///
/// Jede Komponente wird mit `O_DIRECTORY | O_NOFOLLOW` relativ zur vorigen geöffnet: Ein Symlink irgendwo in der Kette
/// lässt das scheitern (`ELOOP`), statt ihm zu folgen. Alle späteren Zugriffe relativ zu `descriptor` (`openat`,
/// `fstatat`, `renameatx_np`, `unlinkat`) treffen genau dieses Verzeichnisobjekt – auch wenn sein Pfad inzwischen auf
/// etwas anderes zeigt, etwa nach einem Austausch gegen einen Symlink. Schließt den Deskriptor beim Freigeben.
///
/// `path` muss der bereits als vertrauenswürdig feststehende, symlinkfreie Pfad sein (nicht erst jetzt aufgelöst), sonst
/// würde ein zwischenzeitlich eingehängter Symlink mit aufgelöst statt abgelehnt.
public final class BoundDirectory: Sendable {
    public let descriptor: Int32
    /// Der geöffnete Pfad, nur für Meldungen.
    public let path: String

    /// Öffnet `path`. `inspect` erhält jede geöffnete Komponente (ihren Deskriptor und Pfad, beginnend mit `/`) und kann
    /// mit einem eigenen Fehler abbrechen – etwa, wenn ein Ordner einem fremden Benutzer gehört. Scheitert ein `open`,
    /// wird ein `POSIXError` mit dessen `errno` geworfen: `ELOOP` für einen Symlink (auch wo macOS `ENOTDIR` meldet),
    /// `ENOENT`/`ENOTDIR`, wenn die Komponente fehlt bzw. kein Ordner ist.
    ///
    /// `path` muss absolut sein und darf keine `.`- oder `..`-Komponenten enthalten (`EINVAL`): Ein relativer Pfad
    /// hinge vom Arbeitsverzeichnis ab, `..` würde die Kette der geprüften Ordner verlassen. Mehrfache Schrägstriche
    /// zählen nicht als Komponente.
    ///
    /// Mit `creationMode` wird eine fehlende Komponente mit diesen Rechten angelegt (`mkdirat` relativ zum bereits
    /// geöffneten und geprüften Elternordner) und dann ebenso ohne Symlink-Auflösung geöffnet und geprüft. Legt ein
    /// anderer Prozess sie zwischenzeitlich an, gilt seine – sie durchläuft dieselben Prüfungen.
    public init(
        path: String,
        creatingMissingWith creationMode: mode_t? = nil,
        inspecting inspect: (_ descriptor: Int32, _ path: String) throws -> Void = { _, _ in }
    ) throws {
        let components = try Self.components(of: path)
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.posixError() }
        var current = "/"
        do { try inspect(descriptor, current) } catch { close(descriptor); throw error }
        for component in components {
            let next = Self.openComponent(component, in: descriptor, creatingMissingWith: creationMode)
            guard next >= 0 else {
                // macOS meldet für einen Symlink mit `O_DIRECTORY | O_NOFOLLOW` `ENOTDIR`, nicht `ELOOP`.
                let code = errno
                let failure = code == ENOTDIR && Self.isSymbolicLink(component, in: descriptor) ? ELOOP : code
                close(descriptor)
                throw Self.posixError(failure)
            }
            close(descriptor)
            descriptor = next
            current = current == "/" ? "/" + component : current + "/" + component
            do { try inspect(descriptor, current) } catch { close(descriptor); throw error }
        }
        self.descriptor = descriptor
        self.path = current
    }

    deinit { close(descriptor) }

    /// Öffnet `name` in `directory` als Ordner ohne Symlink-Auflösung; fehlt er und ist `creationMode` gesetzt, wird er
    /// zuvor angelegt. Bei Fehlschlag `-1` mit gesetztem `errno`.
    private static func openComponent(_ name: String, in directory: Int32, creatingMissingWith creationMode: mode_t?) -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let descriptor = openat(directory, name, flags)
        guard descriptor < 0, errno == ENOENT, let creationMode else { return descriptor }
        guard mkdirat(directory, name, creationMode) == 0 || errno == EEXIST else { return -1 }
        return openat(directory, name, flags)
    }

    /// Die Komponenten eines absoluten Pfads ohne `.`/`..`; sonst `POSIXError(.EINVAL)`.
    private static func components(of path: String) throws -> [String] {
        guard path.hasPrefix("/") else { throw POSIXError(.EINVAL) }
        let components = path.split(separator: "/").map(String.init)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else { throw POSIXError(.EINVAL) }
        return components
    }

    private static func isSymbolicLink(_ name: String, in directory: Int32) -> Bool {
        var info = stat()
        return fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    /// `POSIXError` zu `code` (standardmäßig das aktuelle `errno`).
    public static func posixError(_ code: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
