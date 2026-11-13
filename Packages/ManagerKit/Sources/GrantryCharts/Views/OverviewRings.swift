import SwiftUI

/// Lastring eines Kerns (Übersicht der Menüleiste, #495): Bahn und Bogen mit dem Anteil in der Farbe der Kernart, ohne
/// Mittelpunkt und ohne Übergang; ohne eigene Beschriftung – wer ihn zeigt, nennt Kern und Wert. Aus Formen statt
/// `Canvas`: Ein `Canvas` legt einen eigenen Grafikpuffer an, im Popover der Menüleiste rund 280 MB (Bewertung
/// 2026.11.9/1510, Mangel 1). `nil` heißt „keine Messung“: nur die Bahn.
public struct LoadRing: View {
    let fraction: Double?
    let color: Color
    let lineWidth: CGFloat

    public init(fraction: Double?, color: Color, lineWidth: CGFloat = InstrumentStroke.ring) {
        self.fraction = fraction
        self.color = color
        self.lineWidth = lineWidth
    }

    public var body: some View {
        ZStack {
            Circle().stroke(color.opacity(InstrumentOpacity.track), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: Self.trimmed(fraction))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
    }

    /// Anteil für den Bogen: 0…1, ohne Messung oder ungültig 0.
    nonisolated static func trimmed(_ fraction: Double?) -> Double {
        guard let fraction, fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
    }
}

/// Wertring (#495): ein oder mehrere Teile hintereinander auf einer Bahn, Wert in der Mitte, Beschriftung unter dem Ring.
/// Teile tragen ihre Bedeutung über die Legende daneben, nie über die Farbe allein. Wert und Beschriftung liest VoiceOver
/// als ein Element.
public struct ValueRing: View {
    public struct Part: Sendable {
        public let fraction: Double
        public let hue: InstrumentHue

        public init(fraction: Double, hue: InstrumentHue) {
            self.fraction = fraction
            self.hue = hue
        }
    }

    let parts: [Part]
    let value: String
    let caption: String

    @Environment(\.self) private var environment

    public init(parts: [Part], value: String, caption: String) {
        self.parts = parts
        self.value = value
        self.caption = caption
    }

    static let lineWidth: CGFloat = 6

    public var body: some View {
        let spans = Self.spans(parts.map(\.fraction))
        let track = parts.first.map { environment.instrumentColor($0.hue) } ?? .instrumentSecondary
        VStack(spacing: InstrumentSpacing.stack) {
            ZStack {
                Circle().stroke(track.opacity(InstrumentOpacity.track), lineWidth: Self.lineWidth)
                ForEach(Array(zip(spans, parts).enumerated()), id: \.offset) { _, pair in
                    Circle()
                        .trim(from: pair.0.start, to: pair.0.end)
                        .stroke(environment.instrumentColor(pair.1.hue),
                                style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
                Text(verbatim: value).font(InstrumentFont.tileValue).lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.horizontal, Self.lineWidth)
            }
            .padding(Self.lineWidth / 2)
            .frame(width: InstrumentSize.valueRing, height: InstrumentSize.valueRing)
            Text(verbatim: caption).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary).lineLimit(1)
        }
        .renderProbe("ValueRing")
        .accessibilityReading(Text(verbatim: caption), value: Text(verbatim: value))
    }

    /// Abschnitte der Teile auf dem Kreis (0…1), hintereinander; was über den vollen Kreis ginge, entfällt.
    nonisolated static func spans(_ fractions: [Double]) -> [(start: Double, end: Double)] {
        var start = 0.0
        return fractions.map { fraction in
            let end = min(start + max(fraction.isFinite ? fraction : 0, 0), 1)
            defer { start = end }
            return (start, end)
        }
    }
}

/// Kernringe je Cluster (#495): je Gruppe ihr Kürzel („P0“, „E“) über einer Reihe kleiner Lastringe in der Farbe der
/// Kernart; zwischen Gruppen mehr Abstand als zwischen Kernen. Kernarten unterscheiden sich so auch ohne Farbe. Die Ringe
/// wachsen, bis die Reihe die Breite füllt (höchstens `InstrumentSize.coreRingWide`); reicht die Breite auch für die
/// kleinsten nicht (Ultra), brechen ganze Gruppen um. Jeder Ring ist ein eigenes VoiceOver-Element.
public struct CoreRingBoard: View {
    public struct Ring: Identifiable, Sendable, Equatable {
        public let id: Int
        public let load: Double?
        public let label: String
        public let value: String

        public init(id: Int, load: Double?, label: String, value: String) {
            self.id = id
            self.load = load
            self.label = label
            self.value = value
        }
    }

    public struct Group: Identifiable, Sendable, Equatable {
        public let tag: String?
        public let hue: InstrumentHue
        public let rings: [Ring]

        public var id: Int { rings.first?.id ?? -1 }

        public init(tag: String?, hue: InstrumentHue, rings: [Ring]) {
            self.tag = tag
            self.hue = hue
            self.rings = rings
        }
    }

    /// Ringgröße und Zeilen (Gruppen je Zeile als Indizes) für eine Breite.
    struct Arrangement: Equatable {
        let ringSize: CGFloat
        let lines: [[Int]]
    }

    let groups: [Group]

    public init(groups: [Group]) {
        self.groups = groups
    }

    static let ringSpacing = InstrumentSpacing.inline
    static let groupSpacing = InstrumentSpacing.bar
    static let lineSpacing = InstrumentSpacing.group

    public var body: some View {
        CoreRingFlow(ringCounts: groups.map(\.rings.count)) {
            ForEach(groups) { group in
                CoreRingGroup(group: group)
            }
        }
        .renderProbe("CoreRingBoard")
    }

    /// Breite einer Gruppe mit `rings` Ringen der Größe `ringSize`.
    nonisolated static func groupWidth(rings: Int, ringSize: CGFloat) -> CGFloat {
        CGFloat(rings) * ringSize + CGFloat(max(rings - 1, 0)) * ringSpacing
    }

    /// Passen alle Gruppen mit den kleinsten Ringen in eine Zeile, wachsen die Ringe auf ganze Punkte, bis die Zeile die
    /// Breite füllt oder die Obergrenze erreicht ist. Sonst bleiben sie klein, und ganze Gruppen brechen um.
    nonisolated static func arrangement(ringCounts: [Int], width: CGFloat) -> Arrangement {
        let minimum = InstrumentSize.coreRing
        let rings = ringCounts.reduce(0, +)
        guard rings > 0, width.isFinite else {
            return Arrangement(ringSize: minimum, lines: ringCounts.isEmpty ? [] : [Array(ringCounts.indices)])
        }
        let gaps = CGFloat(ringCounts.count - 1) * groupSpacing
            + ringCounts.map { groupWidth(rings: $0, ringSize: 0) }.reduce(0, +)
        let fitting = ((width - gaps) / CGFloat(rings)).rounded(.down)
        if fitting >= minimum {
            return Arrangement(ringSize: min(fitting, InstrumentSize.coreRingWide), lines: [Array(ringCounts.indices)])
        }
        var lines: [[Int]] = [[]]
        var used: CGFloat = 0
        for (index, count) in ringCounts.enumerated() {
            let groupWidth = groupWidth(rings: count, ringSize: minimum)
            if !lines[lines.count - 1].isEmpty, used + groupSpacing + groupWidth > width {
                lines.append([])
                used = 0
            }
            used += (lines[lines.count - 1].isEmpty ? 0 : groupSpacing) + groupWidth
            lines[lines.count - 1].append(index)
        }
        return Arrangement(ringSize: minimum, lines: lines)
    }
}

/// Anordnung der Gruppen einer `CoreRingBoard` nach `CoreRingBoard.arrangement`; je Gruppe genau eine Unteransicht.
private struct CoreRingFlow: Layout {
    let ringCounts: [Int]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let frames = frames(width: width ?? .infinity, subviews: subviews)
        return CGSize(width: width ?? frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        guard subviews.count == ringCounts.count else { return [] }
        let arrangement = CoreRingBoard.arrangement(ringCounts: ringCounts, width: width)
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var top: CGFloat = 0
        for line in arrangement.lines {
            var left: CGFloat = 0
            var height: CGFloat = 0
            for index in line {
                let groupWidth = CoreRingBoard.groupWidth(rings: ringCounts[index], ringSize: arrangement.ringSize)
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: groupWidth, height: nil))
                frames[index] = CGRect(x: left, y: top, width: groupWidth, height: size.height)
                left += groupWidth + CoreRingBoard.groupSpacing
                height = max(height, size.height)
            }
            top += height + CoreRingBoard.lineSpacing
        }
        return frames
    }
}

/// Eine Gruppe der `CoreRingBoard`: Kürzel und Ringe. Die Ringe teilen sich die angebotene Breite gleichmäßig.
private struct CoreRingGroup: View {
    let group: CoreRingBoard.Group

    @Environment(\.self) private var environment

    var body: some View {
        let color = environment.instrumentColor(group.hue)
        VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
            if let tag = group.tag {
                Text(verbatim: tag)
                    .font(InstrumentFont.micro.weight(.semibold))
                    .foregroundStyle(environment.instrumentTextColor(group.hue))
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
            HStack(spacing: CoreRingBoard.ringSpacing) {
                ForEach(group.rings) { ring in
                    LoadRing(fraction: ring.load, color: color)
                        .aspectRatio(1, contentMode: .fit)
                        .accessibilityReading(Text(verbatim: ring.label), value: Text(verbatim: ring.value))
                }
            }
        }
    }
}

/// Gestapelter stiller Verlauf (#495): unten der Anteil `lower` (CPU-System), darüber bis `total` der Rest (Benutzer),
/// beide auf fester Skala 0…1 und aus Formen wie `Sparkline`.
public struct StackedSparkline: View {
    let lower: ChartSeries
    let total: ChartSeries
    let window: TimeInterval
    let colors: (lower: InstrumentHue, upper: InstrumentHue)

    @Environment(\.self) private var environment

    public init(lower: ChartSeries, total: ChartSeries, window: TimeInterval = 60,
                colors: (lower: InstrumentHue, upper: InstrumentHue)) {
        self.lower = lower
        self.total = total
        self.window = window
        self.colors = colors
    }

    public var body: some View {
        ZStack {
            SparklineTrace(series: total, scale: .fixed(0...1), window: window,
                           color: environment.instrumentColor(colors.upper))
            SparklineTrace(series: lower, scale: .fixed(0...1), window: window,
                           color: environment.instrumentColor(colors.lower))
        }
        .renderProbe("StackedSparkline")
        .background(RoundedRectangle(cornerRadius: InstrumentRadius.graph, style: .continuous)
            .fill(.primary.opacity(InstrumentOpacity.subtle)))
        .clipShape(RoundedRectangle(cornerRadius: InstrumentRadius.graph, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(Text("Verlauf"))
    }
}
