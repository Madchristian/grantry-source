import Testing
@testable import ManagerKit

/// Bearbeiten der Tafel (Spec 2026-11-09-uebersicht-baukasten § 5): ein Befehl für Maus, Tastatur, Kontextmenü und
/// VoiceOver, je mit Ansage der neuen Lage oder einem Hinweis, wenn nichts geht; nächste erlaubte Größe für ⌘+ und ⌘−,
/// Größengriff, Auswahl in Lesereihenfolge.
@Suite struct OverviewBoardEditingTests {
    private let all = Set(TaskManagerSource.allCases)
    private var standard: OverviewBoardLayout { .standard(configured: all) }

    private func layout(_ tiles: [(OverviewTileKind, OverviewTileSpan)]) -> OverviewBoardLayout {
        OverviewBoardLayout(tiles: tiles.map { OverviewTile($0.0, $0.1) })
    }

    /// Führt einen Befehl außerhalb von `#expect` aus (das Makro zerlegt mutierende Aufrufe).
    private func apply(_ command: OverviewEditCommand, to kind: OverviewTileKind,
                       on board: inout OverviewBoardLayout) -> OverviewEditResult {
        board.apply(command, to: kind)
    }

    // MARK: - Lage und Ansage

    @Test func spokenPositionCountsRowsAndColumnsFromOne() {
        #expect(standard.spokenPosition(of: .disk) == "Datenträger, Zeile 7, Spalte 1, 2 × 2")
        #expect(standard.spokenPosition(of: .uptime) == "Laufzeit, Zeile 9, Spalte 4, 1 × 1")
        #expect(layout([(.cpu, .wide)]).spokenPosition(of: .disk) == nil)
    }

    @Test func placementOfAKindOnTheBoard() {
        #expect(standard.placement(of: .gpu)?.anchor == OverviewGridCell(column: 0, row: 4))
        #expect(standard.placement(of: .gpu)?.span == .large)
        #expect(layout([(.cpu, .wide)]).placement(of: .gpu) == nil)
    }

    // MARK: - Größe

    /// ⌘+ und ⌘−: die nächste erlaubte Größe der Kachel, aufsteigend nach Fläche.
    @Test func steppingGoesToTheNextAllowedSpan() {
        let board = layout([(.cpu, .wide), (.thermal, .small), (.cores, .wide)])
        #expect(board.span(of: .cpu, stepped: .larger) == .large)
        #expect(board.span(of: .cpu, stepped: .smaller) == .small)
        #expect(board.span(of: .thermal, stepped: .larger) == .wide)
        #expect(board.span(of: .thermal, stepped: .smaller) == nil, "schon die kleinste")
        #expect(board.span(of: .cores, stepped: .smaller) == nil, "Kerne gibt es nicht in 1 × 1")
        #expect(board.span(of: .gpu, stepped: .larger) == nil, "nicht auf der Tafel")
    }

    /// Größengriff: gezogene Größe in Zellen, eingerastet auf die nächste erlaubte Größe der Kachel.
    @Test func handleSnapsToTheNearestAllowedSpan() {
        #expect(OverviewTileKind.cpu.span(columns: 3.7, rows: 1.2) == .banner)
        #expect(OverviewTileKind.thermal.span(columns: 3.7, rows: 2.2) == .wide)
        #expect(OverviewTileKind.cores.span(columns: 0.4, rows: 0.4) == .wide)
        #expect(OverviewTileKind.processes.span(columns: 2.2, rows: 1.8) == .large)
    }

    // MARK: - Befehle

    @Test func moveAnnouncesTheNewPosition() {
        var board = standard
        let result = apply(.move(.right), to: .disk, on: &board)
        #expect(result.changed)
        #expect(result.message == board.spokenPosition(of: .disk))
        #expect(board.placement(of: .disk)?.anchor == OverviewGridCell(column: 2, row: 6))
        #expect(result.selection == .disk)
    }

    @Test func impossibleMoveGivesAHintInsteadOfSilence() {
        var board = standard
        let result = apply(.move(.up), to: .cpu, on: &board)
        #expect(!result.changed)
        #expect(result.message == "CPU lässt sich nicht weiter nach oben verschieben")
        #expect(board == standard)
        #expect(result.selection == .cpu)
    }

    @Test func steppingTheSizeAnnouncesOrHints() {
        var board = standard
        let larger = apply(.step(.larger), to: .disk, on: &board)
        #expect(larger.changed)
        #expect(board.span(of: .disk) == .banner)
        #expect(larger.message == board.spokenPosition(of: .disk))
        let smallest = apply(.step(.smaller), to: .thermal, on: &board)
        #expect(!smallest.changed)
        #expect(smallest.message == "Thermik hat schon die kleinste Größe")
        let largest = apply(.step(.larger), to: .thermal, on: &board)
        #expect(largest.changed)
        #expect(apply(.step(.larger), to: .thermal, on: &board).message == "Thermik hat schon die größte Größe")
    }

    @Test func resizingToAForbiddenSpanIsRefused() {
        var board = standard
        let result = apply(.resize(.panel), to: .thermal, on: &board)
        #expect(!result.changed)
        #expect(result.message == "Thermik gibt es nicht in 4 × 2")
        let same = apply(.resize(.small), to: .thermal, on: &board)
        #expect(!same.changed)
        #expect(same.message == board.spokenPosition(of: .thermal), "unverändert: nur die Lage")
        #expect(apply(.resize(.wide), to: .thermal, on: &board).changed)
    }

    /// Ablegen von der Tafel oder aus dem Katalog: Einrasten wie `place`, Ansage der Lage; ohne Änderung nur die Lage.
    @Test func droppingAnnouncesThePosition() {
        var board = layout([(.cpu, .banner), (.gpu, .wide), (.disk, .wide)])
        let dropped = apply(.place(OverviewGridCell(column: 0, row: 1)), to: .disk, on: &board)
        #expect(dropped.changed)
        #expect(dropped.message == "Datenträger, Zeile 2, Spalte 1, 2 × 1")
        let again = apply(.place(OverviewGridCell(column: 0, row: 1)), to: .disk, on: &board)
        #expect(!again.changed)
        #expect(again.message == dropped.message)
        let fromCatalog = apply(.place(OverviewGridCell(column: 0, row: 2)), to: .thermal, on: &board)
        #expect(fromCatalog.changed)
        #expect(board.span(of: .thermal) == .small, "aus dem Katalog in Standardgröße")
        #expect(fromCatalog.selection == .thermal)
    }

    @Test func addingAppendsWithTheDefaultSpan() {
        var board = layout([(.cpu, .banner)])
        let result = apply(.add, to: .memory, on: &board)
        #expect(result.changed)
        #expect(board.tiles.last == OverviewTile(.memory, .wide))
        #expect(result.message == "Arbeitsspeicher, Zeile 2, Spalte 1, 2 × 1")
        #expect(result.selection == .memory)
        let again = apply(.add, to: .memory, on: &board)
        #expect(!again.changed)
        #expect(again.message == "Arbeitsspeicher ist schon auf der Tafel")
    }

    /// Entfernen wählt die nächste Kachel in Lesereihenfolge, an letzter Stelle die vorige.
    @Test func removingSelectsTheNeighbour() {
        var board = layout([(.cpu, .wide), (.gpu, .wide), (.disk, .small)])
        let middle = apply(.remove, to: .gpu, on: &board)
        #expect(middle.changed)
        #expect(middle.message == "GPU entfernt")
        #expect(middle.selection == .disk)
        #expect(apply(.remove, to: .disk, on: &board).selection == .cpu)
        #expect(apply(.remove, to: .cpu, on: &board).selection == nil)
        let missing = apply(.remove, to: .cpu, on: &board)
        #expect(!missing.changed)
        #expect(missing.message == "CPU ist nicht auf der Tafel")
    }

    // MARK: - Auswahl

    /// Tab und ⇧Tab: Kacheln in Lesereihenfolge; hinter der letzten bzw. vor der ersten `nil` (der Fokus verlässt die
    /// Tafel).
    @Test func selectionWalksInReadingOrder() {
        let board = layout([(.processes, .large), (.gpu, .wide), (.memory, .wide)])
        #expect(board.selection(after: nil, forward: true) == .processes)
        #expect(board.selection(after: nil, forward: false) == .memory)
        #expect(board.selection(after: .processes, forward: true) == .gpu)
        #expect(board.selection(after: .gpu, forward: true) == .memory)
        #expect(board.selection(after: .memory, forward: true) == nil)
        #expect(board.selection(after: .processes, forward: false) == nil)
        #expect(board.selection(after: .cpu, forward: true) == .processes, "nicht auf der Tafel: von vorn")
    }
}
