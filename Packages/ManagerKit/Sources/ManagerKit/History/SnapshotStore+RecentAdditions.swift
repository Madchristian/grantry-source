import Foundation

extension SnapshotStore {
    /// Seitengröße, mit der `events(since:)` den Verlauf durchblättert.
    static var additionsPageSize: Int { 200 }

    /// Alle Events ab `date` (einschließlich), neueste zuerst.
    ///
    /// Blättert seitenweise durch `events(limit:after:)` und hört auf, sobald eine Seite vor `date` reicht – so bleibt
    /// die Abfrage auch bei langem Verlauf günstig. Grundlage von `additions(since:)` und des Nachtrags ins Wachbuch
    /// (`WatchbookChangeMarks.history(from:now:)`).
    public func events(since date: Date) async throws -> [HistoryEvent] {
        var events: [HistoryEvent] = []
        var cursor: HistoryEvent?
        while true {
            let page = try await self.events(limit: Self.additionsPageSize, after: cursor)
            let inRange = page.prefix { $0.event.detectedAt >= date }
            events += inRange
            guard inRange.count == Self.additionsPageSize, let last = page.last else { return events }
            cursor = last
        }
    }

    /// Alle `.added`-Events ab `date` (einschließlich), neueste zuerst. Grundlage für „neu seit 7 Tagen“
    /// (`DashboardMetrics`) und das Badge „neu“ (`RecordBadges`), die über die `MonitoringState.recentEvents` hinaus
    /// zählen müssen.
    public func additions(since date: Date) async throws -> [HistoryEvent] {
        try await events(since: date).filter { $0.event.kind == .added }
    }
}
