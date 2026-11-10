import SwiftUI

/// Taktband eines Clusters (Chip-Tab, Spec 2026-11-08 §5.3): eine Zelle je Taktstufe mit Takt und Zeitanteil, Hitze aus
/// dem Anteil (§2.6). Ohne Verteilung steht `placeholder` im Graph-Rahmen.
public struct ClockBand: Identifiable, Hashable, Sendable {
    public struct Step: Identifiable, Hashable, Sendable {
        /// Takt in MHz – innerhalb eines Clusters eindeutig.
        public let id: Double
        public let frequency: String
        public let share: String
        /// Zeitanteil 0…1.
        public let heat: Double

        public init(id: Double, frequency: String, share: String, heat: Double) {
            self.id = id
            self.frequency = frequency
            self.share = share
            self.heat = heat
        }
    }

    public let id: String
    public let title: String
    /// Häufigste Stufe, in der Farbe der Kernart.
    public let value: String
    /// Anteil Höchsttakt.
    public let detail: String
    public let hue: InstrumentHue
    public let steps: [Step]
    public let placeholder: String
    /// VoiceOver: häufigste Stufe und Anteil Höchsttakt.
    public let accessibilityValue: String

    public init(id: String, title: String, value: String, detail: String, hue: InstrumentHue, steps: [Step],
                placeholder: String = "", accessibilityValue: String) {
        self.id = id
        self.title = title
        self.value = value
        self.detail = detail
        self.hue = hue
        self.steps = steps
        self.placeholder = placeholder
        self.accessibilityValue = accessibilityValue
    }
}

/// Thermikband: der thermische Zustand über die Zeit in Zustandstönen (§2.5); vor dem ersten bekannten Stand bleibt eine
/// Lücke.
public struct ThermalBand: Hashable, Sendable {
    public struct Segment: Hashable, Sendable {
        /// Anfang und Ende als Anteil des Zeitraums (0 = vor `window` Sekunden, 1 = jetzt).
        public let start: Double
        public let end: Double
        public let title: String
        public let tone: StatusTone

        public init(start: Double, end: Double, title: String, tone: StatusTone) {
            self.start = start
            self.end = end
            self.title = title
            self.tone = tone
        }
    }

    public let current: StatusItem
    /// Feinere Stufe laut Helper; leer ohne.
    public let detail: String
    public let segments: [Segment]
    public let window: TimeInterval
    /// VoiceOver: Verlauf in Worten.
    public let accessibilityValue: String

    public init(current: StatusItem, detail: String, segments: [Segment], window: TimeInterval,
                accessibilityValue: String) {
        self.current = current
        self.detail = detail
        self.segments = segments
        self.window = window
        self.accessibilityValue = accessibilityValue
    }
}

/// Panel „Takt und Thermik“ unter dem Chip-Grundriss: Peilkopf (Cache und Kerne je Cluster im Detail, Drosselung als
/// Befund-Punkt), je Cluster ein Taktband, darunter das Thermikband mit Zeitachse. Zeichnet nur bei neuen Daten.
public struct ClockThermalPanel: View {
    public struct Head: Hashable, Sendable {
        public let title: String
        public let detail: String
        public let value: String
        public let fraction: Double?
        /// Grund eines offenen Befunds „Drosselung“; `nil` ohne.
        public let finding: String?

        public init(title: String, detail: String, value: String, fraction: Double?, finding: String?) {
            self.title = title
            self.detail = detail
            self.value = value
            self.fraction = fraction
            self.finding = finding
        }
    }

    let head: Head
    let caption: String
    let bands: [ClockBand]
    let thermal: ThermalBand
    let thermalTitle: String

    public init(head: Head, caption: String, bands: [ClockBand], thermal: ThermalBand, thermalTitle: String) {
        self.head = head
        self.caption = caption
        self.bands = bands
        self.thermal = thermal
        self.thermalTitle = thermalTitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.group) {
            PeilHead(head.title, detail: head.detail, value: head.value, hue: .cpu, fraction: head.fraction,
                     finding: head.finding != nil, identifier: "clockThermalTitle")
            if let finding = head.finding {
                HStack(spacing: InstrumentSpacing.item) {
                    FindingDot(size: InstrumentSize.findingDotSmall)
                    Text(verbatim: finding).font(InstrumentFont.body).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            Text(verbatim: caption).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
            ForEach(bands) { band in
                VerlaufLane(title: band.title, value: band.value, detail: band.detail, hue: band.hue) {
                    ClockBandCells(band: band)
                }
                .accessibilityReading(Text(verbatim: band.title), value: Text(verbatim: band.accessibilityValue))
            }
            ThermalLane(title: thermalTitle, band: thermal)
            TimeAxisLabels(window: thermal.window).padding(.leading, InstrumentSize.laneLabel + InstrumentSpacing.panel)
        }
        .instrumentPanel()
    }
}

/// Zellen eines Taktbands nebeneinander; ohne Stufen der Grund im Graph-Rahmen.
private struct ClockBandCells: View {
    let band: ClockBand

    var body: some View {
        if band.steps.isEmpty {
            Text(verbatim: band.placeholder).font(InstrumentFont.body).foregroundStyle(.instrumentSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .graphFrame()
        } else {
            HStack(spacing: InstrumentSpacing.stack) {
                ForEach(band.steps) { step in
                    VStack(spacing: 0) {
                        Text(verbatim: step.frequency).fontWeight(.semibold)
                        Text(verbatim: step.share)
                    }
                    .font(InstrumentFont.micro.monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(HeatTile(heat: step.heat, hue: band.hue))
                }
            }
        }
    }
}

/// Thermikband mit Beschriftung links wie eine Verlaufsspur: Titel, aktueller Zustand als Chip, feinere Stufe.
private struct ThermalLane: View {
    let title: String
    let band: ThermalBand

    var body: some View {
        HStack(spacing: InstrumentSpacing.panel) {
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                Text(verbatim: title).font(InstrumentFont.body.weight(.semibold)).lineLimit(1)
                StatusChip(band.current)
                if !band.detail.isEmpty {
                    Text(verbatim: band.detail).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .frame(width: InstrumentSize.laneLabel, alignment: .leading)
            ThermalSegments(segments: band.segments)
                .frame(maxWidth: .infinity, minHeight: InstrumentSize.laneHeight, maxHeight: .infinity)
                .graphFrame()
        }
        .accessibilityReading(Text(verbatim: title), value: Text(verbatim: band.accessibilityValue))
    }
}

/// Abschnitte gleichen Zustands: Fläche im Ton 14 %, unten eine Leiste im Ton, Name, wenn er hineinpasst. Aus Formen
/// statt `Canvas` (#521, siehe `Plot`).
private struct ThermalSegments: View {
    let segments: [ThermalBand.Segment]
    @Environment(\.self) private var environment

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(segments.indices, id: \.self) { index in
                    segment(segments[index], in: proxy.size)
                }
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func segment(_ segment: ThermalBand.Segment, in size: CGSize) -> some View {
        let x = size.width * min(max(segment.start, 0), 1)
        let width = size.width * min(max(segment.end, 0), 1) - x
        if width > 0 {
            let color = environment.statusColor(segment.tone)
            let bar = InstrumentSize.spurList
            ZStack(alignment: .bottom) {
                Rectangle().fill(color.opacity(InstrumentOpacity.chip))
                Rectangle().fill(color).frame(height: bar)
            }
            .overlay(alignment: .leading) {
                // Der Name nur, wenn er samt Abstand ganz hineinpasst.
                ViewThatFits(in: .horizontal) {
                    Text(verbatim: segment.title).font(InstrumentFont.label.weight(.medium))
                        .foregroundStyle(environment.statusTextColor(segment.tone))
                        .fixedSize()
                        .padding(.horizontal, InstrumentSpacing.item)
                    Color.clear
                }
                .padding(.bottom, bar)
            }
            .frame(width: width, height: size.height)
            .offset(x: x)
        }
    }
}
