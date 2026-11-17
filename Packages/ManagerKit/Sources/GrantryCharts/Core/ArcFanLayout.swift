import CoreGraphics

/// Anordnung des Bogenfächers (`ArcFan`): links der Ursprung, rechts untereinander die Äste, vergrößert dahinter je Ast
/// seine Blätter als zweite Fächerstufe. Reine Rechnung ohne Ansicht; die Textmaße kommen von außen
/// (`RingRadarTextMeasure`), damit Tests ohne Schriften rechnen.
///
/// Die Äste stehen in der übergebenen Reihenfolge. Fasst die Höhe nicht alle, steht der letzte Platz als Sammel-Ast
/// „+n“ für den Rest; ebenso das letzte Blatt eines Asts. Beschriftungen stehen rechts neben ihrem Punkt und werden
/// gekürzt, bis sie in ihre Spalte passen. Die Liste für VoiceOver nennt weiter jeden Eintrag einzeln. Jeder Ast hat
/// eine Klickfläche über Punkt und Beschriftung (#633); der Sammel-Ast vertritt die Äste, die keinen Platz fanden.
struct ArcFanLayout: Equatable {
    struct Leaf: Hashable {
        let id: String
        let label: String
        let weight: Int
    }

    struct Branch: Hashable {
        let id: String
        let label: String
        /// Gewicht des Asts, etwa die Zahl der Verbindungen: bestimmt die Linienstärke.
        let weight: Int
        var leaves: [Leaf] = []
    }

    struct LeafMark: Equatable, Identifiable {
        let id: String
        /// Beschriftung wie gezeichnet, gegebenenfalls gekürzt, mit Gewicht („Safari · 2“).
        let caption: String
        let point: CGPoint
        /// Sammel-Blatt „+n“ für den Rest eines Asts.
        let isSummary: Bool
    }

    struct Mark: Equatable, Identifiable {
        let id: String
        /// Beschriftung wie gezeichnet, gegebenenfalls gekürzt, mit Gewicht („Deutschland · 2“).
        let caption: String
        let weight: Int
        /// Sammel-Ast „+n“ für die Äste, die keinen Platz mehr fanden.
        let isSummary: Bool
        let point: CGPoint
        let lineWidth: CGFloat
        /// Beginn der zweiten Fächerstufe hinter der Beschriftung; `nil` ohne Blätter.
        let stem: CGPoint?
        let leaves: [LeafMark]
        /// Kennungen der Äste, für die der Punkt steht: der Ast selbst bzw. beim Sammel-Ast alle zusammengefassten.
        let members: [String]
        /// Fläche der Beschriftung rechts neben dem Punkt.
        let captionFrame: CGRect
        /// Klickfläche: eine Zeile hoch, vom Punkt bis zum Ende der Beschriftung.
        let hitFrame: CGRect
    }

    /// Mittelpunkt des Ursprungs am linken Rand.
    let origin: CGPoint
    let marks: [Mark]

    /// Kennung des Sammel-Asts und Präfix der Sammel-Blätter.
    static let summaryID = "ArcFanLayout.summary"
    /// Rand der Fläche.
    static let margin: CGFloat = 12
    /// Halber Durchmesser des Ursprungs mit dem Symbol.
    static let originRadius: CGFloat = 22
    /// Kleinster und größter Abstand zweier Zeilen.
    static let minimumPitch: CGFloat = 18
    static let maximumPitch: CGFloat = 34
    /// Höchstens so viele Äste in der kleinen Karte und so viele Blätter je Ast in der vergrößerten.
    static let compactCapacity = 10
    static let leafCapacity = 4
    /// Abstand vom Punkt zur Beschriftung und von der Beschriftung zum Beginn der zweiten Stufe.
    static let captionOffset: CGFloat = 10
    static let stemGap: CGFloat = 8
    /// Anteil der Breite, an dem die Äste stehen: klein mittig, vergrößert weiter links mit Platz für die Blätter.
    static let compactBranchFraction: CGFloat = 0.46
    static let expandedBranchFraction: CGFloat = 0.3
    static let leafFraction: CGFloat = 0.66
    /// Linienstärke des leichtesten und des schwersten Asts.
    static let minimumLine: CGFloat = 1
    static let maximumLine: CGFloat = 6
    /// Abstand der Klickflächen benachbarter Äste zur Zeilengrenze.
    static let hitInset: CGFloat = 0.5
    /// Kürzeste gekürzte Beschriftung in Zeichen.
    static let shortestLabel = 3

    /// - Parameter isExpanded: Vergrößerte Karte: so viele Äste, wie die Höhe fasst, und je Ast seine Blätter.
    init(size: CGSize, branches: [Branch], isExpanded: Bool = false, measure: RingRadarTextMeasure) {
        origin = CGPoint(x: min(Self.margin + Self.originRadius, size.width / 2), y: size.height / 2)
        let usable = max(size.height - 2 * Self.margin, 0)
        let rowLimit = max(Int(usable / Self.minimumPitch), 1)
        let planned = Self.planned(branches, rowLimit: isExpanded ? rowLimit : min(rowLimit, Self.compactCapacity),
                                   withLeaves: isExpanded)
        let rowCount = planned.reduce(0) { $0 + $1.rowCount }
        guard rowCount > 0, size.width > 0 else { marks = []; return }
        let pitch = min(Self.maximumPitch, usable / CGFloat(rowCount))
        let top = size.height / 2 - pitch * CGFloat(rowCount) / 2
        let branchX = size.width * (isExpanded ? Self.expandedBranchFraction : Self.compactBranchFraction)
        let leafX = size.width * Self.leafFraction
        let hasLeaves = planned.contains { !$0.leaves.isEmpty }
        let branchLimit = (hasLeaves ? leafX - Self.stemGap * 2 : size.width - Self.margin) - branchX - Self.captionOffset
        let leafLimit = size.width - Self.margin - leafX - Self.captionOffset
        let heaviest = max(planned.map(\.weight).max() ?? 1, 1)

        var row = 0
        marks = planned.map { item in
            let rows = (row..<row + item.rowCount).map { top + pitch * (CGFloat($0) + 0.5) }
            row += item.rowCount
            let point = CGPoint(x: branchX, y: rows.reduce(0, +) / CGFloat(rows.count))
            let caption = Self.caption(item.label, weight: item.weight, limit: branchLimit, measure: measure)
            let captionSize = measure.label(caption)
            let captionFrame = CGRect(x: branchX + Self.captionOffset, y: point.y - captionSize.height / 2,
                                      width: captionSize.width, height: captionSize.height)
            let stem = item.leaves.isEmpty ? nil : CGPoint(x: captionFrame.maxX + Self.stemGap, y: point.y)
            let leaves = zip(item.leaves, rows).map { leaf, y in
                LeafMark(id: leaf.id, caption: Self.caption(leaf.label, weight: leaf.weight, limit: leafLimit,
                                                            measure: measure),
                         point: CGPoint(x: leafX, y: y), isSummary: leaf.isSummary)
            }
            // Eine Zeile hoch, um einen halben Punkt eingerückt, damit benachbarte Flächen sich nicht berühren.
            let hitFrame = CGRect(x: branchX - pitch / 2, y: point.y - pitch / 2 + Self.hitInset,
                                  width: captionFrame.maxX - branchX + pitch / 2, height: pitch - 2 * Self.hitInset)
            return Mark(id: item.id, caption: caption, weight: item.weight, isSummary: item.isSummary, point: point,
                        lineWidth: Self.lineWidth(weight: item.weight, heaviest: heaviest), stem: stem, leaves: leaves,
                        members: item.members, captionFrame: captionFrame, hitFrame: hitFrame)
        }
    }

    /// Linienstärke nach Gewicht: die Wurzel hält auch leichte Äste neben einem sehr schweren sichtbar.
    static func lineWidth(weight: Int, heaviest: Int) -> CGFloat {
        let share = (Double(max(weight, 0)) / Double(max(heaviest, 1))).squareRoot()
        return minimumLine + (maximumLine - minimumLine) * CGFloat(min(share, 1))
    }

    /// „Deutschland · 2“; die Beschriftung von hinten gekürzt, bis alles in `limit` passt.
    static func caption(_ label: String, weight: Int, limit: CGFloat, measure: RingRadarTextMeasure) -> String {
        let suffix = " · \(weight)"
        var kept = label
        while measure.label(kept + suffix).width > limit, kept.count > shortestLabel {
            kept = String(kept.dropLast(kept.hasSuffix("…") ? 2 : 1)) + "…"
        }
        return kept + suffix
    }

    // MARK: Auswahl der Zeilen

    private struct PlannedLeaf {
        let id: String
        let label: String
        let weight: Int
        let isSummary: Bool
    }

    private struct PlannedBranch {
        let id: String
        let label: String
        let weight: Int
        let isSummary: Bool
        let leaves: [PlannedLeaf]
        let members: [String]

        var rowCount: Int { max(leaves.count, 1) }
    }

    /// Äste in ihrer Reihenfolge, solange die Zeilen reichen; der Rest steht als Sammel-Ast in der letzten Zeile.
    private static func planned(_ branches: [Branch], rowLimit: Int, withLeaves: Bool) -> [PlannedBranch] {
        var result: [PlannedBranch] = []
        var used = 0
        for (index, branch) in branches.enumerated() {
            let isLast = index == branches.count - 1
            // Eine Zeile bleibt für den Sammel-Ast frei, solange noch Äste folgen.
            let free = rowLimit - used - (isLast ? 0 : 1)
            guard free >= 1 else { break }
            let leaves = withLeaves ? planned(branch.leaves, of: branch.id, limit: min(leafCapacity, free)) : []
            let item = PlannedBranch(id: branch.id, label: branch.label, weight: branch.weight, isSummary: false,
                                     leaves: leaves, members: [branch.id])
            result.append(item)
            used += item.rowCount
        }
        let rest = branches.dropFirst(result.count)
        if !rest.isEmpty {
            result.append(PlannedBranch(id: summaryID, label: "+\(rest.count)", weight: rest.reduce(0) { $0 + $1.weight },
                                        isSummary: true, leaves: [], members: rest.map(\.id)))
        }
        return result
    }

    private static func planned(_ leaves: [Leaf], of branch: String, limit: Int) -> [PlannedLeaf] {
        guard leaves.count > limit else {
            return leaves.map { PlannedLeaf(id: $0.id, label: $0.label, weight: $0.weight, isSummary: false) }
        }
        let rest = leaves.dropFirst(limit - 1)
        return leaves.prefix(limit - 1).map { PlannedLeaf(id: $0.id, label: $0.label, weight: $0.weight, isSummary: false) }
            + [PlannedLeaf(id: "\(summaryID).\(branch)", label: "+\(rest.count)",
                           weight: rest.reduce(0) { $0 + $1.weight }, isSummary: true)]
    }
}
