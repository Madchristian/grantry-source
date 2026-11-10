import CoreGraphics
import Testing
@testable import GrantryCharts

/// Aufteilung der Panels und Kacheln im Chip-Tab und in „Pro Kern“.
@Suite struct ChipLayoutTests {
    @Test func equalWeightsShareTheWidth() {
        #expect(WeightedRow(spacing: 12).widths(total: 1012, weights: [1, 1]) == [500, 500])
    }

    /// M4 Max: 12 Leistungs-, 4 Effizienzkerne.
    @Test func widthFollowsCoreCount() {
        #expect(WeightedRow(spacing: 12).widths(total: 1012, weights: [12, 4]) == [750, 250])
    }

    /// M1 Pro: 8 zu 2 Kernen – das schmale Panel bleibt lesbar, das breite gibt ab.
    @Test func narrowPanelKeepsMinimumWidth() {
        #expect(WeightedRow(spacing: 12, minimumWidth: 250).widths(total: 1012, weights: [8, 2]) == [750, 250])
    }

    @Test func tooNarrowRowSharesEqually() {
        #expect(WeightedRow(spacing: 0, minimumWidth: 250).widths(total: 300, weights: [2, 1]) == [200, 100])
    }

    /// Ohne Cluster wie das adaptive Raster; eine Clusterreihe füllt die Breite mit ihren Kernen.
    @Test func tileColumns() {
        #expect(TileGrid(stretches: false).columns(width: 560, count: 4) == 6)
        #expect(TileGrid(stretches: true).columns(width: 560, count: 4) == 4)
        #expect(TileGrid(stretches: true).columns(width: 300, count: 6) == 3)
        #expect(TileGrid(stretches: true).columns(width: 10, count: 6) == 1)
    }

    /// Beim Messen der Idealgröße schlägt SwiftUI unendliche Breiten vor; das darf nicht abstürzen (Chip-Grundriss).
    @Test func infiniteWidthKeepsOneRow() {
        #expect(TileGrid(stretches: true).columns(width: .infinity, count: 6) == 6)
    }
}
