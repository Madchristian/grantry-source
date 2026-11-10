/// Höhen der Säulen eines Verlaufs: jede Säule als Anteil an einer runden Obergrenze (`NiceScale`), damit die Skala
/// beim Umschalten nicht auf krumme Werte springt. Negative und ungültige Werte zählen als 0.
struct UsageBarLayout: Equatable {
    let upperBound: Double
    let fractions: [Double]

    init(values: [Double]) {
        let clean = values.map { $0.isFinite ? max($0, 0) : 0 }
        let maximum = clean.max() ?? 0
        let upper = maximum > 0 ? NiceScale.ceiling(maximum) : 1
        upperBound = upper
        fractions = clean.map { $0 / upper }
    }

    /// Waagrechte Hilfslinien bei Vierteln der Obergrenze.
    var gridFractions: [Double] { [0.25, 0.5, 0.75, 1] }
}
