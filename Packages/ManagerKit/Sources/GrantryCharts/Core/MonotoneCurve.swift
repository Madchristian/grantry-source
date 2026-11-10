import CoreGraphics
import SwiftUI

/// Monotone kubische Interpolation nach Fritsch–Carlson: Die Kurve läuft durch alle Punkte und schwingt zwischen zwei
/// Punkten nie über deren Werte hinaus – kein Ausschlag unter 0 % oder über 100 % (Spec §4).
enum MonotoneCurve {
    /// Kurve durch `points` (nach x sortiert).
    static func path(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }
        for segment in controlPoints(for: points) {
            path.addCurve(to: segment.end, control1: segment.control1, control2: segment.control2)
        }
        return path
    }

    struct Segment: Equatable {
        let control1: CGPoint
        let control2: CGPoint
        let end: CGPoint
    }

    static func controlPoints(for points: [CGPoint]) -> [Segment] {
        let tangents = tangents(for: points)
        return points.indices.dropLast().map { index in
            let start = points[index], end = points[index + 1]
            let third = (end.x - start.x) / 3
            return Segment(control1: CGPoint(x: start.x + third, y: start.y + tangents[index] * third),
                           control2: CGPoint(x: end.x - third, y: end.y - tangents[index + 1] * third),
                           end: end)
        }
    }

    /// Steigungen je Punkt, begrenzt, damit die Kurve monoton bleibt.
    static func tangents(for points: [CGPoint]) -> [CGFloat] {
        let count = points.count
        guard count > 1 else { return Array(repeating: 0, count: count) }
        let slopes = points.indices.dropLast().map { index -> CGFloat in
            let dx = points[index + 1].x - points[index].x
            return dx == 0 ? 0 : (points[index + 1].y - points[index].y) / dx
        }
        var tangents = [CGFloat](repeating: 0, count: count)
        tangents[0] = slopes[0]
        tangents[count - 1] = slopes[count - 2]
        for index in 1..<(count - 1) {
            let left = slopes[index - 1], right = slopes[index]
            tangents[index] = left * right <= 0 ? 0 : (left + right) / 2
        }
        for index in slopes.indices {
            let slope = slopes[index]
            guard slope != 0 else {
                tangents[index] = 0
                tangents[index + 1] = 0
                continue
            }
            let alpha = tangents[index] / slope, beta = tangents[index + 1] / slope
            let magnitude = alpha * alpha + beta * beta
            if magnitude > 9 {
                let scale = 3 / magnitude.squareRoot()
                tangents[index] = scale * alpha * slope
                tangents[index + 1] = scale * beta * slope
            }
        }
        return tangents
    }
}
