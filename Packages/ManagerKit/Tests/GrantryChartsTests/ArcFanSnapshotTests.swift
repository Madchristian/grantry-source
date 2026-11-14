import SwiftUI
import Testing
@testable import GrantryCharts

/// Karte „Ziele“ als Bogenfächer in hell, dunkel und „Kontrast erhöhen“: wenige Länder, viele Länder (der Rest als
/// „+n“), nur lokale Gegenstellen und auf die ganze Seite vergrößert mit den Programmen als zweiter Stufe.
/// Neu aufzeichnen mit `GRANTRY_RECORD_SNAPSHOTS=1`.
@MainActor
@Suite struct ArcFanSnapshotTests {
    nonisolated static let cases = SnapshotGallery.ArcFanScene.allCases.flatMap { scene in
        ChartAppearance.allCases.map { (scene, $0) }
    }

    @Test(arguments: cases)
    func arcFan(_ scene: SnapshotGallery.ArcFanScene, _ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.arcFan(scene), named: "bogenfaecher-\(scene.rawValue)",
                                 size: scene.size, appearance: appearance)
    }

    /// Mit den Maßen der Systemschrift wie im Bild: Die Karte zeigt neun Ziele und den Rest als „+n“, vergrößert steht
    /// jedes Ziel einzeln da.
    @Test func cardSummarisesAndPageShowsEveryBranch() {
        let branches = SnapshotGallery.ArcFanScene.many.branches.map {
            ArcFanLayout.Branch(id: $0.id, label: $0.label, weight: $0.weight,
                                leaves: $0.leaves.map { ArcFanLayout.Leaf(id: $0.id, label: $0.label, weight: $0.weight) })
        }
        let card = ArcFanLayout(size: CGSize(width: 376, height: 280), branches: branches, measure: .system)
        #expect(card.marks.count == ArcFanLayout.compactCapacity)
        #expect(card.marks.last?.isSummary == true)
        let page = ArcFanLayout(size: CGSize(width: 1048, height: 640), branches: branches, isExpanded: true,
                                measure: .system)
        #expect(page.marks.count == branches.count)
        #expect(page.marks.allSatisfy { !$0.isSummary })
    }

    /// VoiceOver liest jedes Ziel einzeln mit Gewicht und Programmen, auch die im Bild zusammengefassten.
    @Test func spokenListNamesEveryBranch() {
        let spoken = ArcFan.spoken(SnapshotGallery.ArcFanScene.many.branches)
        #expect(spoken.count == 15)
        #expect(spoken[1].text == "Deutschland, 9: Safari 5, Firefox 4")
        #expect(ArcFan.spoken([ArcFan.Branch(id: "a", label: "A", weight: 1, accessibilityLabel: "eigener Text")])[0].text
            == "eigener Text")
    }
}
