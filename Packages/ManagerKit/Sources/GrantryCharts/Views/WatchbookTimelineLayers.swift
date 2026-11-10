import SwiftUI

/// Ereignisleiste des Wachbuchs (Spec 2026-11-08 § 5.1): oben Befunde als Spur über ihrer Dauer mit Befund-Punkt am
/// Beginn (Bernstein, kritisch im Ton `critical`), darunter Änderungen und Systemereignisse als neutrale Marken mit dem
/// Symbol der Quelle; zu dicht liegende Marken stehen als eine mit ihrer Zahl. VoiceOver liest die Ereignisse als Liste.
struct WatchbookEventBar: View {
    let marks: [WatchbookMarkContent]

    @Environment(\.colorScheme) private var colorScheme

    private typealias Geometry = WatchbookTimelineGeometry

    var body: some View {
        Plot("WatchbookEventBar") { context, size in
            drawNeutral(in: &context, size: size)
            drawFindings(in: &context, size: size)
        }
        .renderProbe("WatchbookEventBar")
        .accessibilityReading(Text("Ereignisse"), value: marks.isEmpty ? Text("keine") : Text(verbatim: ""))
        .accessibilityRepresentation {
            VStack {
                ForEach(marks) { Text(verbatim: $0.text) }
            }
        }
    }

    private func drawFindings(in context: inout PlotContext, size: CGSize) {
        let centre = InstrumentSize.findingDot / 2 + InstrumentSpacing.stack
        let height = InstrumentSize.spurCard
        for mark in marks where mark.isFinding {
            let color = (mark.style == .critical ? StatusTone.critical : .finding).color(in: colorScheme)
            let start = CGFloat(mark.start) * size.width, end = CGFloat(mark.end) * size.width
            let span = CGRect(x: start, y: centre - height / 2, width: max(end - start, height), height: height)
            context.fill(Path(roundedRect: span, cornerRadius: height / 2, style: .continuous), with: .color(color))
            let dot = InstrumentSize.findingDot
            let x = min(max(start, dot / 2 + InstrumentSpacing.stack), size.width - dot / 2 - InstrumentSpacing.stack)
            let ring = dot + InstrumentSpacing.stack * 2
            context.fill(Path(ellipseIn: CGRect(x: x - ring / 2, y: centre - ring / 2, width: ring, height: ring)),
                         with: .color(InstrumentSurface.panel(colorScheme)))
            context.fill(Path(ellipseIn: CGRect(x: x - dot / 2, y: centre - dot / 2, width: dot, height: dot)),
                         with: .color(color))
        }
    }

    private func drawNeutral(in context: inout PlotContext, size: CGSize) {
        let neutral = marks.filter { !$0.isFinding }
        let diameter = InstrumentSize.eventMark
        let centre = size.height - diameter / 2
        let line = Color.primary.opacity(InstrumentOpacity.secondaryLine)
        for mark in neutral where mark.end > mark.start {
            var span = Path()
            span.move(to: CGPoint(x: CGFloat(mark.start) * size.width, y: centre))
            span.addLine(to: CGPoint(x: CGFloat(mark.end) * size.width, y: centre))
            context.stroke(span, with: .color(line),
                           style: StrokeStyle(lineWidth: InstrumentStroke.border, lineCap: .round,
                                              dash: [InstrumentSpacing.stack, InstrumentSpacing.inline]))
        }
        for group in Geometry.groups(neutral, width: size.width, spacing: diameter + InstrumentSpacing.stack) {
            let x = min(max(group.x, diameter / 2), size.width - diameter / 2)
            let circle = Path(ellipseIn: CGRect(x: x - diameter / 2, y: centre - diameter / 2, width: diameter,
                                                height: diameter))
            context.fill(circle, with: .color(InstrumentSurface.panel(colorScheme)))
            context.fill(circle, with: .color(.primary.opacity(InstrumentOpacity.well)))
            context.stroke(circle, with: .color(line), lineWidth: InstrumentStroke.border)
            let label = group.marks.count > 1
                ? Text(verbatim: "\(group.marks.count)").font(InstrumentFont.micro.weight(.semibold))
                : Text(Image(systemName: group.first.symbol ?? "circle.fill")).font(InstrumentFont.micro)
            context.draw(label.foregroundStyle(.instrumentSecondary), at: CGPoint(x: x, y: centre))
        }
    }
}

/// Schmales Zustandsband (Thermik): Abschnitte gleichen Tons. Nur Auffälliges ist eingefärbt (Befund, kritisch);
/// `neutral` (normal) ist eine Bahn ohne Farbe, Ungemessenes bleibt ganz leer – so unterscheiden sich beide
/// (Entscheidung Christian, 08.11.2026).
struct WatchbookStateBand: View {
    let tones: [StatusTone?]

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let quiet = Color.primary.opacity(contrast == .increased ? InstrumentOpacity.quietBandIncreased
            : InstrumentOpacity.quietBand)
        Plot("WatchbookStateBand") { context, size in
            let count = CGFloat(max(tones.count, 1))
            for run in WatchbookTimelineGeometry.runs(tones) {
                let start = CGFloat(run.columns.lowerBound) / count * size.width
                let end = CGFloat(run.columns.upperBound) / count * size.width
                let color = run.tone == .neutral ? quiet : run.tone.color(in: colorScheme)
                context.fill(Path(roundedRect: CGRect(x: start, y: 0, width: end - start, height: size.height),
                                  cornerRadius: size.height / 2, style: .continuous), with: .color(color))
            }
        }
        .renderProbe("WatchbookStateBand")
        .accessibilityHidden(true)
    }
}

/// Zeitmarke über Ereignisleiste, Spuren und Thermikband: Klick oder Ziehen wählt die Spalte unter dem Zeiger, die
/// Pfeiltasten verschieben um einen Schritt, Escape entfernt sie. Senkrechte Linie im Fokusverlauf (Auswahl, § 2.4); ohne
/// Zeitmarke zeichnet die Ebene nichts. Für VoiceOver ein einstellbares Element.
struct WatchbookMarkerLayer: View {
    @Binding var column: Int?
    let count: Int
    let step: Int
    let time: String?

    @State private var width: CGFloat = 0
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private typealias Geometry = WatchbookTimelineGeometry

    var body: some View {
        Plot("WatchbookMarker") { context, size in
            guard let column, count > 0 else { return }
            let x = Geometry.x(ofColumn: column, count: count, width: size.width)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            let gradient = PlotContext.Shading.linearGradient(
                GrantryBrand.focusGradient(colorScheme), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height))
            context.stroke(line, with: gradient, lineWidth: InstrumentStroke.focus)
            let dot = InstrumentSize.findingDotSmall
            context.fill(Path(ellipseIn: CGRect(x: x - dot / 2, y: 0, width: dot, height: dot)), with: gradient)
        }
        .renderProbe("WatchbookMarker")
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .gesture(dragGesture)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { move(by: -1) }
        .onKeyPress(.rightArrow) { move(by: 1) }
        .onKeyPress(.escape) {
            guard column != nil else { return .ignored }
            column = nil
            return .handled
        }
        .accessibilityReading(Text("Zeitmarke"),
                              value: column == nil ? Text("keine, neuester Stand") : Text(verbatim: time ?? ""))
        .accessibilityAdjustableAction { direction in
            _ = move(by: direction == .increment ? 1 : -1)
        }
        .accessibilityIdentifier("watchbookMarker")
    }

    /// Klick und Ziehen: Die Spalte folgt dem Zeiger, ohne Mindestweg.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                isFocused = true
                guard let selected = Geometry.column(atX: drag.location.x, count: count, width: width),
                      selected != column else { return }
                column = selected
            }
    }

    private func move(by direction: Int) -> KeyPress.Result {
        guard let moved = Geometry.moved(column, by: direction, step: step, count: count) else { return .ignored }
        if moved != column { column = moved }
        return .handled
    }
}

/// Beschriftung der Zeitachse an ihren Anteilen; die erste und die letzte stehen bündig am Rand.
struct WatchbookAxis: View {
    let ticks: [WatchbookAxisTick]

    var body: some View {
        WatchbookAxisLayout {
            ForEach(ticks, id: \.self) { tick in
                Text(verbatim: tick.label).layoutValue(key: WatchbookAxisPosition.self, value: tick.position)
            }
        }
        .font(InstrumentFont.micro.monospacedDigit())
        .foregroundStyle(.instrumentSecondary)
        .lineLimit(1)
        .accessibilityHidden(true)
    }
}

private struct WatchbookAxisPosition: LayoutValueKey {
    static let defaultValue = 0.0
}

private struct WatchbookAxisLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let centre = bounds.minX + bounds.width * subview[WatchbookAxisPosition.self]
            let x = min(max(centre - size.width / 2, bounds.minX), bounds.maxX - size.width)
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: .unspecified)
        }
    }
}
