import Foundation

/// Schreibt das Wachbuch gebündelt (Spec 2026-11-08 §5.1): Punkte und Ereignisse sammeln sich im Speicher und gehen
/// höchstens alle 60 s als ein Block je Tag in die Dateien (`WatchbookStore.append`). Danach folgt die Wartung
/// (`WatchbookStore.maintain`), wenn ein neuer Tag begonnen hat, ein Block in einen schon verdichtbaren Tag fiel (Uhr
/// zurückgestellt) oder die Obergrenze erreicht sein kann.
///
/// Die Zeit kommt vom Aufrufer (`now`), nie von der Wanduhr. Springt sie um mehr als das Schreibintervall – vor oder
/// zurück –, wird sofort geschrieben; ein Rückwärtssprung hält das Schreiben also nicht auf.
///
/// Nicht threadsicher: Der Recorder besitzt das Journal und ruft es auf seiner eigenen Queue bzw. in seinem Actor auf.
public final class WatchbookJournal {
    public static let flushInterval: TimeInterval = 60
    /// Mehr Einträge im Puffer werden sofort geschrieben; scheitert das Schreiben, bleiben höchstens so viele (die
    /// neuesten) für den nächsten Versuch.
    public static let defaultMaximumPending = 2_000

    public let store: WatchbookStore
    let maximumPending: Int
    public private(set) var pendingPoints: [WatchbookPoint] = []
    public private(set) var pendingEvents: [WatchbookEvent] = []
    /// Was beim letzten Schreiben und der letzten Wartung nicht wie vorgesehen ging.
    public private(set) var problems: [WatchbookProblem] = []
    private var lastFlush: Date?
    private var maintainedDay: WatchbookDay?
    /// Größe aller Dateien laut letzter Wartung plus seither Geschriebenes.
    private var estimatedSize = 0

    public init(store: WatchbookStore, maximumPending: Int = defaultMaximumPending) {
        self.store = store
        self.maximumPending = max(maximumPending, 1)
    }

    public func record(_ point: WatchbookPoint, now: Date) throws {
        pendingPoints.append(point)
        try flushIfDue(now: now)
    }

    public func record(_ event: WatchbookEvent, now: Date) throws {
        pendingEvents.append(event)
        try flushIfDue(now: now)
    }

    /// Schreibt sofort, etwa vor dem Ruhezustand oder beim Beenden.
    public func flush(now: Date) throws {
        lastFlush = now
        guard !pendingPoints.isEmpty || !pendingEvents.isEmpty else { return }
        let report: WatchbookAppendReport
        do {
            report = try store.append(points: pendingPoints, events: pendingEvents)
        } catch {
            pendingPoints = Array(pendingPoints.suffix(maximumPending))
            pendingEvents = Array(pendingEvents.suffix(maximumPending))
            throw error
        }
        pendingPoints = []
        pendingEvents = []
        problems = report.problems
        estimatedSize += report.writtenBytes
        try maintainIfNeeded(now: now, appendedDays: report.days)
    }

    /// „Wachbuch löschen“: verwirft den Puffer und löscht die Dateien.
    public func remove() throws {
        pendingPoints = []
        pendingEvents = []
        problems = []
        maintainedDay = nil
        estimatedSize = 0
        try store.remove()
    }

    /// Verdichtete Reihe einschließlich der noch nicht geschriebenen Einträge (`WatchbookStore.series`).
    public func series(_ period: WatchbookPeriod, endingAt end: Date, width: Int) -> WatchbookSeries {
        store.series(period, endingAt: end, width: width, pendingPoints: pendingPoints, pendingEvents: pendingEvents)
    }

    private func flushIfDue(now: Date) throws {
        guard let lastFlush else {
            lastFlush = now
            return
        }
        let isDue = abs(now.timeIntervalSince(lastFlush)) >= Self.flushInterval
        guard isDue || pendingPoints.count + pendingEvents.count >= maximumPending else { return }
        try flush(now: now)
    }

    private func maintainIfNeeded(now: Date, appendedDays: Set<WatchbookDay>) throws {
        let today = WatchbookDay(containing: now)
        let touchesCompactableDay = appendedDays.contains {
            $0.end.addingTimeInterval(WatchbookStore.compactionDelay) <= now
        }
        guard maintainedDay != today || touchesCompactableDay || estimatedSize > store.sizeLimit else { return }
        let result = try store.maintain(now: now)
        maintainedDay = today
        estimatedSize = result.totalSize
        problems += result.problems
    }
}
