import Testing
@testable import ManagerKit

/// Rasterbelegung des Baukastens (Spec § 3): vier Spalten, Kacheln in Listenreihenfolge, jede an der ersten freien
/// Stelle, an der sie ganz passt. Dicht gepackt füllen spätere kleine Kacheln Lücken, geordnet nie.
@Suite struct OverviewGridTests {
    private let grid = OverviewGrid()

    private func anchors(_ placements: [OverviewTilePlacement]) -> [OverviewTileKind: OverviewGridCell] {
        Dictionary(uniqueKeysWithValues: placements.map { ($0.kind, $0.anchor) })
    }

    @Test func tilesFlowLeftToRightTopToBottom() {
        let placements = grid.place([OverviewTile(.cpu, .wide), OverviewTile(.gpu, .wide), OverviewTile(.memory, .small)])
        #expect(anchors(placements) == [.cpu: .init(column: 0, row: 0), .gpu: .init(column: 2, row: 0),
                                        .memory: .init(column: 0, row: 1)])
        #expect(grid.rowCount(of: placements) == 2)
    }

    @Test func tallTileLeavesRoomBesideIt() {
        let placements = grid.place([OverviewTile(.processes, .large), OverviewTile(.gpu, .wide),
                                     OverviewTile(.memory, .wide), OverviewTile(.cpu, .banner)])
        #expect(anchors(placements) == [.processes: .init(column: 0, row: 0), .gpu: .init(column: 2, row: 0),
                                        .memory: .init(column: 2, row: 1), .cpu: .init(column: 0, row: 2)])
    }

    /// Dicht (Standard): Die kleine Kachel nach der breiten rückt in die Lücke davor.
    @Test func densePackingFillsEarlierGaps() {
        let tiles = [OverviewTile(.thermal, .small), OverviewTile(.cpu, .banner), OverviewTile(.uptime, .small)]
        #expect(anchors(grid.place(tiles)) == [.thermal: .init(column: 0, row: 0), .cpu: .init(column: 0, row: 1),
                                               .uptime: .init(column: 1, row: 0)])
        let ordered = OverviewGrid(packing: .ordered)
        #expect(anchors(ordered.place(tiles)) == [.thermal: .init(column: 0, row: 0), .cpu: .init(column: 0, row: 1),
                                                  .uptime: .init(column: 0, row: 2)])
    }

    @Test func placementsNeverOverlapOrLeaveTheGrid() {
        var generator = BoardRandom(seed: 7)
        for _ in 0..<300 {
            let tiles = OverviewTileKind.allCases.shuffled(using: &generator).prefix(Int.random(in: 1...11,
                                                                                               using: &generator))
                .map { OverviewTile($0, $0.allowedSpans.randomElement(using: &generator)!) }
            for packing in [OverviewGrid.Packing.dense, .ordered] {
                let placements = OverviewGrid(packing: packing).place(Array(tiles))
                #expect(placements.map(\.kind) == tiles.map(\.kind))
                var occupied = Set<OverviewGridCell>()
                for placement in placements {
                    #expect(placement.anchor.column + placement.span.columns <= OverviewGrid.columns)
                    for cell in placement.cells {
                        #expect(occupied.insert(cell).inserted, "Überlappung bei \(cell)")
                    }
                }
            }
        }
    }

    @Test func readingOrderSortsByRowThenColumn() {
        let placements = grid.place([OverviewTile(.thermal, .small), OverviewTile(.cpu, .banner),
                                     OverviewTile(.uptime, .small)])
        #expect(OverviewGrid.readingOrder(placements).map(\.kind) == [.thermal, .uptime, .cpu])
    }

    @Test func emptyBoardHasNoRows() {
        #expect(grid.place([]).isEmpty)
        #expect(grid.rowCount(of: []) == 0)
    }

    @Test func placementKnowsItsCells() {
        let placement = OverviewTilePlacement(tile: OverviewTile(.processes, .large),
                                              anchor: OverviewGridCell(column: 2, row: 1))
        #expect(placement.cells == [.init(column: 2, row: 1), .init(column: 3, row: 1), .init(column: 2, row: 2),
                                    .init(column: 3, row: 2)])
        #expect(placement.contains(.init(column: 3, row: 2)))
        #expect(!placement.contains(.init(column: 1, row: 1)))
    }
}

/// Reproduzierbarer Zufall für Eigenschaftstests (SplitMix64).
struct BoardRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
