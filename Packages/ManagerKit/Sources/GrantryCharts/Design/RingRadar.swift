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

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.chartStyle) private var style

    /// - Parameters:
    ///   - centerSymbol: SF Symbol in der Mitte, etwa der Mac oder der Kern.
    ///   - title: Name der Liste für VoiceOver.
    public init(rings: [Ring], echoes: [Echo], centerSymbol: String, title: String, selection: Echo.ID? = nil) {
        self.rings = rings
        self.echoes = echoes
        self.centerSymbol = centerSymbol
        self.title = title
        self.selection = selection
    }

    /// Radius eines Rings relativ zum halben Durchmesser: gleichmäßig von 0,34 (innen) bis 0,93 (außen).
    nonisolated static func scale(ring: Int, of count: Int) -> CGFloat {
        guard count > 1 else { return 0.93 }
        return 0.34 + 0.59 * CGFloat(ring) / CGFloat(count - 1)
    }

    /// Grenze eines Rings im Verhältnis seines Umfangs zum äußersten, der `outermost` Echos fasst – innen liegen die
    /// Beschriftungen sonst übereinander.
    public nonisolated static func proportionalCapacity(ring: Int, of count: Int, outermost: Int) -> Int {
        max(1, Int((Double(outermost) * scale(ring: ring, of: count) / scale(ring: count - 1, of: count)).rounded()))
    }

    /// Echos je Ring mit Winkel (Grad); über der Grenze des Rings ein Sammel-Echo „+n“ im Ton des Rings. Die Ringe sind
    /// gegeneinander versetzt, damit Beschriftungen benachbarter Ringe nicht übereinander liegen; oben bleibt Platz für
    /// den Ringtitel. Echos ohne passenden Ring fallen weg.
    nonisolated static func placed(_ echoes: [Echo], rings: [Ring]) -> [(echo: Echo, degrees: Double)] {
        rings.indices.flatMap { index -> [(echo: Echo, degrees: Double)] in
            let capacity = rings[index].capacity
            var members = echoes.filter { $0.ring == index }
            if members.count > capacity {
                let rest = members.count - (capacity - 1)
                members = Array(members.prefix(capacity - 1)) + [Echo(id: "more-\(index)", label: "+\(rest)", ring: index)]
            }
            // Bogen von 300° über unten bis 240° (oben bleibt frei); je Ring um ein Viertel Schritt versetzt.
            let step = 300.0 / Double(max(members.count, 1))
            let shift = 0.25 * Double(index - 1)
            return members.enumerated().map { position, echo in
                (echo, (300 + step * (Double(position) + 0.5 + shift)).truncatingRemainder(dividingBy: 360))
            }
        }
    }

    public var body: some View {
        let scheme = colorScheme
        let rings = rings
        let placed = Self.placed(echoes, rings: rings)
        let selection = selection
        let focus = GrantryBrand.focusGradient(scheme)
        // „Kontrast erhöhen“ zeichnet die Ringe in voller Tonfarbe.
        let ringOpacity = contrast == .increased ? 1 : InstrumentOpacity.radarRing
        Plot("RingRadar") { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let base = min(size.width, size.height) / 2 - InstrumentSpacing.panel
            for (index, ring) in rings.enumerated() {
                let radius = base * Self.scale(ring: index, of: rings.count)
                context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2,
                                                      height: radius * 2)),
                               with: .color(ring.tone.color(in: scheme).opacity(ringOpacity)),
                               style: StrokeStyle(lineWidth: InstrumentStroke.echo, dash: ring.isDashed ? [4, 3] : []))
                context.draw(Text(verbatim: ring.title).font(InstrumentFont.micro.weight(.semibold))
                                .foregroundStyle(ring.tone.textColor(in: scheme)),
                             at: CGPoint(x: center.x, y: center.y - radius + InstrumentSpacing.cell))
            }
            let middle = InstrumentSize.shield / 2
            context.fill(Path(ellipseIn: CGRect(x: center.x - middle, y: center.y - middle, width: middle * 2,
                                                height: middle * 2)),
                         with: .color(GrantryBrand.teal.opacity(InstrumentOpacity.chip)))
            context.draw(Image(systemName: centerSymbol), at: center)
            for (echo, degrees) in placed {
                let angle = Angle.degrees(degrees).radians
                let radius = base * Self.scale(ring: echo.ring, of: rings.count)
                let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                let tone = echo.tone ?? rings[echo.ring].tone
                PeilPoint.draw(at: point, color: tone.color(in: scheme), echoes: style.glows, in: &context)
                if echo.id == selection {
                    let ring = InstrumentSize.findingDot
                    let frame = CGRect(x: point.x - ring, y: point.y - ring, width: ring * 2, height: ring * 2)
                    context.stroke(Path(ellipseIn: frame),
                                   with: .linearGradient(focus, startPoint: frame.origin,
                                                         endPoint: CGPoint(x: frame.maxX, y: frame.maxY)),
                                   lineWidth: InstrumentStroke.focus)
                }
                let label = Text(verbatim: echo.label).font(InstrumentFont.micro.weight(.medium))
                if echo.ring == 0 {
                    // Vom Mittelpunkt weg beschriftet; unter dem Punkt läge die Beschriftung auf der Mitte.
                    let outward = CGPoint(x: point.x + cos(angle) * InstrumentSpacing.group,
                                          y: point.y + sin(angle) * InstrumentSpacing.group)
                    context.draw(label, at: outward, anchor: UnitPoint(x: 0.5 - 0.5 * cos(angle), y: 0.5 - 0.5 * sin(angle)))
                } else {
                    context.draw(label, at: CGPoint(x: point.x, y: point.y + InstrumentSpacing.bar))
                }
            }
        }
        .renderProbe("RingRadar")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityRepresentation {
            VStack {
                ForEach(placed, id: \.echo.id) { item in
                    Text(verbatim: item.echo.accessibilityLabel ?? "\(item.echo.label), \(rings[item.echo.ring].title)")
                }
            }
        }
    }
}
