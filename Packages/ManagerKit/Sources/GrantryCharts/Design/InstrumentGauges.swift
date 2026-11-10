import SwiftUI

/// Spur (§3.5): durchgehende Bahn mit Kerben bei ¼, ½, ¾, gefüllt bis zum Wert in der Farbe der Messgröße. Ersetzt die
/// LED-Leisten. Zeichnet nur bei neuem Wert; ab dem kleinsten Wert über 0 sichtbar gefüllt. `nil` heißt „keine
/// Messung“: Bahn ohne Füllung. Aus Formen statt `Canvas`: Ein `Canvas` legt einen eigenen Grafikpuffer an, im Popover der
/// Menüleiste kostete das rund 280 MB (Bewertung 2026.11.9/1510, Mangel 1).
public struct Spur: View {
    let fraction: Double?
    let color: Color
    let label: String

    @Environment(\.colorScheme) private var colorScheme

    public init(fraction: Double?, color: Color, label: String = "") {
        self.fraction = fraction.map { min(max($0.isFinite ? $0 : 0, 0), 1) }
        self.color = color
        self.label = label
    }

    public var body: some View {
        ZStack {
            SpurShape(part: .track).fill(color.opacity(InstrumentOpacity.track))
            SpurShape(part: .filled(fraction)).fill(color)
            SpurShape(part: .notches).fill(InstrumentSurface.panel(colorScheme))
        }
        .renderProbe("Spur")
        .accessibilityReading(Text(verbatim: label),
                              value: Text(fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) }
                                  ?? String(localized: "keine Messung")))
        // Ohne Beschriftung gehört die Spur zu einem Wert daneben; allein gelesen hätte „37 %“ keinen Bezug.
        .accessibilityHidden(label.isEmpty)
    }

    /// Breite der Füllung: mindestens eine Bahnhöhe, sobald der Wert über 0 liegt.
    nonisolated static func filledWidth(fraction: Double?, width: CGFloat, height: CGFloat) -> CGFloat {
        guard let fraction, fraction > 0 else { return 0 }
        return min(width, max(height, width * fraction))
    }

}

/// Bahn, Füllung bis zum Wert oder Kerben bei ¼, ½, ¾ einer `Spur`.
struct SpurShape: Shape {
    enum Part {
        case track, filled(Double?), notches
    }

    let part: Part

    func path(in rect: CGRect) -> Path {
        let radius = rect.height / 2
        switch part {
        case .track:
            return Path(roundedRect: rect, cornerRadius: radius)
        case .filled(let fraction):
            let width = Spur.filledWidth(fraction: fraction, width: rect.width, height: rect.height)
            guard width > 0 else { return Path() }
            return Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height),
                        cornerRadius: radius)
        case .notches:
            var path = Path()
            for quarter in [0.25, 0.5, 0.75] {
                let x = rect.minX + rect.width * quarter
                path.addRect(CGRect(x: x - InstrumentStroke.base, y: rect.minY, width: InstrumentStroke.base * 2,
                                    height: rect.height))
            }
            return path
        }
    }
}

/// Bogen (§3.5): 270° ab unten links mit Teilstrichen, Füllung in der Farbe der Messgröße bzw. des Tons, Peilpunkt am
/// Ende der Füllung; Wert und Titel in der Mitte. Übergänge nur bei deutlichen Sprüngen (`ValueTransition`).
public struct ArcGauge: View {
    let fraction: Double?
    let color: Color
    let textColor: Color
    let value: String
    let caption: String

    @Environment(\.chartStyle) private var style
    @Environment(\.colorSchemeContrast) private var contrast

    public init(fraction: Double?, color: Color, textColor: Color, value: String, caption: String) {
        self.fraction = fraction.map { min(max($0.isFinite ? $0 : 0, 0), 1) }
        self.color = color
        self.textColor = textColor
        self.value = value
        self.caption = caption
    }

    static let start = 135.0
    static let sweep = 270.0

    public var body: some View {
        let fraction = fraction ?? 0
        let tick = Color.primary.opacity(contrast == .increased ? InstrumentOpacity.borderIncreased
            : InstrumentOpacity.gridDotIncreased)
        ZStack {
            Plot("ArcGauge") { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2 - InstrumentSpacing.panel
                var track = Path()
                track.addArc(center: center, radius: radius, startAngle: .degrees(Self.start),
                             endAngle: .degrees(Self.start + Self.sweep), clockwise: false)
                context.stroke(track, with: .color(color.opacity(InstrumentOpacity.track)),
                               style: StrokeStyle(lineWidth: InstrumentStroke.arc, lineCap: .round))
                if fraction > 0 {
                    var fill = Path()
                    fill.addArc(center: center, radius: radius, startAngle: .degrees(Self.start),
                                endAngle: .degrees(Self.start + Self.sweep * fraction), clockwise: false)
                    context.stroke(fill, with: .color(color),
                                   style: StrokeStyle(lineWidth: InstrumentStroke.arc, lineCap: .round))
                }
                for step in 0...10 {
                    let angle = Angle.degrees(Self.start + Self.sweep * Double(step) / 10).radians
                    let inner = radius + InstrumentStroke.arc, outer = inner + (step % 5 == 0 ? 5 : 3)
                    var mark = Path()
                    mark.move(to: CGPoint(x: center.x + inner * cos(angle), y: center.y + inner * sin(angle)))
                    mark.addLine(to: CGPoint(x: center.x + outer * cos(angle), y: center.y + outer * sin(angle)))
                    context.stroke(mark, with: .color(tick), lineWidth: InstrumentStroke.echo)
                }
                let head = Angle.degrees(Self.start + Self.sweep * fraction).radians
                PeilPoint.draw(at: CGPoint(x: center.x + radius * cos(head), y: center.y + radius * sin(head)),
                               color: color, echoes: style.glows, in: &context)
            }
            .animatesSteps(of: fraction, when: style.animates)
            VStack(spacing: 0) {
                Text(verbatim: value).font(InstrumentFont.valueLarge).foregroundStyle(textColor)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(verbatim: caption).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary).lineLimit(1)
            }
            // Neben dem Bogen, nicht an ihm: Dort ist der Übergang erlaubt (`ValueTransition`).
            .renderProbe("ArcGauge")
            .padding(.horizontal, InstrumentSpacing.empty)
        }
        .accessibilityReading(Text(verbatim: caption), value: Text(verbatim: value))
    }
}

/// Peilpunkt (§3.4): Punkt am aktuellen Wert mit zwei Ringen wie ein Radar-Echo; statisch, ohne Puls. Bei „Kontrast
/// erhöhen“ ohne Ringe.
enum PeilPoint {
    static func draw(at point: CGPoint, color: Color, echoes: Bool, in context: inout PlotContext) {
        if echoes {
            for (radius, opacity) in [(11.0, InstrumentOpacity.echoOuter), (7.0, InstrumentOpacity.echoInner)] {
                context.stroke(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2,
                                                      height: radius * 2)),
                               with: .color(color.opacity(opacity)), lineWidth: InstrumentStroke.echo)
            }
        }
        let dot = InstrumentSize.peilPoint
        context.fill(Path(ellipseIn: CGRect(x: point.x - dot, y: point.y - dot, width: dot * 2, height: dot * 2)),
                     with: .color(color))
    }
}
