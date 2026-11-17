import Testing
@testable import ManagerKit

/// Anordnung des Baukastens (Spec § 3–5): Standard, Einfügen und Entfernen mit Nachrücken, Größe ändern, Ziehen mit
/// Einrasten an der nächstmöglichen Stelle, Verschieben per Tastatur, Bedarf an Quellen nur der gezeigten Kacheln.
@Suite struct OverviewBoardLayoutTests {
    private let all = Set(TaskManagerSource.allCases)

    private func anchor(_ kind: OverviewTileKind, in layout: OverviewBoardLayout) -> OverviewGridCell? {
        layout.placements().first { $0.kind == kind }?.anchor
    }

    /// Ändert die Anordnung außerhalb von `#expect` (das Makro zerlegt mutierende Aufrufe).
    private func change(_ board: inout OverviewBoardLayout, _ edit: (inout OverviewBoardLayout) -> Bool) -> Bool {
        edit(&board)
    }

    private func layout(_ tiles: [(OverviewTileKind, OverviewTileSpan)]) -> OverviewBoardLayout {
        OverviewBoardLayout(tiles: tiles.map { OverviewTile($0.0, $0.1) })
    }

    // MARK: - Standard

    /// Standard wie das Popover der Übersicht vor dem Baukasten (Karten aus #495 mit dem dichteren Aufbau aus PR 623):
    /// CPU und Kerne je eine Leiste, Prozesse über die ganze Breite mit fünf Zeilen, darunter paarweise GPU und
    /// Arbeitsspeicher, Datenträger und Netz, unten die vier kleinen Werte.
    @Test func standardLayoutShowsEveryCardOfTheOverview() {
        let standard = OverviewBoardLayout.standard(configured: all)
        #expect(standard.tiles.map(\.kind) == OverviewTileKind.allCases)
        #expect(standard.tiles.map(\.span) == [.banner, .banner, .panel, .large, .large, .large, .large, .small, .small,
                                               .small, .small])
        let anchors: [(Int, Int)] = [(0, 0), (0, 1), (0, 2), (0, 4), (2, 4), (0, 6), (2, 6), (0, 8), (1, 8), (2, 8),
                                     (3, 8)]
        let expected = anchors.map { OverviewGridCell(column: $0.0, row: $0.1) }
        #expect(standard.placements().map(\.anchor) == expected)
        #expect(OverviewGrid().rowCount(of: standard.placements()) == 9)
    }

    @Test func standardLayoutLeavesOutUnavailableTiles() {
        let standard = OverviewBoardLayout.standard(configured: all.subtracting([.battery, .gpu]))
        #expect(!standard.contains(.battery) && !standard.contains(.gpu))
        #expect(standard.contains(.thermal))
    }

    // MARK: - Bereinigung

    @Test func duplicateKindsAndForbiddenSpansAreRepaired() {
        let repaired = layout([(.cpu, .wide), (.cpu, .banner), (.uptime, .panel)])
        #expect(repaired.tiles == [OverviewTile(.cpu, .wide), OverviewTile(.uptime, OverviewTileKind.uptime.defaultSpan)])
    }

    // MARK: - Einfügen, Entfernen, Größe

    @Test func insertingAddsAtTheEndWithDefaultSpan() {
        var board = layout([(.cpu, .banner)])
        #expect(change(&board) { $0.insert(.memory) })
        #expect(board.tiles.last == OverviewTile(.memory, OverviewTileKind.memory.defaultSpan))
        #expect(!change(&board) { $0.insert(.memory) }, "jede Kachel nur einmal")
        #expect(!change(&board) { $0.insert(.thermal, span: .panel) }, "Größe nicht erlaubt")
    }

    @Test func removingLetsFollowingTilesMoveUp() {
        var board = layout([(.cpu, .banner), (.memory, .wide), (.disk, .wide)])
        #expect(change(&board) { $0.remove(.cpu) })
        #expect(anchor(.memory, in: board) == .init(column: 0, row: 0))
        #expect(!change(&board) { $0.remove(.cpu) })
    }

    @Test func resizingOnlyToAllowedSpans() {
        var board = layout([(.thermal, .small), (.uptime, .small), (.memory, .wide)])
        #expect(change(&board) { $0.resize(.thermal, to: .wide) })
        #expect(anchor(.memory, in: board) == .init(column: 0, row: 1))
        #expect(!change(&board) { $0.resize(.thermal, to: .wide) }, "unverändert")
        #expect(!change(&board) { $0.resize(.thermal, to: .panel) })
        #expect(!change(&board) { $0.resize(.cpu, to: .wide) }, "nicht auf der Tafel")
    }

    @Test func addableKindsAreTheMissingAvailableOnes() {
        let board = layout([(.cpu, .banner), (.memory, .wide)])
        let desktop = all.subtracting([.battery])
        let missing: Set<OverviewTileKind> = [.cpu, .memory, .battery]
        let expected = OverviewTileKind.allCases.filter { !missing.contains($0) }
        #expect(board.addableKinds(configured: desktop) == expected)
    }

    // MARK: - Ziehen und Einrasten

    /// Abgelegt wird an der Stelle, die der Zielzelle am nächsten kommt – mit Nachrücken der anderen Kacheln.
    @Test func droppingSnapsToTheTargetCell() {
        var board = layout([(.cpu, .wide), (.gpu, .wide), (.memory, .wide), (.disk, .wide)])
        #expect(change(&board) { $0.place(.disk, at: .init(column: 0, row: 0)) })
        #expect(board.tiles.map(\.kind) == [.disk, .cpu, .gpu, .memory])
        #expect(change(&board) { $0.place(.disk, at: .init(column: 3, row: 1)) })
        #expect(anchor(.disk, in: board) == .init(column: 2, row: 1))
        #expect(!change(&board) { $0.place(.disk, at: .init(column: 2, row: 1)) }, "schon dort")
    }

    @Test func droppingFromTheCatalogInsertsAtTheTarget() {
        var board = layout([(.cpu, .banner), (.memory, .wide), (.disk, .wide)])
        #expect(change(&board) { $0.place(.thermal, span: .small, at: .init(column: 0, row: 1)) })
        #expect(board.tiles.map(\.kind) == [.cpu, .thermal, .memory, .disk])
        #expect(!change(&board) { $0.place(.uptime, span: .panel, at: .init(column: 0, row: 0)) }, "Größe nicht erlaubt")
    }

    @Test func dropPreviewLeavesTheLayoutUntouched() {
        let board = layout([(.cpu, .wide), (.gpu, .wide)])
        let preview = board.placing(.gpu, at: .init(column: 0, row: 0))
        #expect(preview.tiles.map(\.kind) == [.gpu, .cpu])
        #expect(board.tiles.map(\.kind) == [.cpu, .gpu])
    }

    // MARK: - Tastatur und VoiceOver

    @Test func arrowKeysMoveOneStepInReadingOrder() {
        var board = layout([(.thermal, .small), (.battery, .small), (.uptime, .small), (.loadAverage, .small),
                            (.memory, .wide), (.disk, .wide)])
        #expect(change(&board) { $0.move(.battery, .right) })
        #expect(anchor(.battery, in: board) == .init(column: 2, row: 0))
        #expect(anchor(.uptime, in: board) == .init(column: 1, row: 0))
        #expect(change(&board) { $0.move(.battery, .left) })
        #expect(change(&board) { $0.move(.battery, .left) })
        #expect(anchor(.battery, in: board) == .init(column: 0, row: 0))
        #expect(!change(&board) { $0.move(.battery, .left) }, "schon vorne")
        #expect(!change(&board) { $0.move(.disk, .right) }, "schon hinten")
    }

    @Test func arrowKeysMoveBetweenRows() {
        var board = layout([(.cpu, .banner), (.memory, .wide), (.disk, .wide), (.thermal, .small)])
        #expect(change(&board) { $0.move(.disk, .up) })
        #expect(anchor(.disk, in: board)?.row == 0)
        #expect(!change(&board) { $0.move(.disk, .up) }, "schon oben")
        #expect(change(&board) { $0.move(.disk, .down) })
        #expect(anchor(.disk, in: board)?.row == 1)
        #expect(change(&board) { $0.move(.cpu, .down) })
        #expect(anchor(.cpu, in: board)?.row == 1)
    }

    /// Jede Bewegung ändert die Lage sichtbar oder meldet `false` – nie ein stilles Nichts.
    @Test func everySuccessfulMoveChangesTheAnchor() {
        var generator = BoardRandom(seed: 11)
        for _ in 0..<200 {
            var board = OverviewBoardLayout(tiles: OverviewTileKind.allCases.shuffled(using: &generator)
                .map { OverviewTile($0, $0.allowedSpans.randomElement(using: &generator)!) })
            let kind = board.tiles.randomElement(using: &generator)!.kind
            let direction = [OverviewMoveDirection.left, .right, .up, .down].randomElement(using: &generator)!
            let before = anchor(kind, in: board)!
            if board.move(kind, direction) {
                let after = anchor(kind, in: board)!
                let forward = (after.row, after.column) > (before.row, before.column)
                switch direction {
                case .left: #expect(!forward && after != before)
                case .right: #expect(forward)
                case .up: #expect(after.row < before.row)
                case .down: #expect(after.row > before.row)
                }
            }
        }
    }

    // MARK: - Quellen

    @Test func requirementsAreTheUnionOfShownTiles() {
        let board = layout([(.cpu, .wide), (.disk, .wide), (.loadAverage, .small)])
        #expect(board.requirements == OverviewTileRequirements(sources: [.cpu, .disks],
                                                               context: [.sensors, .startupVolume, .loadAverage]))
        #expect(OverviewBoardLayout(tiles: []).requirements == OverviewTileRequirements())
    }

    @Test func unavailableTilesAreDroppedForTheMac() {
        let board = layout([(.battery, .small), (.cpu, .wide)])
        #expect(board.available(configured: all.subtracting([.battery])).tiles.map(\.kind) == [.cpu])
    }
}
