import Foundation

/// Summe der Threads aller Prozesse eines Takts (Leistung › CPU und Spaltenkopf in „Details“). Prozesse anderer
/// Benutzer liefern ohne Root keine Thread-Zahl; fehlt sie bei einem Prozess, ist die Summe nur eine Untergrenze und
/// heißt „mind. …“ (Bewertung 2026.11.7-1188, Mangel 9).
public struct ThreadTotal: Hashable, Sendable {
    public let count: Int
    /// Mindestens ein Prozess ohne Thread-Zahl.
    public let isPartial: Bool

    /// `nil`, wenn kein Prozess eine Thread-Zahl hat.
    public init?(_ processes: [ProcessMeasurement]) {
        let counts = processes.compactMap(\.threadCount)
        guard !counts.isEmpty else { return nil }
        count = counts.reduce(0, +)
        isPartial = counts.count < processes.count
    }

    /// „6.859“ bzw. „mind. 4.512“.
    public var text: String {
        let number = count.formatted(.number.locale(Locale(identifier: "de_DE")))
        return isPartial ? "mind. \(number)" : number
    }
}
