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
/// Kernart; zwischen Gruppen mehr Abstand als zwischen Kernen. Kernarten unterscheiden sich so auch ohne Farbe. Reicht die
/// Breite nicht (Ultra), brechen ganze Gruppen um. Jeder Ring ist ein eigenes VoiceOver-Element.
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

    let groups: [Group]

    public init(groups: [Group]) {
        self.groups = groups
    }

    static let ringSpacing = InstrumentSpacing.inline

    public var body: some View {
        LegendFlow(spacing: InstrumentSpacing.bar, lineSpacing: InstrumentSpacing.group) {
            ForEach(groups) { group in
                CoreRingGroup(group: group)
            }
        }
        .renderProbe("CoreRingBoard")
    }
}

/// Eine Gruppe der `CoreRingBoard`: Kürzel und Ringe.
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
                    .accessibilityHidden(true)
            }
            HStack(spacing: CoreRingBoard.ringSpacing) {
                ForEach(group.rings) { ring in
                    LoadRing(fraction: ring.load, color: color)
                        .frame(width: InstrumentSize.coreRing, height: InstrumentSize.coreRing)
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
