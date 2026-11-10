import Foundation

/// Wohin das Wachbuch beim Öffnen an einem Zeitpunkt springt (Mitteilung zu einem schweren Befund, TM-12.8a): der
/// kürzeste Zeitraum, in dem die Zeitmarke mit Abstand zum linken Rand liegt – sie wandert mit der Zeit nach links.
/// Zeitpunkte außerhalb der Aufbewahrung, vor Beginn der Aufzeichnung (gelöscht) oder in der Zukunft haben keinen; das
/// Wachbuch öffnet dann am aktuellen Ende.
public struct WatchbookFocus: Hashable, Sendable {
    public let period: WatchbookPeriod
    public let marker: Date

    /// Anteil des Zeitraums, den die Zeitmarke beim Öffnen höchstens vom rechten Rand entfernt liegt.
    static let visibleShare = 0.9

    public init?(markerAt marker: Date, now: Date, recordingSince: Date?) {
        let age = now.timeIntervalSince(marker)
        guard age >= 0, age <= WatchbookStore.retention,
              recordingSince.map({ marker >= $0 }) ?? true else { return nil }
        period = WatchbookPeriod.allCases.first { age <= $0.duration * Self.visibleShare } ?? .week
        self.marker = marker
    }
}
