import SwiftUI

/// Bogenfächer: vom Ursprung links führt je Ast eine Bogenlinie zu einem Punkt rechts, etwa von diesem Mac zu den
/// Ländern seiner Verbindungen. Die Linienstärke folgt dem Gewicht des Asts, gestrichelt steht für die Gegenrichtung
/// (nur eingehend). Ab der Grenze der Karte fasst ein Sammel-Ast „+n“ den Rest zusammen; vergrößert
/// (`InstrumentExpansion`) trägt die Karte, was ihre Höhe fasst, und zeigt je Ast seine Blätter als zweite Fächerstufe.
/// Geometrie aus `ArcFanLayout`. Statisch aus Formen (`Plot`), ohne Bewegung. VoiceOver liest die Äste als Liste.
///
/// Mit `onPick` nimmt jeder Ast Klicks an (#633, Klickbedienung aus `ChartPick`): der Rückruf bekommt die Kennungen der
/// Äste, für die der Punkt steht – beim Sammel-Ast alle zusammengefassten; gewählte Äste (`picked`) tragen ihre
/// Beschriftung weiß auf dem Grantry-Verlauf. Der Rückruf geht nicht in den Vergleich (`Equatable`) ein: Mit
/// `.equatable()` zeichnet ein Messtakt mit gleichen Ästen den Fächer nicht neu.
public struct ArcFan: View, Equatable {
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
        /// Wert des Eintrags für VoiceOver (die Beschriftung ist `label`); `nil` liest Gewicht und Blätter.
        public let accessibilityValue: String?

        public init(id: String, label: String, weight: Int, tone: StatusTone = .info, isDashed: Bool = false,
                    leaves: [Leaf] = [], accessibilityValue: String? = nil) {
            self.id = id
            self.label = label
            self.weight = weight
            self.tone = tone
            self.isDashed = isDashed
            self.leaves = leaves
            self.accessibilityValue = accessibilityValue
        }
    }

    let branches: [Branch]
    let originSymbol: String
    let title: String
    let selection: Branch.ID?
    let picked: Set<Branch.ID>
    let isExpanded: Bool
    let pickHint: String?
    let onPick: ((Set<Branch.ID>) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.chartStyle) private var style

    /// - Parameters:
    ///   - branches: Äste in der Reihenfolge von oben nach unten, der wichtigste zuerst.
    ///   - originSymbol: SF Symbol des Ursprungs, etwa der Mac.
    ///   - title: Name der Liste für VoiceOver.
    ///   - selection: Ast mit Fokusring, etwa das Ziel der gewählten Zeile.
    ///   - picked: Gewählte Äste, etwa ein Filter; der Sammel-Ast gilt als gewählt, sobald einer seiner Äste es ist.
    ///   - isExpanded: Vergrößerte Karte: alle Äste, die die Höhe fasst, samt Blättern.
    ///   - pickHint: Was ein Klick bewirkt, als Tooltip und VoiceOver-Hinweis.
    ///   - onPick: Klick auf einen Ast mit den Kennungen, für die er steht; `nil` nimmt keine Klicks an.
    public init(branches: [Branch], originSymbol: String, title: String, selection: Branch.ID? = nil,
                picked: Set<Branch.ID> = [], isExpanded: Bool = false, pickHint: String? = nil,
                onPick: ((Set<Branch.ID>) -> Void)? = nil) {
        self.branches = branches
        self.originSymbol = originSymbol
        self.title = title
        self.selection = selection
        self.picked = picked
        self.isExpanded = isExpanded
        self.pickHint = pickHint
        self.onPick = onPick
    }

    nonisolated public static func == (lhs: ArcFan, rhs: ArcFan) -> Bool {
        lhs.branches == rhs.branches && lhs.originSymbol == rhs.originSymbol && lhs.title == rhs.title
            && lhs.selection == rhs.selection && lhs.picked == rhs.picked && lhs.isExpanded == rhs.isExpanded
            && lhs.pickHint == rhs.pickHint && (lhs.onPick == nil) == (rhs.onPick == nil)
    }

    /// Äste von oben nach unten, wie VoiceOver sie liest: jeder einzeln, auch die im Bild zu „+n“ zusammengefassten;
    /// der Name als Beschriftung, Gewicht und Blätter als Wert.
    nonisolated static func spoken(_ branches: [Branch]) -> [ChartPick.Spoken] {
        branches.map { branch in
            let leaves = branch.leaves.map { "\($0.label) \($0.weight)" }.joined(separator: ", ")
            return ChartPick.Spoken(id: branch.id, label: branch.label, value: branch.accessibilityValue
                                        ?? ["\(branch.weight)", leaves].filter { !$0.isEmpty }.joined(separator: ": "))
        }
    }

    /// Ob ein Punkt als gewählt gilt: ein Ast, wenn er gewählt ist; der Sammel-Ast, sobald einer seiner Äste es ist.
    nonisolated static func isPicked(_ mark: ArcFanLayout.Mark, picked: Set<Branch.ID>) -> Bool {
        ChartPick.isPicked(mark.members, picked: picked)
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
        let entries = branches.map { branch in
            ArcFanLayout.Branch(id: branch.id, label: branch.label, weight: branch.weight,
                                leaves: branch.leaves.map { ArcFanLayout.Leaf(id: $0.id, label: $0.label, weight: $0.weight) })
        }
        let isExpanded = isExpanded
        GeometryReader { proxy in
            let layout = ArcFanLayout(size: proxy.size, branches: entries, isExpanded: isExpanded, measure: .system)
            drawing(layout)
                .overlay(alignment: .topLeading) {
                    if let onPick {
                        ChartPick.Areas(targets: layout.marks.map {
                            ChartPick.Target(id: $0.id, caption: $0.caption, members: $0.members, frame: $0.hitFrame)
                        }, hint: pickHint, onPick: onPick)
                    }
                }
        }
        .renderProbe("ArcFan")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityRepresentation {
            ChartPick.SpokenList(title: title, items: Self.spoken(branches), picked: picked, hint: pickHint,
                                 onPick: onPick)
        }
    }

    private func drawing(_ layout: ArcFanLayout) -> some View {
        let scheme = colorScheme
        let known = Dictionary(branches.map { ($0.id, $0) }) { first, _ in first }
        let selection = selection
        let picked = picked
        let originSymbol = originSymbol
        let glows = style.glows
        let focus = GrantryBrand.focusGradient(scheme)
        // „Kontrast erhöhen“ zeichnet die Bögen in voller Tonfarbe.
        let lineOpacity = contrast == .increased ? 1 : InstrumentOpacity.radarRing
        return Plot("ArcFan") { context, _ in
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
                PeilPoint.draw(at: mark.point, color: color, echoes: glows, in: &context)
                if mark.id == selection, !mark.isSummary {
                    PeilPoint.drawFocus(at: mark.point, gradient: focus, in: &context)
                }
                let caption = Text(verbatim: mark.caption).font(InstrumentFont.micro.weight(.medium))
                if Self.isPicked(mark, picked: picked) {
                    // Gewählt wie ein Segment: weiß auf dem Verlauf, die Kapsel ist auch ohne Farbe erkennbar.
                    context.draw(ChartPick.pickedCaption(caption),
                                 at: CGPoint(x: mark.captionFrame.minX - ChartPick.captionPadding, y: mark.point.y),
                                 anchor: .leading)
                } else {
                    context.draw(caption, at: CGPoint(x: mark.captionFrame.minX, y: mark.point.y), anchor: .leading)
                }
            }
            let radius = ArcFanLayout.originRadius
            context.fill(Path(ellipseIn: CGRect(x: origin.x - radius, y: origin.y - radius, width: radius * 2,
                                                height: radius * 2)),
                         with: .color(GrantryBrand.teal.opacity(InstrumentOpacity.chip)))
            context.draw(Image(systemName: originSymbol), at: origin)
        }
    }
}
