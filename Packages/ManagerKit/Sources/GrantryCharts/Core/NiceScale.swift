import Foundation

/// Runde Achsen-Obergrenzen (Spec §4). Die Obergrenze gleitet nicht mehr, sie wechselt mit dem Messpunkt – wie die
/// Achsenbeschriftung daneben (Leistungsbudget, siehe `LiveGraph`).
public enum NiceScale {
    /// Kleinste Obergrenze aus 1, 2, 5 × 10ⁿ, die `value` umfasst; mindestens `minimum`.
    public static func ceiling(_ value: Double, minimum: Double = 1) -> Double {
        let target = max(value, minimum)
        guard target.isFinite, target > 0 else { return minimum }
        let magnitude = pow(10, (log10(target)).rounded(.down))
        for factor in [1.0, 2, 5, 10] where factor * magnitude >= target * (1 - 1e-12) {
            return factor * magnitude
        }
        return 10 * magnitude
    }
}
