import Foundation

/// Eine verdichtete Minute (Spec 2026-11-08 §5.1): Mittel und Maximum je Messgröße aus `count` Punkten, dazu die
/// größten Verbraucher nach ihrer Spitze in der Minute.
public struct WatchbookMinute: Hashable, Sendable {
    public static let duration: TimeInterval = 60

    public let start: Date
    /// Zahl der zusammengefassten Punkte.
    public let count: Int
    public let mean: WatchbookValues
    public let maximum: WatchbookValues
    public let cpuConsumers: [WatchbookConsumer]
    public let memoryConsumers: [WatchbookConsumer]

    public init(start: Date, count: Int, mean: WatchbookValues, maximum: WatchbookValues,
                cpuConsumers: [WatchbookConsumer], memoryConsumers: [WatchbookConsumer]) {
        self.start = start
        self.count = count
        self.mean = mean
        self.maximum = maximum
        self.cpuConsumers = cpuConsumers
        self.memoryConsumers = memoryConsumers
    }

    static func start(of time: Date) -> Date {
        Date(timeIntervalSince1970: (time.timeIntervalSince1970 / duration).rounded(.down) * duration)
    }
}

/// Verdichtung der 10-s-Punkte zu Minutenwerten (rein, ohne Uhr). Minuten ohne Punkt entstehen nicht – Lücken bleiben
/// Lücken; Messgrößen ohne Wert in einer Minute bleiben dort leer.
enum WatchbookCompaction {
    /// Minutenwerte aus `points` (Reihenfolge beliebig), mit `existing` zusammengeführt, aufsteigend nach Beginn.
    ///
    /// Gibt es eine Minute schon (Punkte kamen nach der Verdichtung dazu, etwa weil die Uhr zurückgestellt wurde),
    /// zählen beide Teile nach ihrer Zahl an Punkten. Fehlte eine Messgröße nur in einzelnen Punkten, ist das Mittel
    /// dabei eine Näherung.
    static func minutes(from points: [WatchbookPoint], merging existing: [WatchbookMinute] = []) -> [WatchbookMinute] {
        let fresh = Dictionary(grouping: points) { WatchbookMinute.start(of: $0.time) }.mapValues(minute)
        let merged = Dictionary(existing.map { ($0.start, $0) }, uniquingKeysWith: merge)
            .merging(fresh, uniquingKeysWith: merge)
        return merged.values.sorted { $0.start < $1.start }
    }

    private static func minute(of points: [WatchbookPoint]) -> WatchbookMinute {
        var mean = WatchbookValues(), maximum = WatchbookValues()
        for metric in WatchbookMetric.allCases {
            let measured = points.compactMap { $0.values[metric] }
            guard !measured.isEmpty else { continue }
            mean[metric] = measured.reduce(0, +) / Double(measured.count)
            maximum[metric] = measured.max()
        }
        return WatchbookMinute(start: WatchbookMinute.start(of: points[0].time), count: points.count, mean: mean,
                               maximum: maximum, cpuConsumers: peaks(points.map(\.cpuConsumers)),
                               memoryConsumers: peaks(points.map(\.memoryConsumers)))
    }

    private static func merge(_ lhs: WatchbookMinute, _ rhs: WatchbookMinute) -> WatchbookMinute {
        var mean = WatchbookValues(), maximum = WatchbookValues()
        let total = Double(lhs.count + rhs.count)
        for metric in WatchbookMetric.allCases {
            switch (lhs.mean[metric], rhs.mean[metric]) {
            case let (left?, right?):
                mean[metric] = (left * Double(lhs.count) + right * Double(rhs.count)) / total
            case let (single?, nil), let (nil, single?):
                mean[metric] = single
            case (nil, nil):
                break
            }
            maximum[metric] = [lhs.maximum[metric], rhs.maximum[metric]].compactMap { $0 }.max()
        }
        return WatchbookMinute(start: lhs.start, count: lhs.count + rhs.count, mean: mean, maximum: maximum,
                               cpuConsumers: peaks([lhs.cpuConsumers, rhs.cpuConsumers]),
                               memoryConsumers: peaks([lhs.memoryConsumers, rhs.memoryConsumers]))
    }

    /// Die größten Verbraucher nach ihrer Spitze.
    private static func peaks(_ lists: [[WatchbookConsumer]]) -> [WatchbookConsumer] {
        var peaks: [WatchbookSubject: Double] = [:]
        for consumer in lists.joined() { peaks[consumer.subject] = max(peaks[consumer.subject] ?? 0, consumer.value) }
        return WatchbookConsumer.ranked(peaks)
    }
}
