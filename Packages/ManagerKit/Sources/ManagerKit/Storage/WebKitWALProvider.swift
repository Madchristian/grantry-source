import Darwin
import Foundation
import GrantryShared

/// Ausufernde SQLite-Protokolle (WAL) in Websitedaten von WebKit (#226): Safari und andere WebKit-Apps
/// (`~/Library/Containers/*/Data/Library/WebKit`, `~/Library/WebKit/*`), darin `WebsiteData` und `WebsiteDataStore`
/// (Profile). Gemeldet wird eine `-wal`-Datei ab `minimumBytes` (1 GB), die mehr als `minimumRatio`-mal (100) so groß ist wie ihre
/// Datenbank; Titel ist die Website aus der Datei `origin` (`WebKitOrigin`). Nur Bericht: Grantry löscht nie selbst,
/// die Kategorie nennt den Weg über Safari. Ordner anderer Apps liest Grantry nur mit Festplattenvollzugriff – ohne ihn
/// fragte macOS je App nach „Daten anderer Apps“; die Kategorie meldet dann „Festplattenvollzugriff nötig“.
struct WebKitWALProvider: StorageCategoryProvider {
    /// Ordnerebenen unter `WebsiteData`/`WebsiteDataStore`; die tiefste WAL liegt in
    /// `WebsiteDataStore/<Profil>/Origins/<h>/<h>/IndexedDB/<h>/IndexedDB.sqlite3-wal`.
    static let maximumDepth = 7
    static let dataFolders = ["WebsiteData", "WebsiteDataStore"]
    /// So viele Ordner über der WAL wird die Datei `origin` gesucht (`<h>/<h>/IndexedDB/<h>/…`).
    static let originSearchDepth = 3
    static let unknownOrigin = "Unbekannte Website"

    let home: String
    /// Ob Ordner anderer Apps (`~/Library/Containers`) ohne Rückfrage lesbar sind: nur mit Festplattenvollzugriff.
    let canReadAppContainers: @Sendable () async -> Bool
    /// Schwellen der Regel; Tests setzen kleinere.
    var minimumBytes: Int64 = 1_000_000_000
    var minimumRatio: Int64 = 100

    var category: StorageCategory {
        StorageCategory(id: "webKitWAL", title: "Ausufernde Websitedaten", summary: """
                        Riesige Protokolldateien (WAL) einzelner Websites. Entfernen in Safari → Einstellungen → \
                        Datenschutz → Websitedaten verwalten, in anderen Apps über deren Einstellungen.
                        """, risk: .reportOnly, roots: [])
    }

    private var containers: String { home + "/Library/Containers" }

    func scan() async -> StorageCategoryReport {
        let readsContainers = await canReadAppContainers()
        var items: [StorageItem] = []
        var unreadablePaths: [String] = []
        for (app, root) in webKitRoots(includingContainers: readsContainers, unreadablePaths: &unreadablePaths) {
            for folder in Self.dataFolders.map({ root + "/" + $0 }) {
                guard !Task.isCancelled else { break }
                guard Self.isDirectory(folder, unreadablePaths: &unreadablePaths) else { continue }
                let result = Self.walFiles(under: folder)
                unreadablePaths += result.unreadablePaths
                items += result.files.compactMap { item($0.path, bytes: $0.bytes, app: app, in: folder) }
            }
        }
        let status: StorageCategoryStatus = !readsContainers ? .needsFullDiskAccess
            : unreadablePaths.isEmpty ? .available : .failed("Websitedaten konnten nicht vollständig gelesen werden.")
        if !readsContainers { unreadablePaths.append(containers) }
        return StorageCategoryReport(category: category, status: status,
                                     items: items.sorted { ($0.size.bytes ?? 0) > ($1.size.bytes ?? 0) },
                                     unreadablePaths: Array(Set(unreadablePaths)).sorted())
    }

    /// Fehlende Pfade und Symlinks sind keine Lesefehler; andere Metadatenfehler lassen eine Abdeckungslücke.
    private static func isDirectory(_ path: String, unreadablePaths: inout [String]) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno != ENOENT && errno != ENOTDIR { unreadablePaths.append(path) }
            return false
        }
        return FileType.isDirectory(info)
    }

    /// `WebKit`-Ordner je App: nicht sandboxte unter `~/Library/WebKit/<ID>`, sandboxte im Container. Ohne Symlinks.
    private func webKitRoots(includingContainers: Bool, unreadablePaths: inout [String]) -> [(app: String, root: String)] {
        func directories(in folder: String, _ relative: String) -> [(app: String, root: String)] {
            guard Self.isDirectory(folder, unreadablePaths: &unreadablePaths) else { return [] }
            let names: [String]
            do { names = try FileManager.default.contentsOfDirectory(atPath: folder) }
            catch {
                let error = error as NSError
                if error.domain != NSCocoaErrorDomain || error.code != NSFileReadNoSuchFileError {
                    unreadablePaths.append(folder)
                }
                return []
            }
            return names.sorted().filter { !RawPath.isHidden($0) }
                .map { (app: $0, root: folder + "/" + $0 + relative) }
                .filter { Self.isDirectory($0.root, unreadablePaths: &unreadablePaths) }
        }
        let own = directories(in: home + "/Library/WebKit", "")
        return includingContainers ? own + directories(in: containers, "/Data/Library/WebKit") : own
    }

    struct WALScan {
        var files: [(path: String, bytes: Int64)] = []
        var unreadablePaths: [String] = []
    }

    /// Alle `-wal`-Dateien unter `folder` mit belegter Größe; `fts` physisch, ohne andere Volumes, bis `maximumDepth`.
    static func walFiles(
        under folder: String,
        open: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> UnsafeMutablePointer<FTS>? = {
            fts_open($0, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)
        },
        read: (UnsafeMutablePointer<FTS>) -> UnsafeMutablePointer<FTSENT>? = { fts_read($0) }
    ) -> WALScan {
        guard let argument = strdup(folder) else { return WALScan(unreadablePaths: [folder]) }
        defer { free(argument) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [argument, nil]
        guard let stream = open(&arguments) else {
            return WALScan(unreadablePaths: errno == ENOENT || errno == ENOTDIR ? [] : [folder])
        }
        defer { fts_close(stream) }
        var result = WALScan()
        var count = 0
        while true {
            // Nur errno des aktuellen fts_read zählt; Metadaten-/Origin-Abfragen können es ebenfalls setzen.
            errno = 0
            guard let entry = read(stream) else {
                if errno != 0 && errno != ENOENT && errno != ENOTDIR { result.unreadablePaths.append(folder) }
                break
            }
            count += 1
            if count.isMultiple(of: FileSizeCalculator.checkInterval), Task.isCancelled { break }
            switch Int32(entry.pointee.fts_info) {
            case FTS_D where Int(entry.pointee.fts_level) >= maximumDepth:
                fts_set(stream, entry, FTS_SKIP)
            case FTS_DNR, FTS_ERR, FTS_NS:
                if entry.pointee.fts_errno != ENOENT && entry.pointee.fts_errno != ENOTDIR {
                    result.unreadablePaths.append(String(cString: entry.pointee.fts_path))
                }
            case FTS_F:
                let path = String(cString: entry.pointee.fts_path)
                guard path.hasSuffix("-wal") else { continue }
                result.files.append((path, Int64(entry.pointee.fts_statp.pointee.st_blocks) * 512))
            default:
                continue
            }
        }
        return result
    }

    /// Ein Ausreißer als Eintrag; `nil`, wenn die WAL die Regel nicht erfüllt.
    func item(_ path: String, bytes: Int64, app: String, in folder: String) -> StorageItem? {
        let databaseBytes = FileType.linkStatus(of: String(path.dropLast("-wal".count)))
            .map { FileType.isRegularFile($0) ? Int64($0.st_blocks) * 512 : 0 } ?? 0
        guard bytes >= minimumBytes, bytes > minimumRatio * databaseBytes else { return nil }
        let appName = app == "com.apple.Safari" ? "Safari" : DisplayText.singleLine(app)
        return StorageItem(id: path, title: Self.origin(of: path, in: folder) ?? Self.unknownOrigin, path: path, size: .bytes(bytes),
                           removal: .none, isPreselected: false,
                           detail: "\(appName) · Datenbank \(AppTexts.formattedSize(databaseBytes))")
    }

    /// Website aus der nächsten Datei `origin` über der WAL (höchstens `originSearchDepth` Ordner, nie über `folder`
    /// hinaus); ältere Ablage `WebsiteData/LocalStorage/https_example.com_0.localstorage-wal` aus dem Dateinamen.
    private static func origin(of path: String, in folder: String) -> String? {
        var directory = (path as NSString).deletingLastPathComponent
        for _ in 0..<originSearchDepth where directory.hasPrefix(folder + "/") {
            if let title = WebKitOrigin.title(fromFileAt: directory + "/origin") { return title }
            directory = (directory as NSString).deletingLastPathComponent
        }
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let parts = name.split(separator: "_", omittingEmptySubsequences: false)
        guard path.hasSuffix(".localstorage-wal"), parts.count >= 3 else { return nil }
        let host = parts.dropFirst().dropLast().joined(separator: "_")
        return host.isEmpty ? nil : DisplayText.singleLine(host)
    }
}
