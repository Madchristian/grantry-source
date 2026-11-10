import Foundation

/// Werte einer Metrik für einen Graphen, älteste zuerst (wie `SampleHistory.points`); `nil` = Lücke.
public struct ChartSeries: Equatable, Sendable {
    public var values: [Double?]
    /// Zeitlicher Abstand zweier Werte in Sekunden.
    public var spacing: TimeInterval
    /// Zeitpunkt des neuesten Werts.
    public var latest: Date

    public init(values: [Double?], spacing: TimeInterval, latest: Date) {
        precondition(spacing > 0, "Abstand muss positiv sein")
        self.values = values
        self.spacing = spacing
        self.latest = latest
    }

    public static let empty = ChartSeries(values: [], spacing: 1, latest: .distantPast)

    /// Neuester gemessener Wert.
    public var current: Double? { values.last ?? nil }

    /// Zeitpunkt des Werts an `index`.
    func time(at index: Int) -> Date {
        latest.addingTimeInterval(-Double(values.count - 1 - index) * spacing)
    }
}
