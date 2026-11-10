import CoreServices
import Foundation

/// Änderungsprotokoll über den FSEvents-Verlauf: Ein einmaliger Stream mit `sinceWhen` liefert die seit der Marke
/// geänderten Ordner und endet mit `HistoryDone`; danach wartet er kurz (`settle`) auf Ereignisse, die der Kernel noch
/// nicht an `fseventsd` übergeben hat (beobachtet: wenige Millisekunden). Kein dauerhafter Stream, kein Takt.
///
/// Das Protokoll gilt nur, solange der Ereignisstrom des Volumes derselbe ist (`FSEventsCopyUUIDForDevice`): Nach dem
/// Löschen des Verlaufs, einem Überlauf der IDs oder auf einem Volume ohne Verlauf gibt es keine Marke oder keine
/// Antwort, und der Scanner liest alles neu.
struct FSEventsOccupancyJournal: OccupancyChangeJournal {
    static let timeout: Duration = .seconds(5)
    static let settle: Duration = .milliseconds(100)
    /// Mehr Ereignisse hält das Abspielen nicht im Speicher; dann wird alles neu gelesen.
    static let maximumEvents = 100_000

    func mark(forDevice device: Int32) -> OccupancyChangeMark? {
        guard let journal = Self.journal(ofDevice: device) else { return nil }
        return OccupancyChangeMark(journal: journal, eventID: FSEventsGetCurrentEventId())
    }

    func changes(since mark: OccupancyChangeMark, under root: String, device: Int32) async -> OccupancyChanges? {
        guard Self.journal(ofDevice: device) == mark.journal else { return nil }
        let replay = HistoryReplay(root: root, since: mark.eventID, settle: Self.settle, maximumEvents: Self.maximumEvents)
        let events = await withTaskCancellationHandler {
            await replay.events(timeout: Self.timeout)
        } onCancel: {
            replay.cancel()
        }
        return events.flatMap { OccupancyChanges(events: $0, root: root) }
    }

    private static func journal(ofDevice device: Int32) -> String? {
        FSEventsCopyUUIDForDevice(dev_t(device)).map { CFUUIDCreateString(nil, $0) as String }
    }
}

/// Ein einmaliges Abspielen des FSEvents-Verlaufs. Alle Zustände ändern sich nur auf `queue`, auf der auch der Callback
/// des Streams läuft; `finish` beendet genau einmal (Stoppen, Invalidieren, Freigeben, dann Fortsetzen).
///
/// `@unchecked Sendable`, weil `FSEventStreamRef` kein `Sendable` ist und die veränderlichen Felder nur auf `queue`
/// gelesen und geschrieben werden.
private final class HistoryReplay: @unchecked Sendable {
    private let root: String
    private let since: UInt64
    private let settle: Duration
    private let maximumEvents: Int
    private let queue = DispatchQueue(label: "\(ManagerKit.logSubsystem).occupancy-journal", qos: .utility)
    private var stream: FSEventStreamRef?
    private var events: [(path: String, flags: UInt32)] = []
    private var continuation: CheckedContinuation<[(path: String, flags: UInt32)]?, Never>?
    private var isFinished = false
    private var isCancelled = false

    init(root: String, since: UInt64, settle: Duration, maximumEvents: Int) {
        self.root = root
        self.since = since
        self.settle = settle
        self.maximumEvents = maximumEvents
    }

    /// Ereignisse seit der Marke; `nil` bei Zeitüberschreitung, Abbruch oder wenn FSEvents scheitert.
    func events(timeout: Duration) async -> [(path: String, flags: UInt32)]? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                self.continuation = continuation
                guard !isCancelled, start() else { return finish(succeeded: false) }
                queue.asyncAfter(deadline: .now() + timeout.dispatchInterval) { [self] in finish(succeeded: false) }
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            isCancelled = true
            finish(succeeded: false)
        }
    }

    /// Auf `queue`: Stream mit `sinceWhen` erzeugen und starten.
    private func start() -> Bool {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        // Ohne `kFSEventStreamCreateFlagUseCFTypes` ist `eventPaths` ein C-Array von C-Strings.
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, flags, _ in
            guard let info else { return }
            let replay = Unmanaged<HistoryReplay>.fromOpaque(info).takeUnretainedValue()
            let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            replay.receive((0..<count).map { (path: String(cString: paths[$0]), flags: flags[$0]) })
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [root] as CFArray, FSEventStreamEventId(since), 0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else { return false }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        return true
    }

    /// Auf `queue` (Callback des Streams).
    private func receive(_ batch: [(path: String, flags: UInt32)]) {
        guard !isFinished else { return }
        events += batch
        guard events.count <= maximumEvents else { return finish(succeeded: false) }
        if batch.contains(where: { $0.flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 }) {
            queue.asyncAfter(deadline: .now() + settle.dispatchInterval) { [self] in finish(succeeded: true) }
        }
    }

    /// Auf `queue`: genau einmal beenden. Nach `FSEventStreamInvalidate` ruft FSEvents den Callback nicht mehr auf.
    private func finish(succeeded: Bool) {
        guard !isFinished, let continuation else { return }
        isFinished = true
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        self.continuation = nil
        continuation.resume(returning: succeeded ? events : nil)
    }
}
