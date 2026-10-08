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

/// Belegter Speicher einer Datei oder eines Ordners.
public protocol FileSizeMeasuring: Sendable {
    /// Summe der belegten Blöcke aller regulären Dateien; `nil`, wenn der Pfad fehlt, Teile nicht lesbar sind oder die
    /// Frist abläuft.
    func allocatedSize(of path: String) -> Int64?
    /// Wie `allocatedSize(of:)`, unterscheidet aber „nicht lesbar“ von „unbekannt“ und endet beim Abbruch des Tasks.
    func measure(_ path: String) async -> FileSize
}

extension FileSizeMeasuring {
    public func measure(_ path: String) async -> FileSize {
        allocatedSize(of: path).map(FileSize.bytes) ?? .unknown
    }
}

/// Größe ohne eine Datei zu öffnen: `fts` (physisch, `FTS_XDEV`) liest nur Verzeichnisse und `lstat` – FIFOs und Geräte
/// blockieren nicht, Symlinks zählen nicht und werden nicht verfolgt, andere Volumes (Einhängepunkte) werden nicht
/// betreten, Hardlinks zählen einmal. Läuft mit Zeitgrenze (`BlockingCallGuard.fileSize`); zusätzlich bricht die Zählung
/// selbst nach der Frist oder beim Abbruch des Tasks ab, damit kein Thread weiterzählt.
///
/// `measure(_:)` wartet auf einer eigenen (nebenläufigen) Queue, nie im kooperativen Pool (Review N2): Gleichzeitige
/// Messungen begrenzt der Aufrufer (`LeftoverScanner.maximumConcurrentMeasurements`); der Abbruch des Tasks erreicht
/// die laufende Zählung.
public struct FileSizeCalculator: FileSizeMeasuring {
    /// Zählung eines Pfads bis zur Frist oder zum Abbruch (Standard `measurement(of:deadline:isCancelled:)`).
    typealias Counting = @Sendable (_ path: String, _ deadline: ContinuousClock.Instant, _ isCancelled: () -> Bool) -> FileSize

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

    init(timeout: Duration, callGuard: BlockingCallGuard, counting: @escaping Counting = Self.measurement) {
        self.timeout = timeout
        self.callGuard = callGuard
        self.counting = counting
    }

    public func allocatedSize(of path: String) -> Int64? {
        measure(path) { false }.bytes
    }

    public func measure(_ path: String) async -> FileSize {
        let cancellation = CancellationFlag()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return .unknown }
            return await withCheckedContinuation { continuation in
                Self.queue.async { continuation.resume(returning: measure(path, isCancelled: cancellation.isSet)) }
            }
        } onCancel: {
            cancellation.set()
        }
    }

    private func measure(_ path: String, isCancelled: @escaping @Sendable () -> Bool) -> FileSize {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let counting = counting
        return callGuard.run(timeout: timeout) { counting(path, deadline, isCancelled) } ?? .unknown
    }

    static func measurement(of path: String, deadline: ContinuousClock.Instant, isCancelled: () -> Bool) -> FileSize {
        guard let info = FileType.linkStatus(of: path) else { return .unknown }
        if FileType.isRegularFile(info) { return .bytes(Int64(info.st_blocks) * 512) }
        guard FileType.isDirectory(info) else { return .bytes(0) }
        let root = FileIdentity(info)
        guard let argument = strdup(path) else { return .unknown }
        defer { free(argument) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [argument, nil]
        guard let stream = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return .unknown }
        defer { fts_close(stream) }
        var total: Int64 = 0, count = 0, isComplete = true
        var linked = Set<FileIdentity>()
        errno = 0
        while let entry = fts_read(stream) {
            count += 1
            if count.isMultiple(of: checkInterval), isCancelled() || ContinuousClock.now > deadline { return .unknown }
            switch Int32(entry.pointee.fts_info) {
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
        return isComplete && errno == 0 ? .bytes(total) : .unreadable
    }
}

/// Abbruch eines Tasks, sichtbar für den Zähl-Thread des `BlockingCallGuard`.
private final class CancellationFlag: Sendable {
    private let flag = Atomic(false)

    func set() { flag.store(true, ordering: .relaxed) }
    func isSet() -> Bool { flag.load(ordering: .relaxed) }
}
