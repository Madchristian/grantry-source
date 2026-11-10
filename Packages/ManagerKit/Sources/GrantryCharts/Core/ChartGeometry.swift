import CoreGraphics
import Foundation

/// Sichtbarer Ausschnitt eines Graphen: Dauer, Wertebereich und Größe in Punkten.
struct ChartViewport: Equatable {
    var window: TimeInterval
    var range: ClosedRange<Double>
    var size: CGSize
}

/// Laufband-Geometrie (Spec §4): x folgt der Zeit, y dem Wert; `renderTime` ist der Zeitpunkt am rechten Rand, in der
/// Regel der neueste Messpunkt. Alles außerhalb des Rahmens schneidet die Ansicht ab.
enum ChartGeometry {
    /// Zusammenhängende Abschnitte, an Lücken getrennt; Werte außerhalb des Bereichs werden geklemmt.
    static func segments(for series: ChartSeries, at time: Date, in viewport: ChartViewport) -> [[CGPoint]] {
        var segments: [[CGPoint]] = []
        var current: [CGPoint] = []
        for (index, value) in series.values.enumerated() {
            guard let value else {
                if !current.isEmpty { segments.append(current) }
                current = []
                continue
            }
            current.append(point(value: value, at: series.time(at: index), renderTime: time, in: viewport))
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    static func point(value: Double, at date: Date, renderTime: Date, in viewport: ChartViewport) -> CGPoint {
        CGPoint(x: x(for: date, renderTime: renderTime, in: viewport), y: y(for: value, in: viewport))
    }

    static func x(for date: Date, renderTime: Date, in viewport: ChartViewport) -> CGFloat {
        let start = renderTime.addingTimeInterval(-viewport.window)
        return CGFloat(date.timeIntervalSince(start) / viewport.window) * viewport.size.width
    }

    static func y(for value: Double, in viewport: ChartViewport) -> CGFloat {
        let span = viewport.range.upperBound - viewport.range.lowerBound
        guard span > 0 else { return viewport.size.height }
        let clamped = min(max(value, viewport.range.lowerBound), viewport.range.upperBound)
        return viewport.size.height * CGFloat(1 - (clamped - viewport.range.lowerBound) / span)
    }

    /// Spitze der Linie am rechten Rand `edge` (linear zwischen den Punkten davor und danach); `nil`, wenn kein Punkt
    /// links vom Rand liegt. Liegt der letzte Punkt schon links davon, ist er die Spitze.
    static func head(of points: [CGPoint], atX edge: CGFloat) -> CGPoint? {
        guard let afterIndex = points.firstIndex(where: { $0.x > edge }) else { return points.last }
        guard afterIndex > 0 else { return nil }
        let before = points[afterIndex - 1], after = points[afterIndex]
        let fraction = (edge - before.x) / (after.x - before.x)
        return CGPoint(x: edge, y: before.y + (after.y - before.y) * fraction)
    }

    /// Index des Werts, der `x` zeitlich am nächsten liegt, oder `nil` ohne Werte.
    static func nearestIndex(toX x: CGFloat, series: ChartSeries, renderTime: Date, in viewport: ChartViewport) -> Int? {
        guard !series.values.isEmpty, viewport.size.width > 0 else { return nil }
        let start = renderTime.addingTimeInterval(-viewport.window)
        let date = start.addingTimeInterval(Double(x / viewport.size.width) * viewport.window)
        let stepsBack = (series.latest.timeIntervalSince(date) / series.spacing).rounded()
        let index = series.values.count - 1 - Int(stepsBack)
        return series.values.indices.contains(index) ? index : nil
    }
}
