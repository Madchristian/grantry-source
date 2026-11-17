import CoreGraphics

/// Zelle des Kachelrasters, ab 0 von links oben (Spec 2026-11-09-uebersicht-baukasten § 3). Ohne ManagerKit-Typen;
/// die App übersetzt `OverviewGridCell` und `OverviewTileSpan` in diese Werte.
public struct BoardGridCell: Hashable, Sendable {
    public let column: Int
    public let row: Int

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }
}

/// Lage und Größe einer Kachel in Zellen.
public struct BoardGridFrame: Hashable, Sendable {
    public let column: Int
    public let row: Int
    public let columns: Int
    public let rows: Int

    public init(column: Int, row: Int, columns: Int, rows: Int) {
        self.column = column
        self.row = row
        self.columns = columns
        self.rows = rows
    }
}

/// Maße des Kachelrasters: Spaltenbreite aus der verfügbaren Breite, feste Zeilenhöhe, gleicher Abstand waagerecht und
/// senkrecht. Rechnet Rahmen je Kachel, die Zelle unter dem Zeiger (Ablegen) und die gezogene Größe in Zellen (Griff).
public struct BoardGridMetrics: Equatable, Sendable {
    public static let columns = 4

    public let width: CGFloat
    public let rowHeight: CGFloat
    public let spacing: CGFloat

    public init(width: CGFloat, rowHeight: CGFloat = InstrumentSize.boardRow,
                spacing: CGFloat = InstrumentSpacing.group) {
        self.width = width
        self.rowHeight = rowHeight
        self.spacing = spacing
    }

    public var columnWidth: CGFloat {
        max(0, (width - spacing * CGFloat(Self.columns - 1)) / CGFloat(Self.columns))
    }

    public func frame(of frame: BoardGridFrame) -> CGRect {
        CGRect(x: CGFloat(frame.column) * (columnWidth + spacing), y: CGFloat(frame.row) * (rowHeight + spacing),
               width: extent(frame.columns, columnWidth), height: extent(frame.rows, rowHeight))
    }

    /// Höhe von `rows` Zeilen samt Abständen.
    public func height(rows: Int) -> CGFloat { extent(rows, rowHeight) }

    /// Zelle unter einem Punkt; ein Abstand zählt zur Zelle davor, außerhalb gilt die nächste Zelle am Rand.
    public func cell(at point: CGPoint) -> BoardGridCell {
        let column = Int((point.x / (columnWidth + spacing)).rounded(.down))
        let row = Int((point.y / (rowHeight + spacing)).rounded(.down))
        return BoardGridCell(column: min(max(column, 0), Self.columns - 1), row: max(row, 0))
    }

    /// Gezogene Größe in Zellen, gebrochen: Eine Zelle zählt mit ihrem Abstand.
    public func cells(for size: CGSize) -> (columns: Double, rows: Double) {
        (columns: Double(max(0, (size.width + spacing) / (columnWidth + spacing))),
         rows: Double(max(0, (size.height + spacing) / (rowHeight + spacing))))
    }

    private func extent(_ count: Int, _ cell: CGFloat) -> CGFloat {
        count > 0 ? CGFloat(count) * cell + CGFloat(count - 1) * spacing : 0
    }
}
