import Foundation
import Observation

/// Längerer Leistungsverlauf aus dem Wachbuch für den Tab „Leistung“ (TM-14.5). Liest nur, solange `follow` läuft – die
/// Ansicht bindet es per `.task(id:)` an Sichtbarkeit, Zeitraum und Breite –, und danach erst wieder, wenn eine neue
/// Spalte fällig ist, frühestens nach einem Wachbuch-Punkt (10 s). So zeichnet der Graph nur bei neuem Stand (Spec
/// §4.4 Regel 1); das Lesen selbst läuft im Recorder außerhalb des Main Actors.
@MainActor
@Observable
public final class PowerHistoryModel {
    /// Letzter gelesener Stand; `nil` ohne Wachbuch oder bis zum ersten Lesen.
    public private(set) var page: PowerHistoryPage?

    @ObservationIgnored private let source: (any WatchbookSeriesReading)?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    /// - Parameter source: `nil` ohne Wachbuch-Recorder – dann gibt es nie eine Seite.
    public init(source: (any WatchbookSeriesReading)?, now: @escaping @Sendable () -> Date = Date.init,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.source = source
        self.now = now
        self.sleep = sleep
    }

    /// Liest `period` auf `width` Spalten und danach je neuer Spalte erneut, bis die Aufgabe abgebrochen wird.
    public func follow(_ period: WatchbookPeriod, width: Int) async {
        guard let source else { return }
        if page?.period != period { page = nil }
        let width = max(width, 1)
        let interval = max(period.duration / Double(width), WatchbookPoint.interval)
        while !Task.isCancelled {
            let series = await source.series(period, endingAt: now(), width: width)
            guard !Task.isCancelled else { return }
            page = PowerHistoryPage(series: series, period: period)
            do { try await sleep(.seconds(interval)) } catch { return }
        }
    }
}
