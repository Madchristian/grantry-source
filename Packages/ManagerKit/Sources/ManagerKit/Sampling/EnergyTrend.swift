import Foundation
import GrantryShared

/// Gleitender Mittelwert der Prozessleistung (Spec 2026-11-06 §6 Stufe 2: Trend wie Windows 11, dort über zwei
/// Minuten): exponentiell mit Zeitkonstante `window`, damit kein Verlauf je Prozess nötig ist. Der erste Wert übernimmt
/// die Messung; ohne Messung bleibt der bisherige Mittelwert stehen.
public enum EnergyTrend {
    public static let window: Duration = .seconds(120)

    static func next(_ previous: Double?, _ current: Double?, elapsed: Duration?) -> Double? {
        guard let current else { return previous }
        guard let previous, let elapsed, elapsed > .zero else { return current }
        let weight = 1 - exp(-elapsed.seconds / window.seconds)
        return previous + (current - previous) * weight
    }
}
