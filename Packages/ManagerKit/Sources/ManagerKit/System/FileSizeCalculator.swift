import Darwin
import Foundation
import Synchronization

/// Belegter Speicher eines Pfads.
public enum FileSize: Hashable, Sendable {
    /// Vollständig gezählt.
    case bytes(Int64)
    /// Teile ließen sich nicht lesen (fehlende Rechte, z. B. ohne Festplattenvollzugriff) – eine Zahl wäre zu klein.
    case unreadable
    /// Nicht gemessen: Frist abgelaufen, abgebrochen oder Pfad fehlt.
    case unknown

    /// Bytes, wenn vollständig gezählt.
    public var bytes: Int64? {
        if case .bytes(let value) = self { value } else { nil }
    }
}

/// Größe und jüngste Änderung eines Pfads, in einem Durchgang ermittelt (Agenten-Arbeitsordner, #229).
public struct FileTreeSummary: Hashable, Sendable {
    public let size: FileSize
    /// Jüngstes Änderungsdatum (`st_mtime`) aller Einträge samt Wurzel, Symlinks mit ihrem eigenen; `nil`, wenn die
    /// Größe nicht vollständig gezählt ist – dann ist auch die jüngste Änderung nicht belegt.
    public let newestModification: Date?

    public init(size: FileSize, newestModification: Date?) {
        self.size = size
        self.newestModification = newestModification
    }
}

/// Belegter Speicher einer Datei oder eines Ordners.
public protocol FileSizeMeasuring: Sendable {
    /// Summe der belegten Blöcke aller regulären Dateien; `nil`, wenn der Pfad fehlt, Teile nicht lesbar sind oder die
    /// Frist abläuft.
    func allocatedSize(of path: String) -> Int64?
    /// Wie `allocatedSize(of:)`, unterscheidet aber „nicht lesbar“ von „unbekannt“ und endet beim Abbruch des Tasks.
    func measure(_ path: String) async -> FileSize
    /// Wie `measure(_:)`, zusätzlich mit der jüngsten Änderung im Unterbaum.
    func summarize(_ path: String) async -> FileTreeSummary
}

extension FileSizeMeasuring {
    public func measure(_ path: String) async -> FileSize {
        allocatedSize(of: path).map(FileSize.bytes) ?? .unknown
    }

    /// Ohne eigene Zählung bleibt die jüngste Änderung offen.
    public func summarize(_ path: String) async -> FileTreeSummary {
        FileTreeSummary(size: await measure(path), newestModification: nil)
    }
}

/// Größe ohne eine Datei zu öffnen: `fts` (physisch, `FTS_XDEV`) liest nur Verzeichnisse und `lstat` – FIFOs und Geräte
/// blockieren nicht, Symlinks zählen nicht und werden nicht verfolgt, andere Volumes (Einhängepunkte) werden nicht
/// betreten, Hardlinks zählen einmal. Läuft mit Zeitgrenze (`BlockingCallGuard.fileSize`); zusätzlich bricht die Zählung
/// selbst nach der Frist oder beim Abbruch des Tasks ab, damit kein Thread weiterzählt. `summarize(_:)` liefert im selben
/// Durchgang die jüngste Änderung (#229).
///
/// `measure(_:)` wartet auf einer eigenen (nebenläufigen) Queue, nie im kooperativen Pool (Review N2): Gleichzeitige
/// Messungen begrenzt der Aufrufer (`LeftoverScanner.maximumConcurrentMeasurements`); der Abbruch des Tasks erreicht
/// die laufende Zählung.
public struct FileSizeCalculator: FileSizeMeasuring {
    /// Zählung eines Pfads bis zur Frist oder zum Abbruch (Standard `summary(of:deadline:isCancelled:)`).
    typealias Counting = @Sendable (_ path: String, _ deadline: ContinuousClock.Instant, _ isCancelled: () -> Bool)
        -> FileTreeSummary

    /// Frist für ein App-Bundle (Xcode: 166 836 Einträge, `du` 5,5 s).
    public static let appTimeout: Duration = .seconds(60)
    /// Frist je Rest-Eintrag (Container, Caches).
    public static let leftoverTimeout: Duration = .seconds(10)
    /// Frist und Abbruch werden alle so viele Einträge geprüft.
    static let checkInterval = 256

    private static let queue = DispatchQueue(label: "de.cstrube.Grantry.file-size", qos: .utility, attributes: .concurrent)

    private let timeout: Duration
    private let callGuard: BlockingCallGuard
    private let counting: Counting

    public init(timeout: Duration = appTimeout) {
        self.init(timeout: timeout, callGuard: .fileSize)
    }

    init(timeout: Duration, callGuard: BlockingCallGuard, summarizing counting: @escaping Counting = Self.summary) {
        self.timeout = timeout
        self.callGuard = callGuard
        self.counting = counting
    }

    /// Nur mit Größe (Tests); die jüngste Änderung bleibt offen.
    init(timeout: Duration, callGuard: BlockingCallGuard,
         counting: @escaping @Sendable (_ path: String, _ deadline: ContinuousClock.Instant, _ isCancelled: () -> Bool) -> FileSize) {
        self.init(timeout: timeout, callGuard: callGuard) { path, deadline, isCancelled in
            FileTreeSummary(size: counting(path, deadline, isCancelled), newestModification: nil)
        }
    }

    public func allocatedSize(of path: String) -> Int64? {
        measure(path) { false }.size.bytes
    }

    public func measure(_ path: String) async -> FileSize {
        await summarize(path).size
    }

    public func summarize(_ path: String) async -> FileTreeSummary {
        let cancellation = CancellationFlag()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return .unmeasured }
            return await withCheckedContinuation { continuation in
                Self.queue.async { continuation.resume(returning: measure(path, isCancelled: cancellation.isSet)) }
            }
        } onCancel: {
            cancellation.set()
        }
    }

    private func measure(_ path: String, isCancelled: @escaping @Sendable () -> Bool) -> FileTreeSummary {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let counting = counting
        return callGuard.run(timeout: timeout) { counting(path, deadline, isCancelled) } ?? .unmeasured
    }

    static func measurement(of path: String, deadline: ContinuousClock.Instant, isCancelled: () -> Bool) -> FileSize {
        summary(of: path, deadline: deadline, isCancelled: isCancelled).size
    }

    static func summary(of path: String, deadline: ContinuousClock.Instant, isCancelled: () -> Bool) -> FileTreeSummary {
        guard let info = FileType.linkStatus(of: path) else { return .unmeasured }
        if FileType.isRegularFile(info) { return FileTreeSummary(.bytes(Int64(info.st_blocks) * 512), newest: info.st_mtimespec) }
        guard FileType.isDirectory(info) else { return FileTreeSummary(.bytes(0), newest: info.st_mtimespec) }
        let root = FileIdentity(info)
        guard let argument = strdup(path) else { return .unmeasured }
        defer { free(argument) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [argument, nil]
        guard let stream = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return .unmeasured }
        defer { fts_close(stream) }
        var total: Int64 = 0, count = 0, isComplete = true
        var newest = info.st_mtimespec
        var linked = Set<FileIdentity>()
        errno = 0
        while let entry = fts_read(stream) {
            count += 1
            if count.isMultiple(of: checkInterval), isCancelled() || ContinuousClock.now > deadline { return .unmeasured }
            let kind = Int32(entry.pointee.fts_info)
            if kind != FTS_DNR, kind != FTS_ERR, kind != FTS_NS, let status = entry.pointee.fts_statp,
               (status.pointee.st_mtimespec.tv_sec, status.pointee.st_mtimespec.tv_nsec) > (newest.tv_sec, newest.tv_nsec) {
                newest = status.pointee.st_mtimespec
            }
            switch kind {
            case FTS_DNR, FTS_ERR, FTS_NS:
                isComplete = false
            case FTS_F:
                let status = entry.pointee.fts_statp.pointee
                let identity = FileIdentity(status)
                guard identity.isOnSameVolume(as: root) else { continue }
                if status.st_nlink > 1, !linked.insert(identity).inserted { continue }
                total += Int64(status.st_blocks) * 512
            default:
                continue
            }
        }
        // `fts_read` endet mit `errno == 0`, sonst mit einem Fehler außerhalb einzelner Einträge.
        return isComplete && errno == 0 ? FileTreeSummary(.bytes(total), newest: newest)
            : FileTreeSummary(size: .unreadable, newestModification: nil)
    }
}

extension FileTreeSummary {
    /// Nicht gemessen (Frist, Abbruch, Pfad fehlt).
    static let unmeasured = FileTreeSummary(size: .unknown, newestModification: nil)

    fileprivate init(_ size: FileSize, newest: timespec) {
        self.init(size: size, newestModification: Date(timeIntervalSince1970: Double(newest.tv_sec) + Double(newest.tv_nsec) / 1e9))
    }
}

/// Abbruch eines Tasks, sichtbar für den Zähl-Thread des `BlockingCallGuard`.
private final class CancellationFlag: Sendable {
    private let flag = Atomic(false)

    func set() { flag.store(true, ordering: .relaxed) }
    func isSet() -> Bool { flag.load(ordering: .relaxed) }
}
