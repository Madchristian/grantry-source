import CoreGraphics
import SwiftUI

/// Mini-Graph ohne Laufband und Effekte, etwa im Vorlagenbild der Menüleiste (Spec 2026-11-06 §2): `capacity` Plätze
/// gleichmäßig über die Breite, die Werte rechtsbündig – ein kurzer Verlauf füllt nur den rechten Teil. Werte 0…1,
/// außerhalb begrenzt; Lücken (`nil`, nicht endlich) trennen die Kurve. Monotone Interpolation wie `LiveGraph`: kein
/// Ausschlag über den Rand. y wächst nach unten (SwiftUI, gespiegelter `NSImage`-Kontext).
public enum SparklineGeometry {
    /// Zusammenhängende Abschnitte als Punkte in `rect`.
    public static func segments(_ values: [Double?], capacity: Int, in rect: CGRect) -> [[CGPoint]] {
        let slots = max(capacity, values.count, 2)
        let step = rect.width / CGFloat(slots - 1)
        let offset = slots - values.count
        var segments: [[CGPoint]] = [], current: [CGPoint] = []
        for (index, value) in values.enumerated() {
            guard let value, value.isFinite else {
                if !current.isEmpty { segments.append(current) }
                current = []
                continue
            }
            let share = CGFloat(min(max(value, 0), 1))
            current.append(CGPoint(x: rect.minX + CGFloat(offset + index) * step, y: rect.maxY - share * rect.height))
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// Kurve durch alle Abschnitte.
    public static func line(_ values: [Double?], capacity: Int, in rect: CGRect) -> Path {
        var path = Path()
        for segment in segments(values, capacity: capacity, in: rect) where segment.count > 1 {
            path.addPath(MonotoneCurve.path(through: segment))
        }
        return path
    }

    /// Fläche unter der Kurve bis zum unteren Rand von `rect`.
    public static func area(_ values: [Double?], capacity: Int, in rect: CGRect) -> Path {
        var path = Path()
        for segment in segments(values, capacity: capacity, in: rect) where segment.count > 1 {
            var area = MonotoneCurve.path(through: segment)
            area.addLine(to: CGPoint(x: segment[segment.count - 1].x, y: rect.maxY))
            area.addLine(to: CGPoint(x: segment[0].x, y: rect.maxY))
            area.closeSubpath()
            path.addPath(area)
        }
        return path
    }
}
