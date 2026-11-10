import Foundation
import GrantryCharts
import ManagerKit

/// Brücke vom Verlauf des Task-Managers zu den Graphen (`SampleHistory` → `ChartSeries`); einmal zentral für Leistung,
/// Prozesse, Details und Menüleiste.
struct ChartHistory {
    let history: SampleHistory
    /// Ankunft des letzten Takts (`TaskManagerModel.frameDate`).
    let measuredAt: Date

    func series(_ key: MetricKey, in window: HistoryWindow) -> ChartSeries {
        ChartSeries(history.pointSeries(for: key, in: window), measuredAt: measuredAt)
    }

    /// Summe mehrerer Metriken, etwa der CPU-Last aller Prozesse eines Benutzers; leer ohne Metriken.
    func sumSeries(_ keys: [MetricKey], in window: HistoryWindow) -> ChartSeries {
        OverviewPresentation.sum(keys.map { history.pointSeries(for: $0, in: window) })
            .map { ChartSeries($0, measuredAt: measuredAt) } ?? .empty
    }

    /// Mittel mehrerer Metriken, etwa aller Effizienzkerne; leer ohne Metriken.
    func averageSeries(_ keys: [MetricKey], in window: HistoryWindow) -> ChartSeries {
        OverviewPresentation.average(keys.map { history.pointSeries(for: $0, in: window) })
            .map { ChartSeries($0, measuredAt: measuredAt) } ?? .empty
    }
}

extension ChartHistory {
    /// Skala der Leistung in Watt (`MetricKey.power`), weich mitwachsend ab 5 W – gemeinsam für Pegel und Graph.
    static let wattsScale = ChartScale.automatic(minimum: 5)

    /// Obergrenze der Watt-Skala über den sichtbaren Verlauf der Gesamtleistung.
    func wattsUpperBound(in window: HistoryWindow) -> Double {
        Self.wattsScale.upperBound(for: series(.power, in: window).values)
    }
}

extension ChartHistory {
    /// Füllstand von Peilring und Spur einer Messgröße: Anteile direkt, Raten relativ zur Skala ihres Spiegel-Graphen,
    /// Leistung relativ zur Watt-Skala; gemeinsam für Leistung und Popover.
    func level(of metric: PerformanceMetric, in snapshot: TaskManagerSnapshot, sensorHistory: ChartHistory?) -> Double? {
        switch metric {
        case .cpu: return snapshot.cpu?.total
        case .memory: return snapshot.memory.flatMap(PerformancePresentation.usedShare)
        case .gpu: return snapshot.gpu?.utilization
        case .drive(let id): return rateLevel(series(.diskRead(id), in: .oneMinute), series(.diskWrite(id), in: .oneMinute))
        case .interface(let name): return rateLevel(series(.received(name), in: .oneMinute),
                                                    series(.sent(name), in: .oneMinute))
        case .power:
            guard let sensorHistory else { return nil }
            return sensorHistory.series(.power, in: .oneMinute).current
                .map { $0 / sensorHistory.wattsUpperBound(in: .oneMinute) }
        }
    }

    private func rateLevel(_ upper: ChartSeries, _ lower: ChartSeries) -> Double? {
        guard let current = [upper.current, lower.current].compactMap(\.self).max() else { return nil }
        return current / MirrorGraph.scale.upperBound(for: upper.values + lower.values)
    }
}

extension ChartSeries {
    init(_ points: HistoryPoints, measuredAt: Date) {
        self.init(values: points.values, spacing: points.spacing.seconds,
                  latest: measuredAt.addingTimeInterval(-points.latestOffset.seconds))
    }
}

extension HistoryWindow {
    var title: String {
        switch self {
        case .oneMinute: String(localized: "60 s")
        case .fiveMinutes: String(localized: "5 min")
        case .fifteenMinutes: String(localized: "15 min")
        }
    }
}
