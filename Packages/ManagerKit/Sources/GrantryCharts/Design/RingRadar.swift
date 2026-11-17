import SwiftUI

/// Ringradar (§3.13): konzentrische Ringe um eine Mitte, darauf Echos als Peilpunkte mit Beschriftung. Gemeinsame
/// Geometrie von Erreichbarkeitsradar (Verbindungen) und Rechte-Schichten (Erweiterungen). Ab der Grenze eines Rings
/// fasst ein Sammel-Echo „+n“ den Rest zusammen; ein gewähltes Echo trägt einen Ring im Grantry-Verlauf. Statisch aus
/// Formen (`Plot`), ohne Bewegung. VoiceOver liest die Echos als Liste.
///
/// Mit `onPick` nimmt jedes Echo Klicks an (#640, Klickbedienung aus `ChartPick` wie beim Bogenfächer): der Rückruf
/// bekommt die Kennungen der Echos, für die der Punkt steht – beim Sammel-Echo alle zusammengefassten; gewählte Echos
/// (`picked`) tragen ihre Beschriftung weiß auf dem Grantry-Verlauf, ohne Platz für die Beschriftung einen Fokusring.
/// Der Rückruf geht nicht in den Vergleich (`Equatable`) ein: Mit `.equatable()` zeichnet ein Messtakt mit gleichen
/// Echos das Radar nicht neu.
public struct RingRadar: View, Equatable {
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
    let picked: Set<Echo.ID>
    let isExpanded: Bool
    let pickHint: String?
    let onPick: ((Set<Echo.ID>) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.chartStyle) private var style

    /// - Parameters:
    ///   - centerSymbol: SF Symbol in der Mitte, etwa der Mac oder der Kern.
    ///   - title: Name der Liste für VoiceOver.
    ///   - selection: Echo mit Fokusring, etwa das der gewählten Zeile.
    ///   - picked: Gewählte Echos, etwa ein Filter; das Sammel-Echo gilt als gewählt, sobald eines seiner Echos es ist.
    ///   - isExpanded: Vergrößerte Karte (`InstrumentExpansion`): Jeder Ring zeigt so viele Echos einzeln, wie sein
    ///     Umfang fasst, statt früh zu „+n“ zusammenzufassen.
    ///   - pickHint: Was ein Klick bewirkt, als Tooltip und VoiceOver-Hinweis.
    ///   - onPick: Klick auf ein Echo mit den Kennungen, für die es steht; `nil` nimmt keine Klicks an.
    public init(rings: [Ring], echoes: [Echo], centerSymbol: String, title: String, selection: Echo.ID? = nil,
                picked: Set<Echo.ID> = [], isExpanded: Bool = false, pickHint: String? = nil,
                onPick: ((Set<Echo.ID>) -> Void)? = nil) {
        self.rings = rings
        self.echoes = echoes
        self.centerSymbol = centerSymbol
        self.title = title
        self.selection = selection
        self.picked = picked
        self.isExpanded = isExpanded
        self.pickHint = pickHint
        self.onPick = onPick
    }

    nonisolated public static func == (lhs: RingRadar, rhs: RingRadar) -> Bool {
        lhs.rings == rhs.rings && lhs.echoes == rhs.echoes && lhs.centerSymbol == rhs.centerSymbol
            && lhs.title == rhs.title && lhs.selection == rhs.selection && lhs.picked == rhs.picked
            && lhs.isExpanded == rhs.isExpanded && lhs.pickHint == rhs.pickHint
            && (lhs.onPick == nil) == (rhs.onPick == nil)
    }

    /// Grenze eines Rings im Verhältnis seines Umfangs zum äußersten (`RingRadarLayout.proportionalCapacity`).
    public nonisolated static func proportionalCapacity(ring: Int, of count: Int, outermost: Int) -> Int {
        RingRadarLayout.proportionalCapacity(ring: ring, of: count, outermost: outermost)
    }

    /// Echos mit passendem Ring von innen nach außen, wie VoiceOver sie liest: jedes einzeln, auch die im Bild zu „+n“
    /// zusammengefassten; die Beschriftung als Name, der Ring als Wert.
    nonisolated static func spoken(_ echoes: [Echo], rings: [Ring]) -> [ChartPick.Spoken] {
        rings.indices.flatMap { index in
            echoes.filter { $0.ring == index }.map {
                ChartPick.Spoken(id: $0.id, label: $0.label, value: rings[index].title, text: $0.accessibilityLabel)
            }
        }
    }

    /// Ob ein Punkt als gewählt gilt: ein Echo, wenn es gewählt ist; das Sammel-Echo, sobald eines seiner Echos es ist.
    nonisolated static func isPicked(_ mark: RingRadarLayout.Mark, picked: Set<Echo.ID>) -> Bool {
        ChartPick.isPicked(mark.members, picked: picked)
    }

    public var body: some View {
        let rings = rings
        let selection = selection
        let preferred = picked.union([selection].compactMap(\.self))
        let isExpanded = isExpanded
        let entries = echoes.map { RingRadarLayout.Entry(id: $0.id, label: $0.label, ring: $0.ring) }
        GeometryReader { proxy in
            let layout = RingRadarLayout(size: proxy.size,
                                         rings: rings.map { RingRadarLayout.Ring(title: $0.title, capacity: $0.capacity) },
                                         entries: entries, isExpanded: isExpanded, preferred: preferred,
                                         measure: .system)
            drawing(layout)
                .overlay(alignment: .topLeading) {
                    if let onPick {
                        ChartPick.Areas(targets: layout.marks.map {
                            ChartPick.Target(id: $0.id, caption: $0.caption?.text ?? $0.label, members: $0.members,
                                             frame: $0.hitFrame)
                        }, hint: pickHint, onPick: onPick)
                    }
                }
        }
        .renderProbe("RingRadar")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityRepresentation {
            ChartPick.SpokenList(title: title, items: Self.spoken(echoes, rings: rings), picked: picked,
                                 hint: pickHint, onPick: onPick)
        }
    }

    private func drawing(_ layout: RingRadarLayout) -> some View {
        let scheme = colorScheme
        let rings = rings
        let selection = selection
        let picked = picked
        let centerSymbol = centerSymbol
        let glows = style.glows
        let tones = Dictionary(echoes.compactMap { echo in echo.tone.map { (echo.id, $0) } }) { first, _ in first }
        let focus = GrantryBrand.focusGradient(scheme)
        // „Kontrast erhöhen“ zeichnet die Ringe in voller Tonfarbe.
        let ringOpacity = contrast == .increased ? 1 : InstrumentOpacity.radarRing
        return Plot("RingRadar") { context, _ in
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
                let isPicked = Self.isPicked(mark, picked: picked)
                PeilPoint.draw(at: point, color: tone.color(in: scheme), echoes: glows, in: &context)
                // Ohne Platz für die Beschriftung zeigt der Fokusring die Wahl, damit sie nicht nur an der Farbe hängt.
                if (mark.id == selection && !mark.isSummary) || (isPicked && mark.caption == nil) {
                    PeilPoint.drawFocus(at: point, gradient: focus, in: &context)
                }
                if let caption = mark.caption {
                    let text = Text(verbatim: caption.text).font(InstrumentFont.micro.weight(.medium))
                    let at = CGPoint(x: caption.frame.midX, y: caption.frame.midY)
                    if isPicked {
                        context.draw(ChartPick.pickedCaption(text), at: at)
                    } else {
                        context.draw(text, at: at)
                    }
                }
            }
        }
    }
}
