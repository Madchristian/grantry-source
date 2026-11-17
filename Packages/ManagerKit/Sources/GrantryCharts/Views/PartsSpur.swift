import SwiftUI

/// Spur mit Anteilen (Übersichts-Baukasten, Kachel Arbeitsspeicher, #502): wie die `Spur` eine durchgehende Bahn, aber
/// mit mehreren Teilen hintereinander in ihren Farben, getrennt durch Kerben in Panelfarbe; der Rest ist die Bahn
/// („frei“). Teile tragen ihre Bedeutung über die Legende daneben, nie über die Farbe allein. Aus Formen statt `Canvas`
/// (#491); zeichnet nur bei neuen Teilen, ohne Übergang. Ohne Beschriftung gehört sie zu einem Wert daneben und bleibt
/// für VoiceOver verborgen.
public struct PartsSpur: View {
    let parts: [ValueRing.Part]
    let label: String
    let value: String

    @Environment(\.self) private var environment

    /// - Parameters:
    ///   - label: Name für VoiceOver („Arbeitsspeicher belegt“); leer, wenn die Kachel die Teile selbst nennt.
    ///   - value: Teile für VoiceOver („App 25 %, Zug. 13 %“).
    public init(parts: [ValueRing.Part], label: String, value: String) {
        self.parts = parts
        self.label = label
        self.value = value
    }

    public var body: some View {
        let spans = ValueRing.spans(parts.map(\.fraction))
        ZStack {
            Capsule().fill(Color.primary.opacity(InstrumentOpacity.track))
            ForEach(Array(zip(spans, parts).enumerated()), id: \.offset) { _, pair in
                PartsSpurShape(part: .segment(start: pair.0.start, end: pair.0.end))
                    .fill(environment.instrumentColor(pair.1.hue))
            }
            PartsSpurShape(part: .notches(Self.notches(parts.map(\.fraction))))
                .fill(InstrumentSurface.panel(environment.colorScheme))
        }
        .clipShape(Capsule())
        .renderProbe("PartsSpur")
        .accessibilityReading(Text(verbatim: label), value: Text(verbatim: value))
        .accessibilityHidden(label.isEmpty)
    }

    /// Lage der Kerben (0…1): zwischen zwei gefüllten Teilen, nicht am Rand und nicht hinter einem leeren Teil.
    nonisolated static func notches(_ fractions: [Double]) -> [Double] {
        let filled = ValueRing.spans(fractions).filter { $0.end > $0.start }
        return filled.dropLast().map(\.end).filter { $0 < 1 }
    }
}

/// Teil einer `PartsSpur` oder ihre Kerben.
struct PartsSpurShape: Shape {
    enum Part {
        case segment(start: Double, end: Double)
        case notches([Double])
    }

    let part: Part

    func path(in rect: CGRect) -> Path {
        switch part {
        case .segment(let start, let end):
            return Path(CGRect(x: rect.minX + rect.width * start, y: rect.minY, width: rect.width * (end - start),
                               height: rect.height))
        case .notches(let positions):
            var path = Path()
            for position in positions {
                let x = rect.minX + rect.width * position
                path.addRect(CGRect(x: x - InstrumentStroke.base, y: rect.minY, width: InstrumentStroke.base * 2,
                                    height: rect.height))
            }
            return path
        }
    }
}
