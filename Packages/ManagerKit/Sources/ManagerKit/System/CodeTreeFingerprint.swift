import CryptoKit
import Darwin
import Foundation

/// Metadaten aller Einträge statt nur des Bundle-Siegels: liest keine Ressourceninhalte.
/// Physischer Baum, kein Betreten von Symlinks. Interne Links sind durch ihre Ziele im Baum abgedeckt;
/// externe/fehlende Ziele, Sonderdateien, Lesefehler und erreichte Grenzen verhindern jede Cache-Wiederverwendung.
/// ctime mit Nanosekunden erkennt auch gleich große Änderungen mit zurückgesetzter mtime.
/// `path` ist bereits kanonisch (`FileFingerprint.target`), damit interne Links vergleichbar sind.
struct CodeTreeFingerprint {
    static func read(at path: String, maximumEntries: Int = 500_000, timeout: Duration = .seconds(30)) -> String? {
        guard let argument = strdup(path) else { return nil }
        defer { free(argument) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [argument, nil]
        guard let stream = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return nil }
        defer { fts_close(stream) }
        let deadline = ContinuousClock.now + timeout
        var records: [String] = []
        let volumes = MountedVolume.current()
        while true {
            errno = 0
            guard let entry = fts_read(stream) else {
                guard errno == 0 else { return nil }
                break
            }
            guard records.count < maximumEntries, ContinuousClock.now < deadline else { return nil }
            switch Int32(entry.pointee.fts_info) {
            case FTS_DP: continue
            case FTS_D, FTS_F, FTS_SL, FTS_SLNONE: break
            default: return nil
            }
            let itemPath = String(cString: entry.pointee.fts_path)
            guard let info = entry.pointee.fts_statp else { return nil }
            let status = info.pointee
            if FileType.isSymbolicLink(status) {
                // Keine Metadaten externer Link-Ziele lesen (z. B. Automounter/Netzlaufwerk).
                guard let target = LocalPathResolver.resolve(itemPath, volumes: volumes, entry: { candidate in
                    guard candidate == path || path.hasPrefix(candidate + "/") || candidate.hasPrefix(path + "/")
                    else { return .unavailable }
                    return LocalPathResolver.entry(at: candidate)
                }), target.path.hasPrefix(path + "/") else { return nil }
                switch target.entry {
                case .directory, .regularFile: break
                default: return nil
                }
            }
            records.append(record(itemPath, status))
        }
        return digest(of: records)
    }

    /// Bundle-Einträge, deren Metadaten `stamp(at:)` neben dem Ziel selbst erfasst.
    static let stampedBundlePaths = [
        "Contents", "Contents/_CodeSignature", "Contents/_CodeSignature/CodeResources", "Contents/Info.plist",
        "Contents/MacOS", "Contents/Resources", "Contents/Frameworks",
    ]

    /// Billige Metadaten für Teilscans (#259) statt der vollständigen Traversierung von `read(at:)`: das Ziel selbst,
    /// bei Bundles zusätzlich `stampedBundlePaths` und alle direkten Einträge von `Contents/MacOS` – je ein `lstat`.
    /// Erkennt Austausch des Bundles, neue Signatur, ein ersetztes oder verändertes Hauptprogramm sowie hinzugefügte,
    /// entfernte oder umbenannte Einträge dieser Verzeichnisse. Eine in place überschriebene Datei tiefer im Baum
    /// erkennt erst `read(at:)`. `nil`, wenn etwas nicht lesbar ist oder `Contents/MacOS` mehr als
    /// `maximumExecutables` Einträge hat – dann zählt nur `read(at:)`.
    static func stamp(at path: String, maximumExecutables: Int = 64) -> String? {
        guard case .present(let status) = metadata(of: path) else { return nil }
        var records = [record(path, status)]
        guard FileType.isDirectory(status) else { return digest(of: records) }
        let executables = path + "/Contents/MacOS"
        var paths = stampedBundlePaths.map { path + "/" + $0 }
        if case .present(let directory) = metadata(of: executables), FileType.isDirectory(directory) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: executables),
                  names.count <= maximumExecutables else { return nil }
            paths += names.map { executables + "/" + $0 }
        }
        for itemPath in paths {
            switch metadata(of: itemPath) {
            case .present(let status): records.append(record(itemPath, status))
            case .missing: records.append("\(itemPath.utf8.count):\(itemPath):-")
            case nil: return nil
            }
        }
        return digest(of: records)
    }

    private enum Metadata {
        case present(stat)
        case missing
    }

    /// `lstat`-Ergebnis; `nil` bei anderen Fehlern als einem fehlenden Eintrag.
    private static func metadata(of path: String) -> Metadata? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return errno == ENOENT || errno == ENOTDIR ? .missing : nil }
        return .present(status)
    }

    // Length-prefix paths so filenames containing separators/newlines cannot alias another record.
    private static func record(_ itemPath: String, _ status: stat) -> String {
        "\(itemPath.utf8.count):\(itemPath):\(status.st_dev):\(status.st_ino):\(status.st_mode):\(status.st_uid):\(status.st_gid):\(status.st_size):\(status.st_flags):\(status.st_gen):\(status.st_mtimespec.tv_sec):\(status.st_mtimespec.tv_nsec):\(status.st_ctimespec.tv_sec):\(status.st_ctimespec.tv_nsec):\(status.st_birthtimespec.tv_sec):\(status.st_birthtimespec.tv_nsec)"
    }

    private static func digest(of records: [String]) -> String? {
        guard !records.isEmpty else { return nil }
        var hash = SHA256()
        for record in records.sorted() {
            hash.update(data: Data("\(record.utf8.count):\(record)".utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

