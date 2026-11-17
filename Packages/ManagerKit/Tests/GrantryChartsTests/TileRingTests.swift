import Foundation
import SwiftUI
import Testing
@testable import GrantryCharts

/// Bausteine der Kacheln im Übersichts-Baukasten (Spec 2026-11-09-uebersicht-baukasten § 2, #501): Ring mit Wert in der
/// Höhe einer Kachel 1 × 1 (auch ohne Messung und bei „100 %“) und Kennzahlen in einer Zeile. Neu aufzeichnen mit
/// `GRANTRY_RECORD_SNAPSHOTS=1`.
@MainActor
@Suite struct TileRingTests {
    nonisolated static let appearances = ChartAppearance.allCases

    @Test(arguments: appearances)
    func snapshot(_ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(TileRingGallery.view, named: "baukasten-kachelring", size: TileRingGallery.size,
                                 appearance: appearance)
    }
}

/// Ringe in der Inhaltshöhe einer Kachel 1 × 1 (unter dem Titel), darunter Kennzahlen.
@MainActor
enum TileRingGallery {
    static let size = CGSize(width: 260, height: 90)

    static var view: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.group) {
            HStack(spacing: InstrumentSpacing.group) {
                TileRing(fraction: 0.38, value: "38 %", hue: .cpu)
                TileRing(fraction: 1, value: "100 %", hue: .gpu)
                TileRing(fraction: nil, value: "–", hue: .memory)
            }
            .frame(height: 38)
            FactLine([PanelFact("Leerlauf", "62 %"), PanelFact("Takt", "3,2 GHz")])
        }
        .padding(InstrumentSpacing.cell)
        .frame(width: size.width, alignment: .topLeading)
    }
}
