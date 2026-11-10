import Foundation

/// Datenträger-Befunde im vorhandenen Scan (TM-15.5, Spec 2026-11-08 §5.4): Nach einem Scan der Überwachung liest die
/// Prüfung das Volume-Inventar (`VolumeInventorySource`: `diskutil`, `tmutil`, je Container eine Kapazitätsabfrage) und
/// reicht es an `onInventory` weiter – ohne eigenen Takt, höchstens alle `minimumInterval` (Scans kommen auch bei jeder
/// Dateiänderung) und nie zwei Lesungen gleichzeitig.
@MainActor
public final class VolumeFindingCheck {
    /// Wie das Intervall der Überwachung (`ScanTriggers`): Volle Volumes, SMART-Fehler und alte Snapshots ändern sich
    /// nicht im Minutentakt.
    public static let minimumInterval: TimeInterval = 900

    /// Mit dem gelesenen Inventar und dem Zeitpunkt der Prüfung.
    public var onInventory: (@MainActor (VolumeInventory, Date) -> Void)?

    private let read: @Sendable () async -> VolumeInventory
    private let now: @Sendable () -> Date
    private var lastStart: Date?
    private var task: Task<Void, Never>?

    public convenience init() {
        let source = VolumeInventorySource()
        self.init(read: { await source.inventory() }, now: { Date() })
    }

    init(read: @escaping @Sendable () async -> VolumeInventory, now: @escaping @Sendable () -> Date) {
        self.read = read
        self.now = now
    }

    isolated deinit {
        task?.cancel()
    }

    /// Nach einem Scan: liest das Inventar, wenn die letzte Lesung mindestens `minimumInterval` zurückliegt und keine
    /// mehr läuft.
    /// - Returns: die begonnene Lesung; `nil`, wenn keine fällig war.
    @discardableResult
    public func scanFinished() -> Task<Void, Never>? {
        let start = now()
        guard task == nil, lastStart.map({ start.timeIntervalSince($0) >= Self.minimumInterval }) ?? true else {
            return nil
        }
        lastStart = start
        let read = read, now = now
        let task = Task { [weak self] in
            let inventory = await read()
            guard !Task.isCancelled, let self else { return }
            self.task = nil
            self.onInventory?(inventory, now())
        }
        self.task = task
        return task
    }

    /// Beim Beenden der App: Eine laufende Lesung liefert nichts mehr.
    public func cancel() {
        task?.cancel()
        task = nil
    }
}
