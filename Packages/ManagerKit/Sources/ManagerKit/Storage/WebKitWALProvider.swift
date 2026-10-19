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
        for (app, root) in webKitRoots(includingContainers: readsContainers) {
            for folder in Self.dataFolders.map({ root + "/" + $0 }) where FileIdentity.of(folder)?.type == .directory {
                guard !Task.isCancelled else { break }
                items += Self.walFiles(under: folder).compactMap { item($0.path, bytes: $0.bytes, app: app, in: folder) }
            }
        }
        return StorageCategoryReport(category: category, status: readsContainers ? .available : .needsFullDiskAccess,
                                     items: items.sorted { ($0.size.bytes ?? 0) > ($1.size.bytes ?? 0) },
                                     unreadablePaths: readsContainers ? [] : [containers])
    }

    /// `WebKit`-Ordner je App: nicht sandboxte unter `~/Library/WebKit/<ID>`, sandboxte im Container. Ohne Symlinks.
    private func webKitRoots(includingContainers: Bool) -> [(app: String, root: String)] {
        func directories(in folder: String, _ relative: String) -> [(app: String, root: String)] {
            StorageCatalog.entries(of: folder)
                .map { (app: ($0 as NSString).lastPathComponent, root: $0 + relative) }
                .filter { FileIdentity.of($0.root)?.type == .directory }
        }
        let own = directories(in: home + "/Library/WebKit", "")
        return includingContainers ? own + directories(in: containers, "/Data/Library/WebKit") : own
    }

    /// Alle `-wal`-Dateien unter `folder` mit belegter Größe; `fts` physisch, ohne andere Volumes, bis `maximumDepth`.
    static func walFiles(under folder: String) -> [(path: String, bytes: Int64)] {
        guard let argument = strdup(folder) else { return [] }
        defer { free(argument) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [argument, nil]
        guard let stream = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return [] }
        defer { fts_close(stream) }
        var found: [(path: String, bytes: Int64)] = []
        var count = 0
        while let entry = fts_read(stream) {
            count += 1
            if count.isMultiple(of: FileSizeCalculator.checkInterval), Task.isCancelled { break }
            switch Int32(entry.pointee.fts_info) {
            case FTS_D where Int(entry.pointee.fts_level) >= maximumDepth:
                fts_set(stream, entry, FTS_SKIP)
            case FTS_F:
                let path = String(cString: entry.pointee.fts_path)
                guard path.hasSuffix("-wal") else { continue }
                found.append((path, Int64(entry.pointee.fts_statp.pointee.st_blocks) * 512))
            default:
                continue
            }
        }
        return found
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
