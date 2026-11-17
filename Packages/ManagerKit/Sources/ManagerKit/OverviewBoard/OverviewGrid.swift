import Foundation

/// Kachel auf der Tafel: Art und Größe. Die Lage folgt aus der Reihenfolge (`OverviewGrid`).
public struct OverviewTile: Hashable, Sendable, Identifiable {
    public let kind: OverviewTileKind
    public let span: OverviewTileSpan

    public init(_ kind: OverviewTileKind, _ span: OverviewTileSpan) {
        self.kind = kind
        self.span = span
    }

    public var id: OverviewTileKind { kind }
}

/// Zelle des Rasters, gezählt ab 0 von links oben.
public struct OverviewGridCell: Hashable, Sendable, CustomStringConvertible {
    public let column: Int
    public let row: Int

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }

    public var description: String { "(\(column), \(row))" }
}

/// Kachel mit ihrer Lage; `anchor` ist die Zelle links oben.
public struct OverviewTilePlacement: Hashable, Sendable, Identifiable {
    public let tile: OverviewTile
    public let anchor: OverviewGridCell

    public init(tile: OverviewTile, anchor: OverviewGridCell) {
        self.tile = tile
        self.anchor = anchor
    }

    public var id: OverviewTileKind { tile.kind }
    public var kind: OverviewTileKind { tile.kind }
    public var span: OverviewTileSpan { tile.span }

    public var cells: [OverviewGridCell] { Self.cells(of: span, at: anchor) }

    static func cells(of span: OverviewTileSpan, at anchor: OverviewGridCell) -> [OverviewGridCell] {
        (anchor.row..<anchor.row + span.rows).flatMap { row in
            (anchor.column..<anchor.column + span.columns).map { OverviewGridCell(column: $0, row: row) }
        }
    }

    public func contains(_ cell: OverviewGridCell) -> Bool {
        (anchor.column..<anchor.column + span.columns).contains(cell.column)
            && (anchor.row..<anchor.row + span.rows).contains(cell.row)
    }
}

/// Raster des Baukastens (Spec § 3): vier Spalten über die Breite des Popovers, Zeilen nach Bedarf. Jede Kachel kommt
/// in Listenreihenfolge an die erste freie Stelle (Zeile, dann Spalte), an der sie ganz passt – so rücken die übrigen
/// nach, wenn eine Kachel entfällt oder schrumpft, und es entstehen keine Überlappungen.
public struct OverviewGrid: Sendable {
    public static let columns = 4

    public enum Packing: Sendable {
        /// Jede Kachel sucht ab links oben; spätere kleine Kacheln füllen Lücken vor einer breiten (Standard, E1).
        case dense
        /// Jede Kachel sucht erst ab der Stelle ihrer Vorgängerin; die Lesereihenfolge ist die Listenreihenfolge.
        case ordered
    }

    public let packing: Packing

    public init(packing: Packing = .dense) {
        self.packing = packing
    }

    /// Lage aller Kacheln in Listenreihenfolge.
    public func place(_ tiles: [OverviewTile]) -> [OverviewTilePlacement] {
        var occupied = Set<OverviewGridCell>()
        var cursor = OverviewGridCell(column: 0, row: 0)
        return tiles.map { tile in
            let anchor = firstFit(tile.span, from: packing == .dense ? OverviewGridCell(column: 0, row: 0) : cursor,
                                  occupied: occupied)
            let placement = OverviewTilePlacement(tile: tile, anchor: anchor)
            occupied.formUnion(placement.cells)
            cursor = anchor
            return placement
        }
    }

    /// Belegte Zeilen.
    public func rowCount(of placements: [OverviewTilePlacement]) -> Int {
        placements.map { $0.anchor.row + $0.span.rows }.max() ?? 0
    }

    /// Lesereihenfolge (Zeile, dann Spalte): für VoiceOver, Tastatur und Fokus.
    public static func readingOrder(_ placements: [OverviewTilePlacement]) -> [OverviewTilePlacement] {
        placements.sorted { ($0.anchor.row, $0.anchor.column) < ($1.anchor.row, $1.anchor.column) }
    }

    private func firstFit(_ span: OverviewTileSpan, from start: OverviewGridCell,
                          occupied: Set<OverviewGridCell>) -> OverviewGridCell {
        let width = min(span.columns, Self.columns)
        var row = start.row
        var column = start.column
        while true {
            let anchor = OverviewGridCell(column: column, row: row)
            if column + width <= Self.columns,
               OverviewTilePlacement.cells(of: span, at: anchor).allSatisfy({ !occupied.contains($0) }) {
                return anchor
            }
            column += 1
            if column >= Self.columns {
                column = 0
                row += 1
            }
        }
    }
}
