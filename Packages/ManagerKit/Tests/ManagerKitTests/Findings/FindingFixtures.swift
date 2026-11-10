import Foundation
@testable import ManagerKit

/// Feste Zeiten und Messreihen für die Befund-Tests; keine Wanduhr (#214).
enum FindingFixtures {
    /// 7. November 2026, 00:00 UTC.
    static let start = Date(timeIntervalSince1970: 1_794_009_600)
    /// Abstand der Wachbuch-Punkte.
    static let step: TimeInterval = 10
    static let thresholds = FindingThresholds.standard

    static func time(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    /// Ein Wert je Punkt im Abstand `step`, ab `offset`; `nil` heißt „nicht gemessen“.
    static func points(_ values: [Double?], from offset: TimeInterval = 0,
                       set: (inout WatchbookValues, Double?) -> Void) -> [WatchbookPoint] {
        values.enumerated().map { index, value in
            var values = WatchbookValues()
            set(&values, value)
            return WatchbookPoint(time: time(offset + Double(index) * step), values: values, cpuConsumers: [],
                                  memoryConsumers: [])
        }
    }

    /// Anzahl Punkte, deren erster und letzter `seconds` auseinanderliegen.
    static func count(spanning seconds: TimeInterval) -> Int { Int(seconds / step) + 1 }

    /// Abschnitte aus je `count` gleichen Werten, lückenlos nacheinander.
    static func values(_ parts: [(Double?, Int)]) -> [Double?] {
        parts.flatMap { Array(repeating: $0.0, count: $0.1) }
    }
}
