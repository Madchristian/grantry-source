import Foundation

/// Richtung beim Verschieben einer Kachel per Pfeiltaste oder VoiceOver-Aktion.
public enum OverviewMoveDirection: Sendable, CaseIterable {
    case left, right, up, down
}

/// Anordnung der Übersicht, wie Christian sie zusammenstellt (Spec 2026-11-09-uebersicht-baukasten § 3–5): Kacheln in
/// einer Reihenfolge, die Lage rechnet `OverviewGrid` daraus. Jede Kachel steht höchstens einmal darauf und nur in einer
/// ihrer erlaubten Größen. Alle Änderungen liefern `true`, wenn sich die Anordnung geändert hat; sonst bleibt sie gleich
/// (die Oberfläche meldet dann „nicht möglich“).
public struct OverviewBoardLayout: Equatable, Sendable {
    /// Packung der Tafel (Entscheidung E1 der Spec).
    public static let grid = OverviewGrid()

    public private(set) var tiles: [OverviewTile]

    /// Doppelte Kacheln fallen weg (die erste bleibt), verbotene Größen werden zur Standardgröße der Kachel.
    public init(tiles: [OverviewTile]) {
        var seen = Set<OverviewTileKind>()
        self.tiles = tiles.compactMap { tile in
            guard seen.insert(tile.kind).inserted else { return nil }
            return tile.kind.allowedSpans.contains(tile.span) ? tile : OverviewTile(tile.kind, tile.kind.defaultSpan)
        }
    }

    /// Standard wie das Popover der Übersicht vor dem Baukasten (Karten aus #495 im dichteren Aufbau aus PR 623), als
    /// Raster: CPU und Kerne als Leisten, Prozesse über die ganze Breite mit fünf Zeilen, darunter paarweise GPU und
    /// Arbeitsspeicher, Datenträger und Netz, unten Thermik, Akku, Durchschnittslast und Laufzeit – neun Zeilen.
    public static func standard(configured: Set<TaskManagerSource>) -> OverviewBoardLayout {
        OverviewBoardLayout(tiles: [
            OverviewTile(.cpu, .banner), OverviewTile(.cores, .banner), OverviewTile(.processes, .panel),
            OverviewTile(.gpu, .large), OverviewTile(.memory, .large), OverviewTile(.disk, .large),
            OverviewTile(.network, .large), OverviewTile(.thermal, .small), OverviewTile(.battery, .small),
            OverviewTile(.loadAverage, .small), OverviewTile(.uptime, .small),
        ]).available(configured: configured)
    }

    // MARK: - Lesen

    public func placements() -> [OverviewTilePlacement] { Self.grid.place(tiles) }

    public func contains(_ kind: OverviewTileKind) -> Bool { tiles.contains { $0.kind == kind } }

    public func span(of kind: OverviewTileKind) -> OverviewTileSpan? { tiles.first { $0.kind == kind }?.span }

    /// Quellen und Werte, die die Tafel braucht: nur die der gezeigten Kacheln.
    public var requirements: OverviewTileRequirements {
        tiles.reduce(OverviewTileRequirements()) { $0.union($1.kind.requirements) }
    }

    /// Kacheln des Katalogs: verfügbar und noch nicht auf der Tafel, in Katalogreihenfolge.
    public func addableKinds(configured: Set<TaskManagerSource>) -> [OverviewTileKind] {
        OverviewTileKind.allCases.filter { !contains($0) && $0.isAvailable(configured: configured) }
    }

    /// Ohne Kacheln, deren Quelle dieser Mac nicht hat.
    public func available(configured: Set<TaskManagerSource>) -> OverviewBoardLayout {
        OverviewBoardLayout(tiles: tiles.filter { $0.kind.isAvailable(configured: configured) })
    }

    // MARK: - Ändern

    /// Fügt eine Kachel ein, ohne Index hinten; ohne Größe in ihrer Standardgröße.
    @discardableResult
    public mutating func insert(_ kind: OverviewTileKind, span: OverviewTileSpan? = nil, at index: Int? = nil) -> Bool {
        let span = span ?? kind.defaultSpan
        guard !contains(kind), kind.allowedSpans.contains(span) else { return false }
        tiles.insert(OverviewTile(kind, span), at: min(max(index ?? tiles.count, 0), tiles.count))
        return true
    }

    /// Entfernt eine Kachel; die folgenden rücken nach.
    @discardableResult
    public mutating func remove(_ kind: OverviewTileKind) -> Bool {
        guard contains(kind) else { return false }
        tiles.removeAll { $0.kind == kind }
        return true
    }

    /// Ändert die Größe einer Kachel auf der Tafel; die übrigen ordnen sich neu.
    @discardableResult
    public mutating func resize(_ kind: OverviewTileKind, to span: OverviewTileSpan) -> Bool {
        guard let index = tiles.firstIndex(where: { $0.kind == kind }), tiles[index].span != span,
              kind.allowedSpans.contains(span) else { return false }
        tiles[index] = OverviewTile(kind, span)
        return true
    }

    /// Legt eine Kachel (von der Tafel oder aus dem Katalog) so ab, dass sie der Zielzelle am nächsten kommt; die
    /// übrigen behalten ihre Reihenfolge und rücken nach.
    @discardableResult
    public mutating func place(_ kind: OverviewTileKind, span: OverviewTileSpan? = nil,
                               at target: OverviewGridCell) -> Bool {
        let placed = placing(kind, span: span, at: target)
        guard placed != self else { return false }
        self = placed
        return true
    }

    /// Vorschau beim Ziehen: die Anordnung nach `place`, ohne diese zu ändern.
    public func placing(_ kind: OverviewTileKind, span: OverviewTileSpan? = nil,
                        at target: OverviewGridCell) -> OverviewBoardLayout {
        let span = span ?? self.span(of: kind) ?? kind.defaultSpan
        guard kind.allowedSpans.contains(span) else { return self }
        let candidates = self.candidates(moving: OverviewTile(kind, span))
        return candidates.min { lhs, rhs in
            placementKey(lhs, target: target) < placementKey(rhs, target: target)
        }?.layout ?? self
    }

    /// Verschiebt eine Kachel um einen Schritt: links und rechts in Lesereihenfolge an die nächste Stelle, hoch und
    /// runter in die nächste Zeile darüber bzw. darunter (bei mehreren möglichst in derselben Spalte).
    @discardableResult
    public mutating func move(_ kind: OverviewTileKind, _ direction: OverviewMoveDirection) -> Bool {
        guard let index = tiles.firstIndex(where: { $0.kind == kind }), let start = anchor(of: kind) else {
            return false
        }
        let moves = candidates(moving: tiles[index]).compactMap { candidate -> (Candidate, OverviewGridCell)? in
            guard let anchor = candidate.layout.anchor(of: kind), Self.points(from: start, to: anchor, direction) else {
                return nil
            }
            return (candidate, anchor)
        }
        let best = moves.min { lhs, rhs in
            Self.stepKey(from: start, to: lhs.1, direction, shift: abs(lhs.0.index - index))
                < Self.stepKey(from: start, to: rhs.1, direction, shift: abs(rhs.0.index - index))
        }
        guard let best else { return false }
        self = best.0.layout
        return true
    }

    // MARK: - Hilfen

    private struct Candidate {
        let index: Int
        let layout: OverviewBoardLayout
    }

    private func anchor(of kind: OverviewTileKind) -> OverviewGridCell? {
        placements().first { $0.kind == kind }?.anchor
    }

    /// Jede Stelle in der Reihenfolge der übrigen Kacheln.
    private func candidates(moving tile: OverviewTile) -> [Candidate] {
        let others = tiles.filter { $0.kind != tile.kind }
        return (0...others.count).map { index in
            var tiles = others
            tiles.insert(tile, at: index)
            return Candidate(index: index, layout: OverviewBoardLayout(tiles: tiles))
        }
    }

    /// Abstand zur Zielzelle; bei Gleichstand die unveränderte Anordnung, dann die frühere Stelle.
    private func placementKey(_ candidate: Candidate, target: OverviewGridCell) -> (Int, Int, Int) {
        let anchor = candidate.layout.anchor(of: candidate.layout.tiles[candidate.index].kind) ?? target
        let columns = anchor.column - target.column
        let rows = anchor.row - target.row
        return (columns * columns + rows * rows, candidate.layout == self ? 0 : 1, candidate.index)
    }

    private static func points(from start: OverviewGridCell, to anchor: OverviewGridCell,
                               _ direction: OverviewMoveDirection) -> Bool {
        switch direction {
        case .left: (anchor.row, anchor.column) < (start.row, start.column)
        case .right: (anchor.row, anchor.column) > (start.row, start.column)
        case .up: anchor.row < start.row
        case .down: anchor.row > start.row
        }
    }

    /// Kleinster Schritt in der Richtung; bei Gleichstand die kleinste Umstellung der Reihenfolge.
    private static func stepKey(from start: OverviewGridCell, to anchor: OverviewGridCell,
                                _ direction: OverviewMoveDirection, shift: Int) -> (Int, Int, Int) {
        let rows = abs(anchor.row - start.row)
        let columns = abs(anchor.column - start.column)
        switch direction {
        case .left, .right:
            // Lesereihenfolge: erst die Zeile, dann die Spalte.
            return (rows, rows == 0 ? columns : (direction == .right ? anchor.column : -anchor.column), shift)
        case .up, .down:
            return (rows, columns, shift)
        }
    }
}
