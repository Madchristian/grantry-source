import Foundation
import SwiftUI
import Testing
@testable import GrantryCharts

/// Raster des Übersichts-Baukastens (Spec 2026-11-09-uebersicht-baukasten § 3): Spaltenbreite aus der Breite des
/// Popovers, feste Zeilenhöhe, Rahmen je Kachel, Zelle unter dem Zeiger und Einrasten des Größengriffs. Neu aufzeichnen
/// mit `GRANTRY_RECORD_SNAPSHOTS=1`.
@MainActor
@Suite struct BoardGridTests {
    nonisolated static let appearances = ChartAppearance.allCases

    /// 440 pt Popover minus Seitenrand: 412 pt, vier Spalten mit 8 pt Abstand.
    private let metrics = BoardGridMetrics(width: 412)

    @Test func columnWidthFillsTheWidth() {
        #expect(metrics.columnWidth == 97)
        #expect(metrics.rowHeight == InstrumentSize.boardRow)
        #expect(metrics.spacing == InstrumentSpacing.group)
    }

    @Test func frameSpansCellsAndGaps() {
        #expect(metrics.frame(of: BoardGridFrame(column: 0, row: 0, columns: 1, rows: 1))
            == CGRect(x: 0, y: 0, width: 97, height: InstrumentSize.boardRow))
        let row = InstrumentSize.boardRow + InstrumentSpacing.group
        #expect(metrics.frame(of: BoardGridFrame(column: 2, row: 1, columns: 2, rows: 2))
            == CGRect(x: 210, y: row, width: 202, height: InstrumentSize.boardRow * 2 + InstrumentSpacing.group))
        #expect(metrics.frame(of: BoardGridFrame(column: 0, row: 3, columns: 4, rows: 1)).width == 412)
    }

    @Test func heightCoversAllRows() {
        #expect(metrics.height(rows: 0) == 0)
        #expect(metrics.height(rows: 3) == InstrumentSize.boardRow * 3 + InstrumentSpacing.group * 2)
    }

    /// Ablegen: Die Zelle unter einem Punkt, auf das Raster begrenzt; Abstände zählen zur Zelle davor.
    @Test func cellUnderAPointIsClampedToTheGrid() {
        #expect(metrics.cell(at: CGPoint(x: 10, y: 10)) == BoardGridCell(column: 0, row: 0))
        #expect(metrics.cell(at: CGPoint(x: 100, y: 10)) == BoardGridCell(column: 0, row: 0))
        #expect(metrics.cell(at: CGPoint(x: 106, y: InstrumentSize.boardRow + 9)) == BoardGridCell(column: 1, row: 1))
        #expect(metrics.cell(at: CGPoint(x: 900, y: -40)) == BoardGridCell(column: 3, row: 0))
        #expect(metrics.cell(at: CGPoint(x: -5, y: 2000)).column == 0)
    }

    /// Größengriff: Die gezogene Größe in Zellen, gebrochen; das Einrasten auf erlaubte Größen macht das Kit.
    @Test func dragSizeInCells() {
        let size = metrics.cells(for: CGSize(width: 202, height: InstrumentSize.boardRow))
        #expect(abs(size.columns - 2) < 0.001)
        #expect(abs(size.rows - 1) < 0.001)
        #expect(metrics.cells(for: CGSize(width: -10, height: -10)) == (columns: 0, rows: 0))
    }

    @Test(arguments: appearances)
    func placeholderSnapshot(_ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(BoardGridGallery.view, named: "baukasten-platzhalter", size: BoardGridGallery.size,
                                 appearance: appearance)
    }
}

/// Platzhalter in allen fünf Größen auf dem Raster, wie der Editor sie vor den echten Kacheln zeigt.
@MainActor
enum BoardGridGallery {
    static let size = CGSize(width: 440, height: 400)

    static var view: some View {
        let frames = [
            BoardGridFrame(column: 0, row: 0, columns: 4, rows: 1), BoardGridFrame(column: 0, row: 1, columns: 2, rows: 2),
            BoardGridFrame(column: 2, row: 1, columns: 2, rows: 1), BoardGridFrame(column: 2, row: 2, columns: 1, rows: 1),
            BoardGridFrame(column: 0, row: 3, columns: 4, rows: 1),
        ]
        let titles = ["CPU", "Prozesse", "Arbeitsspeicher", "Thermik", "Kerne"]
        return BoardGrid(metrics: BoardGridMetrics(width: 412)) {
            ForEach(Array(zip(frames, titles)), id: \.1) { frame, title in
                PlaceholderTile(title: title, symbolName: "square.dashed", columns: frame.columns, rows: frame.rows)
                    .boardGridFrame(frame)
            }
        }
        .padding(InstrumentSpacing.page)
        .frame(width: size.width, alignment: .topLeading)
    }
}
