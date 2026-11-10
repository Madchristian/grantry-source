import Foundation
import SwiftUI
import Testing
@testable import GrantryCharts

/// Bausteine der Übersicht in der Menüleiste (#495): Kernringe je Cluster, Wertringe mit Anteilen und der gestapelte
/// Verlauf – aus Formen, nie `Canvas` (#491). Neu aufzeichnen mit `GRANTRY_RECORD_SNAPSHOTS=1`.
@MainActor
@Suite struct OverviewRingsTests {
    nonisolated static let appearances = ChartAppearance.allCases

    @Test func ringFractionIsClampedAndMissingStaysEmpty() {
        #expect(LoadRing.trimmed(1.4) == 1)
        #expect(LoadRing.trimmed(-0.2) == 0)
        #expect(LoadRing.trimmed(.nan) == 0)
        #expect(LoadRing.trimmed(nil) == 0)
        #expect(LoadRing.trimmed(0.37) == 0.37)
    }

    /// Teile eines Wertrings liegen hintereinander und enden spätestens beim vollen Kreis.
    @Test func segmentsFollowEachOtherAndStopAtTheFullCircle() {
        let spans = ValueRing.spans([0.5, 0.25, 0.5])
        #expect(spans.map(\.start) == [0, 0.5, 0.75])
        #expect(spans.map(\.end) == [0.5, 0.75, 1])
    }

    /// Jede Gruppe trägt ihr Kürzel als Text, damit Kernarten nicht nur über die Farbe unterscheidbar sind.
    @Test func coreGroupsKeepTheirTags() {
        #expect(OverviewGallery.coreGroups(performance: 12, efficiency: 4).compactMap(\.tag) == ["P0", "P1", "E"])
    }

    @Test(arguments: appearances)
    func snapshot(_ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(OverviewGallery.view, named: "uebersicht-bausteine", size: OverviewGallery.size,
                                 appearance: appearance)
    }
}

/// Feste Beispiele: 12 Leistungs- und 4 Effizienzkerne, ein Speicherring mit drei Teilen, ein CPU-Verlauf.
@MainActor
enum OverviewGallery {
    static let size = CGSize(width: 440, height: 300)

    static func coreGroups(performance: Int, efficiency: Int) -> [CoreRingBoard.Group] {
        let ring = { (id: Int) in
            CoreRingBoard.Ring(id: id, load: Double((id * 37) % 100) / 100, label: "Kern \(id)", value: "\(id) %")
        }
        let half = performance / 2
        return [
            CoreRingBoard.Group(tag: "P0", hue: .cpu, rings: (efficiency..<efficiency + half).map(ring)),
            CoreRingBoard.Group(tag: "P1", hue: .cpu, rings: (efficiency + half..<efficiency + performance).map(ring)),
            CoreRingBoard.Group(tag: "E", hue: .efficiencyCores,
                                rings: (0..<efficiency).map(ring) + [CoreRingBoard.Ring(id: 99, load: nil,
                                                                                        label: "Kern 99",
                                                                                        value: "keine Messung")]),
        ]
    }

    static var view: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            CoreRingBoard(groups: coreGroups(performance: 12, efficiency: 4))
            HStack(spacing: InstrumentSpacing.panel) {
                ValueRing(parts: [ValueRing.Part(fraction: 0.4, hue: .memory), ValueRing.Part(fraction: 0.15, hue: .sent),
                                  ValueRing.Part(fraction: 0.1, hue: .diskWrite)],
                          value: "65 %", caption: "Belegt")
                ValueRing(parts: [ValueRing.Part(fraction: 0.44, hue: .gpu)], value: "44 %", caption: "Auslastung")
                ValueRing(parts: [], value: "–", caption: "Speicher")
            }
            StackedSparkline(lower: SnapshotGallery.series { 0.1 + 0.05 * sin($0 / 6) },
                             total: SnapshotGallery.series { 0.35 + 0.2 * sin($0 / 9) },
                             colors: (lower: .neuralEngine, upper: .cpu))
                .frame(height: 52)
        }
        .padding(InstrumentSpacing.page)
        .frame(width: size.width, alignment: .topLeading)
    }
}
