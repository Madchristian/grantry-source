import SwiftUI

/// Bogenfächer: vom Ursprung links führt je Ast eine Bogenlinie zu einem Punkt rechts, etwa von diesem Mac zu den
/// Ländern seiner Verbindungen. Die Linienstärke folgt dem Gewicht des Asts, gestrichelt steht für die Gegenrichtung
/// (nur eingehend). Ab der Grenze der Karte fasst ein Sammel-Ast „+n“ den Rest zusammen; vergrößert
/// (`InstrumentExpansion`) trägt die Karte, was ihre Höhe fasst, und zeigt je Ast seine Blätter als zweite Fächerstufe.
/// Geometrie aus `ArcFanLayout`. Statisch aus Formen (`Plot`), ohne Bewegung. VoiceOver liest die Äste als Liste.
public struct ArcFan: View {
    public struct Leaf: Identifiable, Hashable, Sendable {
        public let id: String
        public let label: String
        public let weight: Int

        public init(id: String, label: String, weight: Int) {
            self.id = id
            self.label = label
            self.weight = weight
        }
    }

    public struct Branch: Identifiable, Hashable, Sendable {
        public let id: String
        public let label: String
        /// Gewicht des Asts, etwa die Zahl der Verbindungen: bestimmt die Linienstärke und steht hinter dem Namen.
        public let weight: Int
        public let tone: StatusTone
        /// Gestrichelte Linie, etwa für ausschließlich eingehende Verbindungen.
        public let isDashed: Bool
        /// Zweite Fächerstufe der vergrößerten Karte, etwa die Programme.
        public let leaves: [Leaf]
        /// Eintrag der VoiceOver-Liste; `nil` liest Beschriftung, Gewicht und Blätter.
        public let accessibilityLabel: String?

        public init(id: String, label: String, weight: Int, tone: StatusTone = .info, isDashed: Bool = false,
                    leaves: [Leaf] = [], accessibilityLabel: String? = nil) {
            self.id = id
            self.label = label
            self.weight = weight
            self.tone = tone
            self.isDashed = isDashed
            self.leaves = leaves
            self.accessibilityLabel = accessibilityLabel
        }
    }

    let branches: [Branch]
    let originSymbol: String
    let title: String
    let selection: Branch.ID?
    let isExpanded: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.chartStyle) private var style

    /// - Parameters:
    ///   - branches: Äste in der Reihenfolge von oben nach unten, der wichtigste zuerst.
    ///   - originSymbol: SF Symbol des Ursprungs, etwa der Mac.
    ///   - title: Name der Liste für VoiceOver.
    ///   - isExpanded: Vergrößerte Karte: alle Äste, die die Höhe fasst, samt Blättern.
    public init(branches: [Branch], originSymbol: String, title: String, selection: Branch.ID? = nil,
                isExpanded: Bool = false) {
        self.branches = branches
        self.originSymbol = originSymbol
        self.title = title
        self.selection = selection
        self.isExpanded = isExpanded
    }

    /// Äste von oben nach unten, wie VoiceOver sie liest: jeder einzeln, auch die im Bild zu „+n“ zusammengefassten.
    nonisolated static func spoken(_ branches: [Branch]) -> [(id: Branch.ID, text: String)] {
        branches.map { branch in
            let leaves = branch.leaves.map { "\($0.label) \($0.weight)" }.joined(separator: ", ")
            return (branch.id, branch.accessibilityLabel
                ?? ["\(branch.label), \(branch.weight)", leaves].filter { !$0.isEmpty }.joined(separator: ": "))
        }
    }

    /// Bogen mit waagerechten Enden von `start` nach `end`.
    nonisolated static func arc(from start: CGPoint, to end: CGPoint) -> Path {
        var path = Path()
        let middle = (start.x + end.x) / 2
        path.move(to: start)
        path.addCurve(to: end, control1: CGPoint(x: middle, y: start.y), control2: CGPoint(x: middle, y: end.y))
        return path
    }

    public var body: some View {
        let scheme = colorScheme
        let branches = branches
        let selection = selection
        let isExpanded = isExpanded
        let entries = branches.map { branch in
            ArcFanLayout.Branch(id: branch.id, label: branch.label, weight: branch.weight,
                                leaves: branch.leaves.map { ArcFanLayout.Leaf(id: $0.id, label: $0.label, weight: $0.weight) })
        }
        let known = Dictionary(branches.map { ($0.id, $0) }) { first, _ in first }
        let focus = GrantryBrand.focusGradient(scheme)
        // „Kontrast erhöhen“ zeichnet die Bögen in voller Tonfarbe.
        let lineOpacity = contrast == .increased ? 1 : InstrumentOpacity.radarRing
        Plot("ArcFan") { context, size in
            let layout = ArcFanLayout(size: size, branches: entries, isExpanded: isExpanded, measure: .system)
            let origin = layout.origin
            let start = CGPoint(x: origin.x + ArcFanLayout.originRadius, y: origin.y)
            for mark in layout.marks {
                let branch = known[mark.id]
                let tone = branch?.tone ?? .neutral
                let color = tone.color(in: scheme)
                context.stroke(Self.arc(from: start, to: mark.point), with: .color(color.opacity(lineOpacity)),
                               style: StrokeStyle(lineWidth: mark.lineWidth, lineCap: .round,
                                                  dash: branch?.isDashed == true ? [4, 3] : []))
                if let stem = mark.stem {
                    for leaf in mark.leaves {
                        context.stroke(Self.arc(from: stem, to: leaf.point), with: .color(color.opacity(lineOpacity)),
                                       lineWidth: InstrumentStroke.echo)
                        let dot = InstrumentSize.peilPoint
                        context.fill(Path(ellipseIn: CGRect(x: leaf.point.x - dot, y: leaf.point.y - dot,
                                                            width: dot * 2, height: dot * 2)), with: .color(color))
                        context.draw(Text(verbatim: leaf.caption).font(InstrumentFont.micro.weight(.medium)),
                                     at: CGPoint(x: leaf.point.x + ArcFanLayout.captionOffset, y: leaf.point.y),
                                     anchor: .leading)
                    }
                }
                PeilPoint.draw(at: mark.point, color: color, echoes: style.glows, in: &context)
                if mark.id == selection, !mark.isSummary {
                    let ring = InstrumentSize.findingDot
                    let frame = CGRect(x: mark.point.x - ring, y: mark.point.y - ring, width: ring * 2, height: ring * 2)
                    context.stroke(Path(ellipseIn: frame),
                                   with: .linearGradient(focus, startPoint: frame.origin,
                                                         endPoint: CGPoint(x: frame.maxX, y: frame.maxY)),
                                   lineWidth: InstrumentStroke.focus)
                }
                context.draw(Text(verbatim: mark.caption).font(InstrumentFont.micro.weight(.medium)),
                             at: CGPoint(x: mark.point.x + ArcFanLayout.captionOffset, y: mark.point.y),
                             anchor: .leading)
            }
            let radius = ArcFanLayout.originRadius
            context.fill(Path(ellipseIn: CGRect(x: origin.x - radius, y: origin.y - radius, width: radius * 2,
                                                height: radius * 2)),
                         with: .color(GrantryBrand.teal.opacity(InstrumentOpacity.chip)))
            context.draw(Image(systemName: originSymbol), at: origin)
        }
        .renderProbe("ArcFan")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityRepresentation {
            VStack {
                ForEach(Self.spoken(branches), id: \.id) { item in
                    Text(verbatim: item.text)
                }
            }
        }
    }
}
