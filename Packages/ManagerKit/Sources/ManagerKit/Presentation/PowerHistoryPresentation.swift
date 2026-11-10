import Foundation

/// Zeitraum der Messkarte „Leistungsaufnahme“ (Spec 2026-11-08 §5.3, TM-14.5): live aus den Sensoren (`SensorModel`) oder
/// länger aus dem Wachbuch.
public enum PowerRange: Hashable, Sendable {
    case live(HistoryWindow)
    case watchbook(WatchbookPeriod)

    public static var allCases: [PowerRange] {
        HistoryWindow.allCases.map(Self.live) + WatchbookPeriod.allCases.map(Self.watchbook)
    }

    public var title: String {
        switch self {
        case .live(.oneMinute): "60 s"
        case .live(.fiveMinutes): "5 min"
        case .live(.fifteenMinutes): "15 min"
        case .watchbook(let period): period.title
        }
    }
}

extension WatchbookPeriod {
    public var title: String {
        switch self {
        case .hour: "1 h"
        case .sixHours: "6 h"
        case .day: "24 h"
        case .week: "7 Tage"
        }
    }
}

/// Teil der Leistungsaufnahme: gesamt oder ein Block der Darstellung „Je Block“.
public enum PowerPart: CaseIterable, Hashable, Sendable {
    case total, cpu, gpu, neuralEngine

    /// Die Blöcke der Darstellung „Je Block“ (höchstens drei Reihen je Graph, Standard §3.4).
    public static let blocks: [PowerPart] = [.cpu, .gpu, .neuralEngine]

    public var title: String {
        switch self {
        case .total: "Gesamt"
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .neuralEngine: "Neural Engine"
        }
    }

    var metric: WatchbookMetric {
        switch self {
        case .total: .power
        case .cpu: .cpuPower
        case .gpu: .gpuPower
        case .neuralEngine: .neuralEnginePower
        }
    }
}

/// Längerer Leistungsverlauf aus einer verdichteten Wachbuch-Reihe (TM-14.5): je Teil das Mittel jeder Spalte (Lücken
/// bleiben `nil`) und Kennzahlen über den Zeitraum. Gemessen ist nur, was die Sensoren des Helpers geliefert haben.
public struct PowerHistoryPage: Equatable, Sendable {
    public let period: WatchbookPeriod
    /// Ende des Zeitraums, Zeitbezug des rechten Rands.
    public let end: Date
    /// Dauer einer Spalte.
    public let spacing: TimeInterval
    public let stats: [PerformanceStat]
    /// Mindestens eine Spalte mit Leistungswert.
    public let hasValues: Bool
    /// Jede Spalte gemessen – sonst gibt es Lücken, die die Ansicht erklärt.
    public let isComplete: Bool
    private let means: [PowerPart: [Double?]]

    /// - Parameter series: die Reihe über `period` (`WatchbookSeriesReading.series`).
    public init(series: WatchbookSeries, period: WatchbookPeriod) {
        self.period = period
        end = series.range.upperBound
        spacing = series.columnDuration
        let means = Dictionary(uniqueKeysWithValues: PowerPart.allCases.map { part in
            (part, series.statistics(of: part.metric).map { $0?.mean })
        })
        self.means = means
        let measured = series.statistics(of: PowerPart.total.metric).compactMap { $0 }
        hasValues = !measured.isEmpty
        isComplete = hasValues && measured.count == series.width
        let missing = PerformancePresentation.missing
        let watts = { (value: Double) in PerformancePresentation.watts(value * 1_000) }
        let mean = { (part: PowerPart) in
            let values = means[part, default: []].compactMap { $0 }
            return values.isEmpty ? missing : watts(values.reduce(0, +) / Double(values.count))
        }
        let coverage = min(Double(measured.count) * spacing, period.duration)
        let values = [mean(.total), measured.map(\.maximum).max().map(watts) ?? missing]
            + PowerPart.blocks.map(mean) + [hasValues ? Self.coverageText(coverage, of: period) : missing]
        stats = zip(Self.statTitles, values).map(PerformanceStat.init)
    }

    /// Kennzahlen, solange noch nichts gelesen ist oder das Wachbuch fehlt.
    public static var placeholderStats: [PerformanceStat] {
        statTitles.map { PerformanceStat($0, PerformancePresentation.missing) }
    }

    private static var statTitles: [String] { ["Mittel", "Spitze"] + PowerPart.blocks.map(\.title) + ["Gemessen"] }

    /// Länge des Zeitraums.
    public var window: TimeInterval { period.duration }

    /// Mittel je Spalte, älteste zuerst; `nil` heißt nicht gemessen.
    public func values(_ part: PowerPart) -> [Double?] { means[part, default: []] }

    /// „43 von 60 min“, „2 h 5 min von 6 h“, „11 h 20 min von 7 Tagen“ – auf Minuten gerundet.
    static func coverageText(_ seconds: TimeInterval, of period: WatchbookPeriod) -> String {
        let minutes = Int((seconds / 60).rounded())
        if period == .hour { return "\(minutes) von 60 min" }
        let hours = minutes / 60, rest = minutes % 60
        let measured = hours == 0 ? "\(rest) min" : rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
        return "\(measured) von \(period == .week ? "7 Tagen" : period.title)"
    }
}
