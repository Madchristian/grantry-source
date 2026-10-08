import ManagerKit
import SwiftUI

/// Verlaufslinie über `values` (älteste links), skaliert auf `maximum`; ohne Werte oder bei `maximum` 0 eine Grundlinie.
/// Mit `capacity` steht jeder Wert an seinem Platz von `capacity` Plätzen, rechtsbündig – ein kurzer Verlauf füllt dann
/// nur den rechten Teil, statt gestreckt zu werden.
struct SparklineShape: Shape {
    let values: [Double]
    let maximum: Double
    var capacity: Int?

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, maximum > 0 else {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            return path
        }
        let slots = max(capacity ?? values.count, values.count)
        let step = rect.width / CGFloat(slots - 1)
        let offset = slots - values.count
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: rect.minX + CGFloat(offset + index) * step,
                                y: rect.maxY - CGFloat(min(max(value / maximum, 0), 1)) * rect.height)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

/// Verlauf von Datenraten: empfangen in der Akzentfarbe, gesendet in Sekundärfarbe, gemeinsame Skala.
struct TrafficSparkline: View {
    let history: [TrafficRate]
    /// Siehe `SparklineShape.capacity`.
    var capacity: Int?
    let help: LocalizedStringKey

    var body: some View {
        let maximum = history.map { max($0.download, $0.upload) }.max() ?? 0
        ZStack {
            SparklineShape(values: history.map(\.upload), maximum: maximum, capacity: capacity)
                .stroke(.secondary, lineWidth: 1)
            SparklineShape(values: history.map(\.download), maximum: maximum, capacity: capacity)
                .stroke(Color.accentColor, lineWidth: 1.5)
        }
        .help(Text(help))
        .accessibilityElement()
        .accessibilityLabel(Text(help))
        .accessibilityValue(Text(verbatim: "Höchstwert \(TrafficFormat.rate(maximum))"))
    }
}
