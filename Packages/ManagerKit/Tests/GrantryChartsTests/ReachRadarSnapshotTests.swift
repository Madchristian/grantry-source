import SwiftUI
import Testing
@testable import GrantryCharts

/// Karte „Erreichbarkeit“ mit vielen Einträgen in hell, dunkel und „Kontrast erhöhen“: klein in der Spalte (äußerer
/// Ring fasst zusammen) und auf die ganze Seite vergrößert (jedes Programm einzeln). Beschriftungen überdecken einander
/// in beiden nicht (`RingRadarLayoutTests`); dazu mit Programmfilter (#640) ein gewähltes Echo, das gewählte
/// Sammel-Echo und ein gewähltes Echo auf der Seite. Neu aufzeichnen mit `GRANTRY_RECORD_SNAPSHOTS=1`.
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

    /// Ein Echo gilt als gewählt, wenn es im Programmfilter steht; das Sammel-Echo, sobald eines der Echos gewählt ist,
    /// die es vertritt.
    @Test func pickedMarksFollowTheirMembers() throws {
        let entries = SnapshotGallery.reachEchoes.map {
            RingRadarLayout.Entry(id: $0.id, label: $0.label, ring: $0.ring.rawValue)
        }
        let rings = ReachRadar.rings.map { RingRadarLayout.Ring(title: $0.title, capacity: $0.capacity) }
        let card = RingRadarLayout(size: CGSize(width: 376, height: 280), rings: rings, entries: entries,
                                   measure: .system)
        let summaryMark = card.marks.first(where: \.isSummary)
        let summary = try #require(summaryMark)
        #expect(RingRadar.isPicked(summary, picked: SnapshotGallery.ReachRadarScene.pickedSummary.picked))
        #expect(!RingRadar.isPicked(summary, picked: SnapshotGallery.ReachRadarScene.picked.picked))
        let orcaMark = card.marks.first { $0.id == SnapshotGallery.pickedEcho }
        let orca = try #require(orcaMark)
        #expect(RingRadar.isPicked(orca, picked: [SnapshotGallery.pickedEcho]))
        #expect(!RingRadar.isPicked(orca, picked: []))
    }

    /// Der Rückruf geht nicht in den Vergleich ein: Ein neuer Messtakt mit gleichen Echos zeichnet das Radar nicht neu.
    @Test func equalityIgnoresThePickAction() {
        let echoes = SnapshotGallery.reachEchoes
        let first = ReachRadar(echoes: echoes, picked: [SnapshotGallery.pickedEcho]) { _ in }
        let second = ReachRadar(echoes: echoes, picked: [SnapshotGallery.pickedEcho]) { _ in }
        #expect(first == second)
        #expect(first != ReachRadar(echoes: echoes) { _ in })
        #expect(first != ReachRadar(echoes: echoes, picked: [SnapshotGallery.pickedEcho]))
    }

    /// VoiceOver liest jedes Echo mit der Beschriftung als Name und dem Ring als Wert.
    @Test func spokenEchoesNameLabelAndRing() {
        let spoken = RingRadar.spoken(SnapshotGallery.reachEchoes.map {
            RingRadar.Echo(id: $0.id, label: $0.label, ring: $0.ring.rawValue)
        }, rings: ReachRadar.rings)
        #expect(spoken.count == SnapshotGallery.reachEchoes.count)
        #expect(spoken.first?.label == "ACCpromAdapterDaemon :9200")
        #expect(spoken.first?.value == "nur dieser Mac")
        #expect(spoken.last?.plainText == "remoted :49152, aus dem Netz")
    }
}
