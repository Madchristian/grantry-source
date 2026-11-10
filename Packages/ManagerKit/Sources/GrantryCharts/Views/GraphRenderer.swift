import SwiftUI

/// Zeichnet eine Reihe in eine `Plot`, Gestaltung „Lagebild“ (§3.4): Fläche unter der Kurve, ruhige Linie
/// ohne Leuchten, Peilpunkt am aktuellen Wert; dazu das Punktraster. Gemeinsam für alle Graphen, damit sie gleich
/// aussehen. Das Bild hängt nur von den Werten ab, nicht von der Uhr: Gezeichnet wird je Messpunkt einmal
/// (Leistungsbudget Spec §4, siehe `LiveGraph`).
struct GraphRenderer {
    let style: ChartStyle
    let color: Color

    enum Baseline {
        case bottom, top
    }

    /// Punktraster: Punkte bei ¼, ½ und ¾ der Höhe in `columns` Spalten, dazu die Grundlinie – keine Linien, kein dichtes
    /// Quadratraster. Kleine Graphen nehmen weniger Spalten; `baseline` `nil` (Spiegel-Graph) zeichnet keine Grundlinie.
    func drawGrid(in context: inout PlotContext, size: CGSize, columns: Int = 12, baseline: Baseline? = .bottom) {
        let count = max(columns, 1)
        drawGrid(in: &context, size: size, positions: (0...count).map { Double($0) / Double(count) }, baseline: baseline)
    }

    /// Punktraster mit Spalten an `positions` (Anteil der Breite), etwa an den Marken einer Uhrzeit-Achse.
    func drawGrid(in context: inout PlotContext, size: CGSize, positions: [Double], baseline: Baseline? = .bottom) {
        let dot = Color.primary.opacity(style.glows ? InstrumentOpacity.gridDot : InstrumentOpacity.gridDotIncreased)
        var dots = Path()
        for row in [0.25, 0.5, 0.75] {
            for position in positions {
                let x = size.width * CGFloat(position)
                let y = size.height * (1 - row)
                dots.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
            }
        }
        context.fill(dots, with: .color(dot))
        guard let baseline else { return }
        var base = Path()
        let baseY = baseline == .bottom ? size.height - InstrumentStroke.base / 2 : InstrumentStroke.base / 2
        base.move(to: CGPoint(x: 0, y: baseY))
        base.addLine(to: CGPoint(x: size.width, y: baseY))
        context.stroke(base, with: .color(.primary.opacity(InstrumentOpacity.secondaryLine)), lineWidth: InstrumentStroke.base)
    }

    func drawSeries(_ segments: [[CGPoint]], in context: inout PlotContext, size: CGSize,
                    baseline: Baseline = .bottom, showsHead: Bool = true, fills: Bool = true) {
        let baseY = baseline == .bottom ? size.height : 0
        for points in segments where !points.isEmpty {
            let line = MonotoneCurve.path(through: points)
            if fills {
                var area = line
                area.addLine(to: CGPoint(x: points[points.count - 1].x, y: baseY))
                area.addLine(to: CGPoint(x: points[0].x, y: baseY))
                area.closeSubpath()
                let crest = baseline == .bottom ? points.map(\.y).min() ?? 0 : points.map(\.y).max() ?? size.height
                context.fill(area, with: .linearGradient(
                    Gradient(colors: [color.opacity(InstrumentOpacity.area), color.opacity(0)]),
                    startPoint: CGPoint(x: 0, y: crest), endPoint: CGPoint(x: 0, y: baseY)
                ))
            }
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: style.lineWidth, lineCap: .round,
                                                                         lineJoin: .round))
        }
        // Der Peilpunkt sitzt nur am neuesten Wert, also am Ende des letzten Abschnitts – nicht an jeder Lücke.
        if showsHead, let last = segments.last(where: { !$0.isEmpty }),
           let head = ChartGeometry.head(of: last, atX: size.width - style.lineWidth) {
            PeilPoint.draw(at: CGPoint(x: min(head.x, size.width - InstrumentSize.peilPoint), y: head.y), color: color,
                           echoes: style.glows, in: &context)
        }
    }

    /// Hülle einer verdichteten Reihe: Fläche zwischen Maximum (`upper`) und Minimum (`lower`) je Spalte, Abschnitt für
    /// Abschnitt – Spitzen bleiben sichtbar, auch wenn eine Spalte viele Messpunkte zusammenfasst (§ 4.4 Regel 5).
    func drawEnvelope(upper: [[CGPoint]], lower: [[CGPoint]], in context: inout PlotContext) {
        for (top, bottom) in zip(upper, lower) where top.count > 1 && top.count == bottom.count {
            // Ein Umriss: `addLines` begänne mit dem Minimum einen zweiten Teilpfad.
            var band = Path()
            band.move(to: top[0])
            for point in top.dropFirst() + bottom.reversed() { band.addLine(to: point) }
            band.closeSubpath()
            context.fill(band, with: .color(color.opacity(InstrumentOpacity.track)))
        }
    }
}
