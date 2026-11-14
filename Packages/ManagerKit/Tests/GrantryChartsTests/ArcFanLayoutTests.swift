import CoreGraphics
import Testing
@testable import GrantryCharts

/// Anordnung des Bogenfächers (`ArcFanLayout`): Zeilen ohne Überlappung, Sammel-Ast, Linienstärken und die zweite
/// Fächerstufe der vergrößerten Karte. Die Textmaße sind hier fest (6 pt je Zeichen), damit die Rechnung ohne Schrift
/// prüfbar bleibt.
@Suite struct ArcFanLayoutTests {
    static let measure = RingRadarTextMeasure(label: { CGSize(width: CGFloat($0.count) * 6, height: 12) },
                                              title: { CGSize(width: CGFloat($0.count) * 6, height: 12) })
    /// Fläche des Fächers in der Karte: Spalte 400 abzüglich Panelrand, Höhe `InstrumentSize.radar`.
    static let cardSize = CGSize(width: 376, height: 280)
    static let pageSize = CGSize(width: 1100, height: 640)

    static func branches(_ count: Int, leaves: Int = 0) -> [ArcFanLayout.Branch] {
        (0..<count).map { index in
            ArcFanLayout.Branch(id: "land\(index)", label: "Land \(index)", weight: count - index,
                                leaves: (0..<leaves).map {
                                    ArcFanLayout.Leaf(id: "land\(index)-app\($0)", label: "App \($0)", weight: 1)
                                })
        }
    }

    static func layout(_ branches: [ArcFanLayout.Branch], size: CGSize = cardSize,
                       isExpanded: Bool = false) -> ArcFanLayout {
        ArcFanLayout(size: size, branches: branches, isExpanded: isExpanded, measure: measure)
    }

    /// Rechteck einer Beschriftung rechts neben ihrem Punkt.
    static func frame(of caption: String, at point: CGPoint) -> CGRect {
        let size = measure.label(caption)
        return CGRect(x: point.x + ArcFanLayout.captionOffset, y: point.y - size.height / 2, width: size.width,
                      height: size.height)
    }

    /// Beschriftungen von Ästen und Blättern: innerhalb der Fläche und paarweise getrennt.
    static func problems(in layout: ArcFanLayout, size: CGSize) -> [String] {
        let bounds = CGRect(origin: .zero, size: size)
        let frames = layout.marks.flatMap { mark in
            [(mark.caption, frame(of: mark.caption, at: mark.point))]
                + mark.leaves.map { ($0.caption, frame(of: $0.caption, at: $0.point)) }
        }
        var problems: [String] = []
        for (index, (caption, frame)) in frames.enumerated() {
            if !bounds.contains(frame) { problems.append("\(caption) ragt über den Rand") }
            for (other, otherFrame) in frames[(index + 1)...] where frame.intersects(otherFrame) {
                problems.append("\(caption) überdeckt \(other)")
            }
        }
        return problems
    }

    @Test func fewBranchesStandInOrderFromTopToBottom() {
        let layout = Self.layout(Self.branches(4))
        #expect(layout.marks.map(\.id) == ["land0", "land1", "land2", "land3"])
        #expect(layout.marks.map(\.point.y) == layout.marks.map(\.point.y).sorted())
        #expect(layout.marks.allSatisfy { !$0.isSummary && $0.leaves.isEmpty && $0.stem == nil })
        #expect(Self.problems(in: layout, size: Self.cardSize) == [])
    }

    @Test func branchesStandRightOfTheOriginAndAroundItsHeight() {
        let layout = Self.layout(Self.branches(5))
        #expect(layout.origin.y == Self.cardSize.height / 2)
        #expect(layout.marks.allSatisfy { $0.point.x > layout.origin.x + ArcFanLayout.originRadius })
        let rows = layout.marks.map(\.point.y)
        #expect(abs((rows.first! + rows.last!) / 2 - layout.origin.y) < 0.5)
    }

    @Test func rowsKeepTheirDistance() {
        for count in [2, 6, 10, 40] {
            let rows = Self.layout(Self.branches(count)).marks.map(\.point.y)
            let gaps = zip(rows, rows.dropFirst()).map { $1 - $0 }
            #expect(gaps.allSatisfy { $0 >= ArcFanLayout.minimumPitch - 0.01 }, "\(count) Äste")
            #expect(gaps.allSatisfy { $0 <= ArcFanLayout.maximumPitch + 0.01 }, "\(count) Äste")
        }
    }

    @Test func cardSummarisesWhatDoesNotFit() {
        let branches = Self.branches(16)
        let layout = Self.layout(branches)
        #expect(layout.marks.count == ArcFanLayout.compactCapacity)
        let summary = layout.marks.last
        #expect(summary?.isSummary == true)
        #expect(summary?.id == ArcFanLayout.summaryID)
        // Neun Äste einzeln, die übrigen sieben als „+7“ mit der Summe ihrer Gewichte.
        #expect(summary?.caption == "+7 · \(branches.dropFirst(9).reduce(0) { $0 + $1.weight })")
        #expect(layout.marks.dropLast().map(\.id) == branches.prefix(9).map(\.id))
        #expect(Self.problems(in: layout, size: Self.cardSize) == [])
    }

    @Test func exactlyFittingBranchesNeedNoSummary() {
        let layout = Self.layout(Self.branches(ArcFanLayout.compactCapacity))
        #expect(layout.marks.count == ArcFanLayout.compactCapacity)
        #expect(layout.marks.allSatisfy { !$0.isSummary })
    }

    @Test func lowCardShowsFewerRows() {
        let size = CGSize(width: 376, height: 100)
        let layout = Self.layout(Self.branches(12), size: size)
        #expect(layout.marks.count == 4)
        #expect(layout.marks.last?.isSummary == true)
        #expect(Self.problems(in: layout, size: size) == [])
    }

    @Test func lineWidthFollowsTheWeight() {
        let layout = Self.layout([ArcFanLayout.Branch(id: "a", label: "A", weight: 16),
                                  ArcFanLayout.Branch(id: "b", label: "B", weight: 4),
                                  ArcFanLayout.Branch(id: "c", label: "C", weight: 1)])
        let widths = layout.marks.map(\.lineWidth)
        #expect(widths[0] == ArcFanLayout.maximumLine)
        #expect(widths == widths.sorted(by: >))
        #expect(widths.allSatisfy { $0 >= ArcFanLayout.minimumLine })
        // Wurzel: ein Viertel des Gewichts ergibt die halbe Spanne.
        #expect(abs(widths[1] - (ArcFanLayout.minimumLine + (ArcFanLayout.maximumLine - ArcFanLayout.minimumLine) / 2)) < 0.001)
        #expect(ArcFanLayout.lineWidth(weight: 0, heaviest: 0) == ArcFanLayout.minimumLine)
    }

    @Test func longLabelsAreShortenedToTheirColumn() {
        let long = ArcFanLayout.Branch(id: "x", label: "Demokratische Republik Kongo und noch viel mehr Text dahinter",
                                       weight: 3)
        let layout = Self.layout([long])
        let caption = layout.marks[0].caption
        #expect(caption.hasSuffix("… · 3"))
        #expect(caption.hasPrefix("Demokratische"))
        #expect(Self.problems(in: layout, size: Self.cardSize) == [])
    }

    @Test func captionKeepsShortLabelsWhole() {
        #expect(ArcFanLayout.caption("Deutschland", weight: 2, limit: 200, measure: Self.measure) == "Deutschland · 2")
        // Selbst ohne Platz bleiben die ersten Zeichen und das Gewicht stehen.
        #expect(ArcFanLayout.caption("Deutschland", weight: 2, limit: 0, measure: Self.measure) == "De… · 2")
    }

    @Test func expandedPageShowsLeavesAsSecondStage() {
        let layout = Self.layout(Self.branches(5, leaves: 3), size: Self.pageSize, isExpanded: true)
        #expect(layout.marks.count == 5)
        for mark in layout.marks {
            #expect(mark.leaves.count == 3)
            let stem = try! #require(mark.stem)
            #expect(stem.y == mark.point.y)
            #expect(stem.x > mark.point.x)
            #expect(mark.leaves.allSatisfy { $0.point.x > stem.x })
            // Der Ast steht in der Mitte seiner Blätter.
            let rows = mark.leaves.map(\.point.y)
            #expect(abs(mark.point.y - rows.reduce(0, +) / CGFloat(rows.count)) < 0.01)
        }
        #expect(Self.problems(in: layout, size: Self.pageSize) == [])
    }

    @Test func expandedPageSummarisesManyLeavesOfABranch() {
        let layout = Self.layout(Self.branches(2, leaves: 9), size: Self.pageSize, isExpanded: true)
        let leaves = layout.marks[0].leaves
        #expect(leaves.count == ArcFanLayout.leafCapacity)
        #expect(leaves.last?.isSummary == true)
        #expect(leaves.last?.caption == "+6 · 6")
        #expect(leaves.dropLast().allSatisfy { !$0.isSummary })
    }

    @Test func expandedPageHoldsMoreBranchesThanTheCard() {
        let branches = Self.branches(24)
        let page = Self.layout(branches, size: Self.pageSize, isExpanded: true)
        #expect(page.marks.count == 24)
        #expect(page.marks.allSatisfy { !$0.isSummary })
        #expect(Self.problems(in: page, size: Self.pageSize) == [])
    }

    @Test func expandedPageSummarisesBranchesBeyondItsHeight() {
        let branches = Self.branches(30, leaves: 4)
        let layout = Self.layout(branches, size: Self.pageSize, isExpanded: true)
        let summary = try! #require(layout.marks.last)
        #expect(summary.isSummary)
        let shown = layout.marks.dropLast()
        #expect(shown.map(\.id) == branches.prefix(shown.count).map(\.id))
        #expect(summary.weight == branches.dropFirst(shown.count).reduce(0) { $0 + $1.weight })
        let rows = layout.marks.reduce(0) { $0 + max($1.leaves.count, 1) }
        #expect(CGFloat(rows) * ArcFanLayout.minimumPitch <= Self.pageSize.height - 2 * ArcFanLayout.margin)
        #expect(Self.problems(in: layout, size: Self.pageSize) == [])
    }

    @Test func cardIgnoresLeaves() {
        let layout = Self.layout(Self.branches(3, leaves: 4))
        #expect(layout.marks.allSatisfy { $0.leaves.isEmpty && $0.stem == nil })
    }

    @Test func emptyAndTinyAreasStaySafe() {
        #expect(Self.layout([]).marks.isEmpty)
        #expect(Self.layout(Self.branches(3), size: .zero).marks.isEmpty)
        let tiny = Self.layout(Self.branches(3), size: CGSize(width: 40, height: 10))
        #expect(tiny.marks.count == 1)
        #expect(tiny.marks[0].isSummary == false || tiny.marks[0].caption.hasPrefix("+"))
    }

    @Test func sameInputGivesTheSameLayout() {
        #expect(Self.layout(Self.branches(12)) == Self.layout(Self.branches(12)))
    }
}
