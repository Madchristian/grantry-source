import Foundation

/// Zeitraum der Wachbuch-Ansicht (Spec 2026-11-08 §5.1).
public enum WatchbookPeriod: CaseIterable, Hashable, Sendable {
    case hour, sixHours, day, week

    public var duration: TimeInterval {
        switch self {
        case .hour: 3_600
        case .sixHours: 21_600
        case .day: 86_400
        case .week: 604_800
        }
    }
}

/// Minimum, Maximum und Mittel einer Spalte.
public struct WatchbookStatistic: Hashable, Sendable {
    public let minimum: Double
    public let maximum: Double
    public let mean: Double

    public init(minimum: Double, maximum: Double, mean: Double) {
        self.minimum = minimum
        self.maximum = maximum
        self.mean = mean
    }
}

/// Eine auf Spalten verdichtete Reihe (Spec §4.4 Regel 5): je Messgröße höchstens ein Wert je Spalte, `nil` für
/// Spalten ohne Messung – Lücken bleiben Lücken.
public struct WatchbookSeries: Equatable, Sendable {
    public let range: Range<Date>
    /// Je Messgröße die Spalten, älteste zuerst.
    private let columns: [[WatchbookStatistic?]]
    /// Ereignisse, die den Zeitraum berühren, aufsteigend nach Beginn.
    public let events: [WatchbookEvent]
    public let problems: [WatchbookProblem]

    init(range: Range<Date>, columns: [[WatchbookStatistic?]], events: [WatchbookEvent],
         problems: [WatchbookProblem]) {
        self.range = range
        self.columns = columns
        self.events = events
        self.problems = problems
    }

    public var width: Int { columns.first?.count ?? 0 }

    /// Dauer einer Spalte.
    public var columnDuration: TimeInterval {
        range.upperBound.timeIntervalSince(range.lowerBound) / Double(max(width, 1))
    }

    public func statistics(of metric: WatchbookMetric) -> [WatchbookStatistic?] { columns[metric.rawValue] }
}

/// Verdichtet Punkte und Minutenwerte eines Zeitraums auf `width` gleich lange Spalten.
///
/// - Ein Punkt deckt die Zeit seit dem vorigen ab – höchstens `WatchbookPoint.maximumCoverage`, bei einer größeren
///   Lücke (Ruhezustand) und ohne Vorgänger `WatchbookPoint.interval`. Er zählt in jeder Spalte, die er berührt. Punkte
///   sind daher in Schreibreihenfolge zu übergeben; unsortierte (Uhr zurückgestellt) decken nur ihr Intervall ab.
/// - Eine Minute deckt ihre 60 s ab und zählt mit ihrem Mittel (gewichtet nach Punkten) und Maximum; als Minimum gilt
///   ihr Mittel, denn das Minimum der Punkte wird nicht gespeichert.
/// - Spalten ohne Beitrag bleiben leer, ebenso Messgrößen, die in einer Spalte nicht gemessen wurden.
struct WatchbookSeriesBuilder {
    /// Schranke für den Speicher: mehr Spalten als Pixel hat kein Bildschirm.
    static let maximumWidth = 10_000

    let range: Range<Date>
    let width: Int
    private let start: TimeInterval
    private let end: TimeInterval
    private let columnDuration: TimeInterval
    /// Je Messgröße und Spalte, flach: `metric.rawValue * width + column`.
    private var minimum: [Double]
    private var maximum: [Double]
    private var sum: [Double]
    private var weight: [Double]
    private var previousPointTime: TimeInterval?

    init(range: Range<Date>, width: Int) {
        self.range = range
        self.width = min(max(width, 1), Self.maximumWidth)
        start = range.lowerBound.timeIntervalSince1970
        end = range.upperBound.timeIntervalSince1970
        columnDuration = max(end - start, 1) / Double(self.width)
        let count = WatchbookMetric.allCases.count * self.width
        minimum = Array(repeating: .infinity, count: count)
        maximum = Array(repeating: -.infinity, count: count)
        sum = Array(repeating: 0, count: count)
        weight = Array(repeating: 0, count: count)
    }

    mutating func add(_ points: [WatchbookPoint]) {
        for point in points {
            let time = point.time.timeIntervalSince1970
            var coverage = WatchbookPoint.interval
            if let previous = previousPointTime, time > previous, time - previous <= WatchbookPoint.maximumCoverage {
                coverage = time - previous
            }
            previousPointTime = time
            add(from: time - coverage, to: time, low: point.values, high: point.values, mean: point.values, weight: 1)
        }
    }

    mutating func add(_ minutes: [WatchbookMinute]) {
        for minute in minutes {
            let time = minute.start.timeIntervalSince1970
            add(from: time, to: time + WatchbookMinute.duration, low: minute.mean, high: minute.maximum,
                mean: minute.mean, weight: Double(minute.count))
        }
    }

    func build(events: [WatchbookEvent], problems: [WatchbookProblem]) -> WatchbookSeries {
        let columns = WatchbookMetric.allCases.map { metric in
            (0..<width).map { column -> WatchbookStatistic? in
                let index = metric.rawValue * width + column
                guard weight[index] > 0 else { return nil }
                return WatchbookStatistic(minimum: minimum[index], maximum: maximum[index],
                                          mean: sum[index] / weight[index])
            }
        }
        return WatchbookSeries(range: range, columns: columns, events: events, problems: problems)
    }

    /// Trägt einen Abschnitt `[lower, upper)` in alle Spalten ein, die er berührt.
    private mutating func add(from lower: TimeInterval, to upper: TimeInterval, low: WatchbookValues,
                              high: WatchbookValues, mean: WatchbookValues, weight contribution: Double) {
        guard upper > start, lower < end, upper > lower else { return }
        let first = max(Int(((lower - start) / columnDuration).rounded(.down)), 0)
        let last = min(Int(((upper - start) / columnDuration).rounded(.up)) - 1, width - 1)
        guard first <= last else { return }
        for metric in WatchbookMetric.allCases {
            guard let average = mean[metric] else { continue }
            let lowest = low[metric] ?? average, highest = high[metric] ?? average
            for column in first...last {
                let index = metric.rawValue * width + column
                minimum[index] = min(minimum[index], lowest)
                maximum[index] = max(maximum[index], highest)
                sum[index] += average * contribution
                weight[index] += contribution
            }
        }
    }
}
