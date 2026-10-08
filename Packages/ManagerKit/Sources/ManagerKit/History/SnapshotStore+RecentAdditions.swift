import Foundation

extension SnapshotStore {
    /// Seitengröße, mit der `additions(since:)` den Verlauf durchblättert.
    static var additionsPageSize: Int { 200 }

    /// Alle `.added`-Events ab `date` (einschließlich), neueste zuerst.
    ///
    /// Blättert seitenweise durch `events(limit:after:)` und hört auf, sobald eine Seite vor `date` reicht – so bleibt
    /// die Abfrage auch bei langem Verlauf günstig. Grundlage für „neu seit 7 Tagen“ (`DashboardMetrics`) und das
    /// Badge „neu“ (`RecordBadges`), die über die `MonitoringState.recentEvents` hinaus zählen müssen.
    public func additions(since date: Date) async throws -> [HistoryEvent] {
        var additions: [HistoryEvent] = []
        var cursor: HistoryEvent?
        while true {
            let page = try await events(limit: Self.additionsPageSize, after: cursor)
            let inRange = page.prefix { $0.event.detectedAt >= date }
            additions += inRange.filter { $0.event.kind == .added }
            guard inRange.count == Self.additionsPageSize, let last = page.last else { return additions }
            cursor = last
        }
    }
}
