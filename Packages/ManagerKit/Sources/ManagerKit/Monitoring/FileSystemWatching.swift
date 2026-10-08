import CoreServices
import Foundation
import GrantryShared
import os
import Synchronization

/// Beobachtet Pfade im Dateisystem.
public protocol FileSystemWatching: Sendable {
    /// Liefert bei jeder Änderung unter den Verzeichnissen `paths` oder an den Dateien `files` ein Signal mit dem
    /// auslösenden Pfad (geänderte Datei bzw. gemeldetes Verzeichnis). Dateien zählen auch, wenn sie beim Start fehlen:
    /// Ihr Erscheinen und spätere Änderungen werden gemeldet.
    ///
    /// `shallowPaths`: App-Ordner (`/Applications`). Unter ihnen zählen nur Ereignisse bis `WatchScope.shallowDepth`
    /// Ebenen, und auch die nur, wenn sich dadurch die App-Bundles darin geändert haben (`AppFolderFingerprint`):
    /// Dateien, die ein Hersteller in seinen Unterordner schreibt, lösen nichts aus. Ein beim Start fehlender App-Ordner
    /// wird nicht beobachtet.
    func changes(in paths: [String], files: [String], shallowPaths: [String]) -> AsyncStream<String>
}

extension FileSystemWatching {
    /// Verzeichnisse und Dateien, nichts flach.
    public func changes(in paths: [String], files: [String]) -> AsyncStream<String> {
        changes(in: paths, files: files, shallowPaths: [])
    }

    /// Nur Verzeichnisse.
    public func changes(in paths: [String]) -> AsyncStream<String> {
        changes(in: paths, files: [], shallowPaths: [])
    }
}

/// `FileSystemWatching` über FSEvents. Beendet der Konsument den Strom, wird der FSEvents-Stream gestoppt und
/// freigegeben.
///
/// Ohne Datei-Ereignisse: FSEvents meldet nur das Verzeichnis, in dem sich etwas geändert hat – das genügt für die
/// beobachteten Verzeichnisse und hält den Verkehr klein. Ein Pfad, der beim Start fehlt (etwa `~/Library/LaunchAgents`),
/// wird über seinen nächsten existierenden Elternordner beobachtet (siehe `WatchScope`). Dateien (etwa
/// `com.apple.SoftwareUpdate.plist`) werden – auch wenn sie noch fehlen – über ihren Ordner beobachtet und per
/// Fingerabdruck gefiltert (siehe `FileStamps`), damit Änderungen an Nachbardateien nichts auslösen. App-Ordner filtert
/// der Fingerabdruck ihrer Bundles (siehe `AppFolderStamps`). Ausgewählte Dateien filtert statt des Fingerabdrucks ein
/// Inhalts-Stempel (`contentStamps`).
///
/// Liegt eine Wurzel unter einer anderen, beobachtet FSEvents nur die äußere (`WatchScope.roots`). Eine Datei direkt im
/// Home (`~/.claude.json`) macht so den ganzen Home-Baum zur Wurzel: FSEvents liefert dann Ereignisse aus dem ganzen
/// Home, die `WatchScope` und die Stempel herausfiltern.
public struct FSEventsWatcher: FileSystemWatching {
    /// Inhalts-Stempel einer beobachteten Datei: Ein Signal kommt nur, wenn sich der Stempel ändert (`nil` = fehlt).
    public typealias ContentStamp = @Sendable () -> Int?

    private let latency: TimeInterval
    private let contentStamps: [String: ContentStamp]

    /// - Parameters:
    ///   - latency: Zeit, die FSEvents Ereignisse sammelt, bevor es sie meldet.
    ///   - contentStamps: Dateien (wie in `files` angegeben), deren Änderung nicht am Fingerabdruck, sondern am
    ///     Inhalts-Stempel gemessen wird – etwa Agenten-Konfigurationen, die ihr Tool laufend neu schreibt.
    public init(latency: TimeInterval = 0.5, contentStamps: [String: ContentStamp] = [:]) {
        self.latency = latency
        self.contentStamps = contentStamps
    }

    /// Ohne beobachtbaren Pfad oder wenn FSEvents scheitert, endet der Strom sofort.
    public func changes(in paths: [String], files: [String], shallowPaths: [String]) -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let scope = WatchScope(paths: paths, files: files, shallowPaths: shallowPaths)
        guard !scope.roots.isEmpty,
              let handle = EventStreamHandle(
                  scope: scope, contentStamps: contentStamps, latency: latency, continuation: continuation
              )
        else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { _ in handle.stop() }
        return stream
    }
}

/// Was FSEvents beobachten soll (`roots`: existierende Verzeichnisse) und welche gemeldeten Verzeichnisse zählen.
///
/// FSEvents meldet ohne Datei-Ereignisse das Verzeichnis einer Änderung: Für eine Datei in `~/Library/LaunchAgents`
/// also `~/Library/LaunchAgents`, für das Anlegen dieses Ordners `~/Library`. Alle Pfade sind kanonisch (Symlinks
/// aufgelöst), wie FSEvents sie meldet. Die Wurzel `/` wird nie beobachtet: Ein Pfad, dessen nächster existierender
/// Vorfahre `/` ist, wird übersprungen und protokolliert.
///
/// Dateien sind ausdrücklich als solche angegeben (`isFile`) und werden über ihren Ordner beobachtet – fehlt der, über
/// dessen nächsten existierenden Vorfahren. Ob die Datei beim Start existiert, spielt keine Rolle. Ein Ereignis zählt für
/// sie nicht über `contains(_:)`, sondern liefert sie über `files(reportedIn:)` – ob sie sich wirklich geändert hat
/// (auch: erschienen ist), entscheidet ihr Stempel (`FileStamps`).
struct WatchScope: Sendable, Equatable {
    /// Ein beobachteter Pfad (`target`) und das existierende Verzeichnis, über das er beobachtet wird (`root`).
    struct Entry: Sendable, Equatable {
        /// Pfad, wie er angegeben wurde (nicht kanonisch).
        let source: String
        let root: String
        let target: String
        /// `target` ist eine Datei (in `root` oder darunter).
        var isFile = false
        /// Höchstzahl Pfadbestandteile unterhalb von `target`, deren Ereignisse zählen; `nil` = alle.
        var maximumDepth: Int?

        /// Ordner, in dem `target` liegt.
        var directory: String { URL(filePath: target).deletingLastPathComponent().path }
    }

    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "watcher")

    let entries: [Entry]

    /// Tiefe flach beobachteter Ordner: `/Applications/X.app/Contents` (2) und `/Applications/Ordner/X.app/Contents` (3)
    /// zählen, Schreibzugriffe tief in einem Bundle nicht.
    static let shallowDepth = 3

    /// - Parameters:
    ///   - paths: Verzeichnisse; beobachtet wird alles darunter.
    ///   - files: Dateien; beobachtet wird nur die Datei selbst.
    ///   - shallowPaths: Verzeichnisse, unter denen nur Ereignisse bis `shallowDepth` Ebenen zählen. Ein fehlendes wird
    ///     nicht beobachtet: Über den Elternordner (für `~/Applications` der Benutzerordner) löste sonst jede Änderung
    ///     dort einen Scan aus.
    init(paths: [String], files: [String] = [], shallowPaths: [String] = []) {
        let shallow = shallowPaths.compactMap { path -> Entry? in
            guard var entry = Self.resolve(path, isFile: false), entry.root == entry.target else { return nil }
            entry.maximumDepth = Self.shallowDepth
            return entry
        }
        entries = paths.compactMap { Self.resolve($0, isFile: false) } + shallow
            + files.compactMap { Self.resolve($0, isFile: true) }
    }

    /// Zu beobachtende Verzeichnisse, ohne Dubletten und ohne Verzeichnisse unter einem anderen (FSEvents meldet deren
    /// Ereignisse über das äußere), in Reihenfolge der Pfade.
    var roots: [String] {
        let unique = entries.reduce(into: [String]()) { roots, entry in
            if !roots.contains(entry.root) { roots.append(entry.root) }
        }
        return unique.filter { root in
            !unique.contains { other in other != root && Self.isPath(root, atOrBelow: other) }
        }
    }

    /// `true`, wenn das gemeldete Verzeichnis ein beobachteter Pfad ist oder darunter liegt – oder, solange dieser Pfad
    /// noch fehlt, ein Vorfahre innerhalb des beobachteten Verzeichnisses: Dort könnte er gerade angelegt worden sein.
    /// Existiert der Pfad, zählen nur noch Ereignisse an ihm selbst und darunter. Dateien und App-Ordner zählen hier
    /// nie, sie filtert ihr Fingerabdruck (`files(reportedIn:)`, `appFolders(reportedIn:)`).
    func contains(
        _ eventPath: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        let path = Self.normalized(eventPath)
        return entries.contains { entry in
            guard !entry.isFile, entry.maximumDepth == nil else { return false }
            return (Self.isPath(path, atOrBelow: entry.target)
                    && Self.depth(of: path, below: entry.target) <= (entry.maximumDepth ?? .max))
                || (Self.isPath(entry.target, atOrBelow: path)
                    && Self.isPath(path, atOrBelow: entry.root)
                    && !fileExists(entry.target))
        }
    }

    /// Beobachtete Dateien, deren Ordner das gemeldete Verzeichnis ist oder darunter liegt. Ein gemeldeter Vorfahre
    /// zählt mit: FSEvents meldet bei `MustScanSubDirs` oder verworfenen Ereignissen einen Vorfahren, und fehlt der Ordner
    /// noch, entsteht er dort.
    func files(reportedIn eventPath: String) -> [String] {
        let path = Self.normalized(eventPath)
        return entries.filter { $0.isFile && Self.isPath($0.directory, atOrBelow: path) }.map(\.target)
    }

    /// Alle beobachteten Dateien.
    var fileTargets: [String] { entries.filter(\.isFile).map(\.target) }

    /// App-Ordner, in denen das gemeldete Verzeichnis höchstens `shallowDepth` Ebenen tief liegt – oder deren Vorfahre
    /// es ist (`MustScanSubDirs`). Ob sich dort ein Bundle geändert hat, entscheidet `AppFolderStamps`.
    func appFolders(reportedIn eventPath: String) -> [String] {
        let path = Self.normalized(eventPath)
        return entries.filter { entry in
            guard !entry.isFile, let maximumDepth = entry.maximumDepth else { return false }
            return (Self.isPath(path, atOrBelow: entry.target) && Self.depth(of: path, below: entry.target) <= maximumDepth)
                || Self.isPath(entry.target, atOrBelow: path)
        }.map(\.target)
    }

    /// Alle beobachteten App-Ordner.
    var appFolderTargets: [String] { entries.filter { !$0.isFile && $0.maximumDepth != nil }.map(\.target) }

    /// Kanonischer Pfad eines existierenden Eintrags (`realpath(3)`), sonst `nil`.
    static func canonicalPath(of path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Gemeldeter Pfad ohne abschließenden Schrägstrich (außer bei `/`).
    private static func normalized(_ eventPath: String) -> String {
        eventPath.count > 1 && eventPath.hasSuffix("/") ? String(eventPath.dropLast()) : eventPath
    }

    /// `true`, wenn `path` gleich `ancestor` ist oder darunter liegt.
    private static func isPath(_ path: String, atOrBelow ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor + "/")
    }

    /// Zahl der Pfadbestandteile von `path` unterhalb von `ancestor` (`path` liegt am oder unter `ancestor`).
    private static func depth(of path: String, below ancestor: String) -> Int {
        path == ancestor ? 0 : path.dropFirst(ancestor.count + 1).split(separator: "/").count
    }

    /// Nächster existierender Vorfahre (kanonisch) und der kanonische Zielpfad darunter; eine Datei über ihren Ordner.
    private static func resolve(_ path: String, isFile: Bool) -> Entry? {
        guard let entry = unguardedEntry(for: path, isFile: isFile) else { return nil }
        guard entry.root != "/" else {
            logger.error("Pfad wird nicht beobachtet, dafür wäre die Wurzel „/“ zu beobachten: \(path, privacy: .public)")
            return nil
        }
        return entry
    }

    /// Beobachtet wird das nächste existierende Verzeichnis: bei einer Datei ab ihrem Ordner gesucht, sonst ab dem
    /// Pfad selbst. Der Dateiname wird nicht aufgelöst – sie kann fehlen oder später ersetzt werden.
    private static func unguardedEntry(for path: String, isFile: Bool) -> Entry? {
        let url = URL(filePath: path).standardized
        var existing = isFile ? url.deletingLastPathComponent() : url
        var missing = isFile ? [url.lastPathComponent] : []
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
            missing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        guard let canonical = canonicalPath(of: existing.path) else { return nil }
        let target = missing.reduce(URL(filePath: canonical)) { $0.appending(path: $1) }.path
        return Entry(source: path, root: canonical, target: target, isFile: isFile)
    }
}

/// Fingerabdrücke je Pfad; `update` meldet, welche sich seit dem letzten Blick geändert haben. So lösen Änderungen
/// neben dem Beobachteten nichts aus.
final class PathStamps<Stamp: Equatable & Sendable>: Sendable {
    private let read: @Sendable (String) -> Stamp
    private let stamps: Mutex<[String: Stamp]>

    init(paths: [String], read: @escaping @Sendable (String) -> Stamp) {
        self.read = read
        stamps = Mutex(Dictionary(paths.map { ($0, read($0)) }, uniquingKeysWith: { first, _ in first }))
    }

    /// Liest die Fingerabdrücke von `paths` neu; liefert die geänderten Pfade, sortiert. Gelesen wird außerhalb der
    /// Sperre: `read` darf teuer sein (Inhalts-Stempel) und eigene Sperren nehmen. Nur seriell aufrufen – zwei
    /// gleichzeitige Aufrufe könnten einen älteren Stand zuletzt speichern; die Queue des FSEvents-Streams garantiert
    /// das.
    func update(_ paths: Set<String>) -> [String] {
        let current = paths.sorted().map { ($0, read($0)) }
        return stamps.withLock { stamps in
            current.filter { path, stamp in
                defer { stamps[path] = stamp }
                return stamps[path] != .some(stamp)
            }.map(\.0)
        }
    }
}

/// Stempel einer beobachteten Datei: Fingerabdruck oder – für ausgewählte Dateien – Inhalts-Stempel; `nil` = fehlt.
enum FileStamp: Equatable, Sendable {
    case fingerprint(FileFingerprint?)
    case content(Int?)
}

/// Stempel beobachteter Dateien, auch ihr Erscheinen oder Verschwinden.
typealias FileStamps = PathStamps<FileStamp>

extension PathStamps where Stamp == FileStamp {
    /// - Parameter content: Inhalts-Stempel je **Ziel**pfad (`WatchScope.fileTargets`); übrige Dateien per Fingerabdruck.
    convenience init(paths: [String], content: [String: FSEventsWatcher.ContentStamp] = [:]) {
        self.init(paths: paths, read: { path in
            content[path].map { .content($0()) } ?? .fingerprint(FileFingerprint(of: path))
        })
    }
}

/// Fingerabdrücke der App-Ordner (`AppFolderFingerprint`).
typealias AppFolderStamps = PathStamps<AppFolderFingerprint>

extension PathStamps where Stamp == AppFolderFingerprint {
    convenience init(folders: [String]) {
        self.init(paths: folders, read: AppFolderFingerprint.init(folder:))
    }
}

/// Stand der App-Bundles in einem App-Ordner, so wie das Inventar sie findet (`AppInventorySource.scan(root:)`):
/// Pfade (samt Symlink-Zielen), je Bundle dessen `FileFingerprint` (Inode, Siegel bzw. `Info.plist`) und die nicht
/// lesbaren Ordner. Hinzufügen, Entfernen, Umbenennen, Austausch und In-Place-Update eines Bundles ändern ihn, andere
/// Dateien – etwa Protokolle, die ein Hersteller in seinen Unterordner schreibt – nicht.
struct AppFolderFingerprint: Equatable, Sendable {
    private let bundles: [AppInventorySource.Entry: FileFingerprint?]
    private let unreadableFolders: [String]

    init(folder: String) {
        let scan = AppInventorySource.scan(root: folder)
        bundles = Dictionary(scan.entries.map { entry in
            switch entry {
            case .bundle(let path): (entry, FileFingerprint(of: path))
            case .symlink: (entry, nil)
            }
        }, uniquingKeysWith: { first, _ in first })
        unreadableFolders = scan.unreadableFolders
    }
}

/// Hält Continuation und Filter für den C-Callback; wird als `info`-Zeiger an FSEvents übergeben.
final class ContinuationBox: Sendable {
    let continuation: AsyncStream<String>.Continuation
    let scope: WatchScope
    private let stamps: FileStamps
    private let appFolderStamps: AppFolderStamps

    /// - Parameter contentStamps: Inhalts-Stempel je Datei, wie in `scope` angegeben (`WatchScope.Entry.source`); die
    ///   Box ordnet sie den kanonischen Zielen zu.
    init(
        _ continuation: AsyncStream<String>.Continuation, scope: WatchScope,
        contentStamps: [String: FSEventsWatcher.ContentStamp] = [:]
    ) {
        self.continuation = continuation
        self.scope = scope
        var byTarget: [String: FSEventsWatcher.ContentStamp] = [:]
        for entry in scope.entries where entry.isFile {
            if let stamp = contentStamps[entry.source] { byTarget[entry.target] = stamp }
        }
        stamps = FileStamps(paths: scope.fileTargets, content: byTarget)
        appFolderStamps = AppFolderStamps(folders: scope.appFolderTargets)
    }

    /// Meldet ein Signal, wenn sich eine beobachtete Datei unter einem gemeldeten Verzeichnis geändert hat, die Bundles
    /// eines gemeldeten App-Ordners sich geändert haben oder mindestens ein gemeldetes Verzeichnis im beobachteten
    /// Bereich liegt – mit der ersten geänderten Datei, sonst dem ersten gemeldeten Verzeichnis im geänderten App-Ordner,
    /// sonst dem ersten passenden Verzeichnis. Liefert den gemeldeten Pfad, ohne Signal `nil`.
    @discardableResult
    func receive(_ eventPaths: [String]) -> String? {
        let files = Set(eventPaths.flatMap(scope.files(reportedIn:)))
        let folders = Set(eventPaths.flatMap(scope.appFolders(reportedIn:)))
        // Fingerabdrücke immer auffrischen, damit eine spätere Meldung nicht eine längst erfasste Änderung meldet.
        let changedFile = files.isEmpty ? nil : stamps.update(files).first
        let changedFolder = folders.isEmpty ? nil : appFolderStamps.update(folders).first
        let folderEvent = changedFolder.flatMap { folder in
            eventPaths.first { scope.appFolders(reportedIn: $0).contains(folder) }
        }
        guard let path = changedFile ?? folderEvent ?? eventPaths.first(where: { scope.contains($0) }) else { return nil }
        continuation.yield(path)
        return path
    }
}

/// Besitzt einen laufenden FSEvents-Stream samt der von ihm referenzierten `ContinuationBox`.
///
/// `@unchecked Sendable`, weil `FSEventStreamRef` ein nicht-`Sendable` Zeiger ist. Sicher, weil der Zeiger nach
/// `init` unveränderlich ist und `stop()` (vom Termination-Handler genau einmal aufgerufen) Stoppen, Invalidieren und
/// Freigeben auf der Dispatch-Queue des Streams ausführt – seriell zu allen Callbacks. Danach ruft FSEvents den
/// Callback nicht mehr auf, erst dann wird die Box freigegeben.
private final class EventStreamHandle: @unchecked Sendable {
    /// Bewusst ohne `kFSEventStreamCreateFlagFileEvents`: Verzeichnis-Ereignisse genügen (siehe `WatchScope`).
    private static let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)

    private let stream: FSEventStreamRef
    private let queue = DispatchQueue(label: "\(GrantryIdentity.logSubsystem).FSEventsWatcher")
    private let box: Unmanaged<ContinuationBox>

    init?(
        scope: WatchScope, contentStamps: [String: FSEventsWatcher.ContentStamp], latency: TimeInterval,
        continuation: AsyncStream<String>.Continuation
    ) {
        let box = Unmanaged.passRetained(ContinuationBox(continuation, scope: scope, contentStamps: contentStamps))
        var context = FSEventStreamContext(
            version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        // Ohne `kFSEventStreamCreateFlagUseCFTypes` ist `eventPaths` ein C-Array von C-Strings.
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let cPaths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            let paths = (0..<count).map { String(cString: cPaths[$0]) }
            Unmanaged<ContinuationBox>.fromOpaque(info).takeUnretainedValue().receive(paths)
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, scope.roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, Self.flags
        ) else {
            box.release()
            return nil
        }
        self.stream = stream
        self.box = box
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            box.release()
            return nil
        }
    }

    func stop() {
        queue.async { self.tearDown() }
    }

    private func tearDown() {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        box.release()
    }
}
