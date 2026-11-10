import Foundation

/// Lesender Zugriff der Ansichten auf die verdichtete Reihe des Wachbuchs (`WatchbookRecorder.series`), etwa für den
/// längeren Leistungsverlauf im Tab „Leistung“ (TM-14.5); in Tests ersetzt.
public protocol WatchbookSeriesReading: Sendable {
    /// `period` bis `end` auf `width` Spalten, einschließlich noch nicht geschriebener Punkte.
    func series(_ period: WatchbookPeriod, endingAt end: Date, width: Int) async -> WatchbookSeries
}

extension WatchbookRecorder: WatchbookSeriesReading {}
