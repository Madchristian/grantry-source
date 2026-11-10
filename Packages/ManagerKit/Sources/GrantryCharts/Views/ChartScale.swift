/// Wertebereich eines Graphen: fest (Auslastung 0…1) oder automatisch mit runder, weich wechselnder Obergrenze.
public enum ChartScale: Equatable, Sendable {
    case fixed(ClosedRange<Double>)
    case automatic(minimum: Double)

    /// Obergrenze für die sichtbaren Werte.
    public func upperBound(for values: [Double?]) -> Double {
        switch self {
        case .fixed(let range): range.upperBound
        case .automatic(let minimum): NiceScale.ceiling(values.compactMap { $0 }.max() ?? 0, minimum: minimum)
        }
    }

    /// Werte für die Achsenbeschriftung: oben, Mitte, unten (wie `GraphAxes` sie zeigt).
    public func axisMarks(for values: [Double?]) -> [Double] {
        let upper = upperBound(for: values)
        return [upper, (upper + lowerBound) / 2, lowerBound]
    }

    var lowerBound: Double {
        if case .fixed(let range) = self { range.lowerBound } else { 0 }
    }
}
