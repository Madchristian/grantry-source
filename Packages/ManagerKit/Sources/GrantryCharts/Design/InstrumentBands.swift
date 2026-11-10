import SwiftUI

/// Belegungsband (Spec 2026-11-08 § 4.2, § 5.4): eine Spur, deren Teile nebeneinander in Deckkraftstufen einer
/// Messgröße stehen (`InstrumentOpacity.bandLevels`), getrennt durch Kerben in Panelfarbe; der Rest ist die Bahn („frei“).
/// Zeichnet nur bei neuen Teilen. VoiceOver liest das Band als Liste der Teile; die Legende daneben zeigt dieselben Werte.
public struct ShareBand: View {
    /// Ein Teil des Bands: Anteil am Ganzen, Stufe von 0 (fest) bis `bandLevels.count - 1` (flüchtig).
    public struct Part: Identifiable, Hashable, Sendable {
        public let id: String
        public let title: String
        public let value: String
        public let fraction: Double
        public let level: Int

        public init(id: String, title: String, value: String, fraction: Double, level: Int) {
            self.id = id
            self.title = title
            self.value = value
            self.fraction = fraction
            self.level = level
        }
    }

    /// Lage eines Teils im Band.
    struct Segment: Equatable {
        let id: String
        let x: CGFloat
        let width: CGFloat
        let level: Int
    }

    let parts: [Part]
    let hue: InstrumentHue
    let label: String
    let free: String

    @Environment(\.self) private var environment

    /// - Parameters:
    ///   - label: Name des Bands für VoiceOver („Belegung Macintosh HD“).
    ///   - free: Wert der Bahn für VoiceOver („248 GB frei“).
    public init(parts: [Part], hue: InstrumentHue, label: String, free: String) {
        self.parts = parts
        self.hue = hue
        self.label = label
        self.free = free
    }

    public var body: some View {
        let color = environment.instrumentColor(hue)
        let notch = InstrumentSurface.panel(environment.colorScheme)
        let increased = environment.colorSchemeContrast == .increased
        Plot("ShareBand") { context, size in
            Self.draw(parts: parts, color: color, notch: notch, increased: increased, in: &context, size: size)
        }
        .clipShape(Capsule(style: .circular))
        .frame(height: InstrumentSize.band)
        .accessibilityReading(Text(verbatim: label),
                              value: Text(verbatim: Self.accessibilityValue(parts: parts, free: free)))
    }

    nonisolated static func accessibilityValue(parts: [Part], free: String) -> String {
        (parts.map { "\($0.title) \($0.value)" } + [free]).joined(separator: ", ")
    }

    /// Teile von links nach rechts; was über das Ganze hinausreicht, wird abgeschnitten. Teile über 0 sind mindestens
    /// `minimum` breit – die Breite dafür gibt der größte Teil ab, damit die Summe stimmt.
    nonisolated static func segments(_ parts: [Part], width: CGFloat, minimum: CGFloat) -> [Segment] {
        var remaining = 1.0
        var shares: [(part: Part, share: Double)] = []
        for part in parts where part.fraction.isFinite && part.fraction > 0 && remaining > 0 {
            let share = min(part.fraction, remaining)
            shares.append((part, share))
            remaining -= share
        }
        var widths = shares.map { max(minimum, width * $0.share) }
        let excess = widths.reduce(0, +) - shares.reduce(0) { $0 + width * $1.share }
        if excess > 0, let largest = widths.indices.max(by: { widths[$0] < widths[$1] }) {
            widths[largest] = max(minimum, widths[largest] - excess)
        }
        var x: CGFloat = 0
        return zip(shares, widths).map { item, width in
            defer { x += width }
            let level = min(max(item.part.level, 0), InstrumentOpacity.bandLevels.count - 1)
            return Segment(id: item.part.id, x: x, width: width, level: level)
        }
    }

    private static func draw(parts: [Part], color: Color, notch: Color, increased: Bool,
                             in context: inout PlotContext, size: CGSize) {
        let band = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
        context.fill(band, with: .color(color.opacity(InstrumentOpacity.track)))
        let segments = segments(parts, width: size.width, minimum: size.height / 2)
        for segment in segments {
            context.fill(Path(CGRect(x: segment.x, y: 0, width: segment.width, height: size.height)),
                         with: .color(color.opacity(InstrumentOpacity.bandLevels[segment.level])))
        }
        // Kerben an jedem Übergang, auch zur Bahn.
        let notchWidth = increased ? InstrumentStroke.focus : InstrumentStroke.base * 2
        for segment in segments where segment.x + segment.width < size.width {
            context.fill(Path(CGRect(x: segment.x + segment.width - notchWidth / 2, y: 0, width: notchWidth,
                                     height: size.height)), with: .color(notch))
        }
        if increased {
            context.stroke(band, with: .color(color.opacity(InstrumentOpacity.blockBorderIncreased)),
                           lineWidth: InstrumentStroke.border)
        }
    }
}

/// Legende eines Belegungsbands: Farbfeld in der Stufe des Teils, Name und Wert; frei zuletzt mit dem Feld der Bahn.
/// Die Einträge stehen in voller Länge nebeneinander und brechen um, wo die Breite endet.
public struct ShareBandLegend: View {
    let parts: [ShareBand.Part]
    let hue: InstrumentHue
    let free: (title: String, value: String)?

    public init(parts: [ShareBand.Part], hue: InstrumentHue, free: (title: String, value: String)?) {
        self.parts = parts
        self.hue = hue
        self.free = free
    }

    public var body: some View {
        LegendFlow(spacing: InstrumentSpacing.panel, lineSpacing: InstrumentSpacing.item) {
            ForEach(parts) { part in
                ShareBandLegendItem(title: part.title, value: part.value, hue: hue,
                                    opacity: InstrumentOpacity.bandLevels[min(max(part.level, 0),
                                                                              InstrumentOpacity.bandLevels.count - 1)])
            }
            if let free {
                ShareBandLegendItem(title: free.title, value: free.value, hue: hue, opacity: InstrumentOpacity.track)
            }
        }
    }
}

/// Einträge in natürlicher Breite von links nach rechts, umgebrochen am Rand.
struct LegendFlow: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? .infinity
        let frames = Self.frames(subviews.map { $0.sizeThatFits(.unspecified) }, width: width, spacing: spacing,
                                 lineSpacing: lineSpacing)
        return CGSize(width: width.isFinite ? width : frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let frames = Self.frames(sizes, width: bounds.width, spacing: spacing, lineSpacing: lineSpacing)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    nonisolated static func frames(_ sizes: [CGSize], width: CGFloat, spacing: CGFloat, lineSpacing: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var origin = CGPoint.zero
        var lineHeight: CGFloat = 0
        for size in sizes {
            if origin.x > 0, origin.x + size.width > width {
                origin = CGPoint(x: 0, y: origin.y + lineHeight + lineSpacing)
                lineHeight = 0
            }
            frames.append(CGRect(origin: origin, size: CGSize(width: min(size.width, width), height: size.height)))
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}

private struct ShareBandLegendItem: View {
    let title: String
    let value: String
    let hue: InstrumentHue
    let opacity: Double

    @Environment(\.self) private var environment

    var body: some View {
        HStack(spacing: InstrumentSpacing.item) {
            Capsule().fill(environment.instrumentColor(hue).opacity(opacity))
                .frame(width: InstrumentSize.bandSwatch.width, height: InstrumentSize.bandSwatch.height)
            Text(verbatim: title).font(InstrumentFont.label.weight(.medium)).lineLimit(1)
            Text(verbatim: value).font(InstrumentFont.label.monospacedDigit())
                .foregroundStyle(environment.instrumentTextColor(hue)).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
