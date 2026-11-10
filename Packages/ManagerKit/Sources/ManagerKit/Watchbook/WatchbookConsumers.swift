import Foundation

/// Die größten Verbraucher an einem Zeitpunkt für das Panel „Zu diesem Zeitpunkt“ (TM-12.6, Spec 2026-11-08 § 5.1):
/// aus dem nächsten 10-s-Punkt, sonst aus der nächsten Minute (ältere Tage sind verdichtet).
public struct WatchbookConsumers: Hashable, Sendable {
    /// Zeitpunkt des Eintrags: Punkt bzw. Mitte der Minute.
    public let time: Date
    /// CPU als Anteil aller Kerne (0…1), größte zuerst.
    public let cpu: [WatchbookConsumer]
    /// Speicher in Byte, größte zuerst.
    public let memory: [WatchbookConsumer]

    public init(time: Date, cpu: [WatchbookConsumer], memory: [WatchbookConsumer]) {
        self.time = time
        self.cpu = cpu
        self.memory = memory
    }

    /// Suchfenster um die Zeitmarke: eine halbe Spalte, mindestens eine Minute – so trifft jede Spalte mit Messung einen
    /// Punkt oder eine Minute.
    public static func window(columnDuration: TimeInterval) -> TimeInterval {
        max(columnDuration / 2, WatchbookMinute.duration)
    }

    /// Der nächste Punkt höchstens `window` von `time` entfernt; ohne einen solchen die nächste Minute (nach ihrer
    /// Mitte). Ein Punkt ist genauer als eine Minute und geht deshalb vor.
    static func nearest(to time: Date, within window: TimeInterval, points: [WatchbookPoint],
                        minutes: [WatchbookMinute]) -> WatchbookConsumers? {
        func distance(_ date: Date) -> TimeInterval { abs(date.timeIntervalSince(time)) }
        if let point = points.filter({ distance($0.time) <= window }).min(by: { distance($0.time) < distance($1.time) }) {
            return WatchbookConsumers(time: point.time, cpu: point.cpuConsumers, memory: point.memoryConsumers)
        }
        let middle = { (minute: WatchbookMinute) in minute.start.addingTimeInterval(WatchbookMinute.duration / 2) }
        guard let minute = minutes.filter({ distance(middle($0)) <= window })
            .min(by: { distance(middle($0)) < distance(middle($1)) }) else { return nil }
        return WatchbookConsumers(time: middle(minute), cpu: minute.cpuConsumers, memory: minute.memoryConsumers)
    }
}

extension WatchbookStore {
    /// Verbraucher um `time` (`WatchbookConsumers.nearest`); `pendingPoints` sind noch nicht geschriebene Punkte.
    public func consumers(near time: Date, within window: TimeInterval,
                          pendingPoints: [WatchbookPoint] = []) -> WatchbookConsumers? {
        let records = records(in: WatchbookEvent.range(around: time, within: window + WatchbookMinute.duration))
        return WatchbookConsumers.nearest(to: time, within: window, points: records.points + pendingPoints,
                                          minutes: records.minutes)
    }
}

/// Lesender Zugriff des Wachbuch-Tabs auf die Verbraucher an der Zeitmarke; in Tests ersetzt.
public protocol WatchbookConsumerReading: Sendable {
    func consumers(near time: Date, within window: TimeInterval) async -> WatchbookConsumers?
}

extension WatchbookRecorder: WatchbookConsumerReading {}
