import SwiftUI

/// Ringradar (§3.13): konzentrische Ringe um eine Mitte, darauf Echos als Peilpunkte mit Beschriftung. Gemeinsame
/// Geometrie von Erreichbarkeitsradar (Verbindungen) und Rechte-Schichten (Erweiterungen). Ab der Grenze eines Rings
/// fasst ein Sammel-Echo „+n“ den Rest zusammen; ein gewähltes Echo trägt einen Ring im Grantry-Verlauf. Statisch aus
/// Formen (`Plot`), ohne Bewegung. VoiceOver liest die Echos als Liste.
public struct RingRadar: View {
    public struct Ring: Hashable, Sendable {
        public let title: String
        /// Farbe von Ring und Titel und Ton der Echos ohne eigenen Ton.
        public let tone: StatusTone
        public let isDashed: Bool
        /// Höchstens so viele Echos; darüber steht das letzte für den Rest.
        public let capacity: Int

        public init(title: String, tone: StatusTone = .neutral, isDashed: Bool = false, capacity: Int) {
            self.title = title
            self.tone = tone
            self.isDashed = isDashed
            self.capacity = max(capacity, 1)
        }
    }

    public struct Echo: Identifiable, Hashable, Sendable {
        public let id: String
        public let label: String
        /// Index in `rings`, von innen nach außen.
        public let ring: Int
        /// Eigener Ton, etwa Bernstein für einen Befund; `nil` nimmt den des Rings.
        public let tone: StatusTone?
        /// Eintrag der VoiceOver-Liste; `nil` liest Beschriftung und Ring.
        public let accessibilityLabel: String?

        public init(id: String, label: String, ring: Int, tone: StatusTone? = nil, accessibilityLabel: String? = nil) {
            self.id = id
            self.label = label
            self.ring = ring
            self.tone = tone
            self.accessibilityLabel = accessibilityLabel
        }
    }

    let rings: [Ring]
    let echoes: [Echo]
    let centerSymbol: String
    let title: String
    let selection: Echo.ID?
    let isExpanded: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.chartStyle) private var style

    /// - Parameters:
    ///   - centerSymbol: SF Symbol in der Mitte, etwa der Mac oder der Kern.
    ///   - title: Name der Liste für VoiceOver.
    ///   - isExpanded: Vergrößerte Karte (`InstrumentExpansion`): Jeder Ring zeigt so viele Echos einzeln, wie sein
    ///     Umfang fasst, statt früh zu „+n“ zusammenzufassen.
    public init(rings: [Ring], echoes: [Echo], centerSymbol: String, title: String, selection: Echo.ID? = nil,
                isExpanded: Bool = false) {
        self.rings = rings
        self.echoes = echoes
        self.centerSymbol = centerSymbol
        self.title = title
        self.selection = selection
        self.isExpanded = isExpanded
    }

    /// Grenze eines Rings im Verhältnis seines Umfangs zum äußersten (`RingRadarLayout.proportionalCapacity`).
    public nonisolated static func proportionalCapacity(ring: Int, of count: Int, outermost: Int) -> Int {
        RingRadarLayout.proportionalCapacity(ring: ring, of: count, outermost: outermost)
    }

    /// Echos mit passendem Ring von innen nach außen, wie VoiceOver sie liest: jedes einzeln, auch die im Bild zu „+n“
    /// zusammengefassten.
    nonisolated static func spoken(_ echoes: [Echo], rings: [Ring]) -> [(id: Echo.ID, text: String)] {
        rings.indices.flatMap { index in
            echoes.filter { $0.ring == index }.map { ($0.id, $0.accessibilityLabel ?? "\($0.label), \(rings[index].title)") }
        }
    }

    public var body: some View {
        let scheme = colorScheme
        let rings = rings
        let selection = selection
        let isExpanded = isExpanded
        let entries = echoes.map { RingRadarLayout.Entry(id: $0.id, label: $0.label, ring: $0.ring) }
        let tones = Dictionary(echoes.compactMap { echo in echo.tone.map { (echo.id, $0) } }) { first, _ in first }
        let focus = GrantryBrand.focusGradient(scheme)
        // „Kontrast erhöhen“ zeichnet die Ringe in voller Tonfarbe.
        let ringOpacity = contrast == .increased ? 1 : InstrumentOpacity.radarRing
        Plot("RingRadar") { context, size in
            let layout = RingRadarLayout(size: size,
                                         rings: rings.map { RingRadarLayout.Ring(title: $0.title, capacity: $0.capacity) },
                                         entries: entries, isExpanded: isExpanded, preferred: selection, measure: .system)
            let center = layout.center
            for (index, ring) in rings.enumerated() {
                let radius = layout.radii[index]
                context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2,
                                                      height: radius * 2)),
                               with: .color(ring.tone.color(in: scheme).opacity(ringOpacity)),
                               style: StrokeStyle(lineWidth: InstrumentStroke.echo, dash: ring.isDashed ? [4, 3] : []))
                context.draw(Text(verbatim: ring.title).font(InstrumentFont.micro.weight(.semibold))
                                .foregroundStyle(ring.tone.textColor(in: scheme)),
                             at: layout.titlePoints[index])
            }
            let middle = InstrumentSize.shield / 2
            context.fill(Path(ellipseIn: CGRect(x: center.x - middle, y: center.y - middle, width: middle * 2,
                                                height: middle * 2)),
                         with: .color(GrantryBrand.teal.opacity(InstrumentOpacity.chip)))
            context.draw(Image(systemName: centerSymbol), at: center)
            for mark in layout.marks {
                let point = mark.point
                let tone = (mark.isSummary ? nil : tones[mark.id]) ?? rings[mark.ring].tone
                PeilPoint.draw(at: point, color: tone.color(in: scheme), echoes: style.glows, in: &context)
                if mark.id == selection, !mark.isSummary {
                    let ring = InstrumentSize.findingDot
                    let frame = CGRect(x: point.x - ring, y: point.y - ring, width: ring * 2, height: ring * 2)
                    context.stroke(Path(ellipseIn: frame),
                                   with: .linearGradient(focus, startPoint: frame.origin,
                                                         endPoint: CGPoint(x: frame.maxX, y: frame.maxY)),
                                   lineWidth: InstrumentStroke.focus)
                }
                if let caption = mark.caption {
                    context.draw(Text(verbatim: caption.text).font(InstrumentFont.micro.weight(.medium)),
                                 at: CGPoint(x: caption.frame.midX, y: caption.frame.midY))
                }
            }
        }
        .renderProbe("RingRadar")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityRepresentation {
            VStack {
                ForEach(Self.spoken(echoes, rings: rings), id: \.id) { item in
                    Text(verbatim: item.text)
                }
            }
        }
    }
}
