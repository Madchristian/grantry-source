import SwiftUI
import Testing
@testable import GrantryCharts

/// Karte „Erreichbarkeit“ mit vielen Einträgen in hell, dunkel und „Kontrast erhöhen“: klein in der Spalte (äußerer
/// Ring fasst zusammen) und auf die ganze Seite vergrößert (jedes Programm einzeln). Beschriftungen überdecken einander
/// in beiden nicht (`RingRadarLayoutTests`). Neu aufzeichnen mit `GRANTRY_RECORD_SNAPSHOTS=1`.
@MainActor
@Suite struct ReachRadarSnapshotTests {
    nonisolated static let cases = SnapshotGallery.ReachRadarScene.allCases.flatMap { scene in
        ChartAppearance.allCases.map { (scene, $0) }
    }

    @Test(arguments: cases)
    func reachRadar(_ scene: SnapshotGallery.ReachRadarScene, _ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.reachRadar(scene), named: "erreichbarkeit-\(scene.rawValue)",
                                 size: scene.size, appearance: appearance)
    }

    /// Mit den Maßen der Systemschrift wie im Bild: vergrößert steht jedes Programm einzeln und ungekürzt da.
    @Test func expandedPageLabelsEveryEchoInFull() {
        let entries = SnapshotGallery.reachEchoes.map {
            RingRadarLayout.Entry(id: $0.id, label: $0.label, ring: $0.ring.rawValue)
        }
        let rings = ReachRadar.rings.map { RingRadarLayout.Ring(title: $0.title, capacity: $0.capacity) }
        let layout = RingRadarLayout(size: CGSize(width: 1048, height: 640), rings: rings, entries: entries,
                                     isExpanded: true, measure: .system)
        #expect(layout.marks.count == entries.count)
        #expect(layout.marks.allSatisfy { $0.caption?.text == $0.label })
    }
}
