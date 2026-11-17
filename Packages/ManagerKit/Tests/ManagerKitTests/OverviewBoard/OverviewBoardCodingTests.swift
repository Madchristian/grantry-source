import Foundation
import Testing
@testable import ManagerKit

/// Speicherung der Anordnung (Spec § 6): JSON mit Version, robust gegen unbekannte Kacheln und verbotene Größen,
/// Übernahme der ausgeblendeten Karten aus #495.
@Suite struct OverviewBoardCodingTests {
    private let all = Set(TaskManagerSource.allCases)

    private func decode(_ json: String) throws -> OverviewBoardLayout {
        try JSONDecoder().decode(OverviewBoardLayout.self, from: Data(json.utf8))
    }

    @Test func encodesVersionAndTilesWithStableCodes() throws {
        let layout = OverviewBoardLayout(tiles: [OverviewTile(.cpu, .banner), OverviewTile(.uptime, .small)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(layout), as: UTF8.self)
        #expect(json == #"{"tiles":[{"kind":"cpu","span":"4x1"},{"kind":"uptime","span":"1x1"}],"version":1}"#)
        #expect(try JSONDecoder().decode(OverviewBoardLayout.self, from: Data(json.utf8)) == layout)
    }

    @Test func standardLayoutRoundTrips() throws {
        let standard = OverviewBoardLayout.standard(configured: all)
        let data = try JSONEncoder().encode(standard)
        #expect(try JSONDecoder().decode(OverviewBoardLayout.self, from: data) == standard)
    }

    /// Eine Kachel aus einer späteren Version (oder eine entfernte) fällt weg, der Rest bleibt.
    @Test func unknownKindsAndBrokenEntriesAreSkipped() throws {
        let layout = try decode(#"""
        {"version":1,"tiles":[{"kind":"fans","span":"2x1"},{"kind":"cpu","span":"2x1"},{"kind":"gpu"},
        {"kind":"memory","span":"9x9"},{"kind":"cpu","span":"4x1"}]}
        """#)
        #expect(layout.tiles == [OverviewTile(.cpu, .wide), OverviewTile(.memory, OverviewTileKind.memory.defaultSpan)])
    }

    @Test func forbiddenSpanFallsBackToDefault() throws {
        let layout = try decode(#"{"version":1,"tiles":[{"kind":"thermal","span":"4x2"}]}"#)
        #expect(layout.tiles == [OverviewTile(.thermal, OverviewTileKind.thermal.defaultSpan)])
    }

    /// Eine neuere Version kann diese nicht sicher lesen; der Aufrufer behält dann seine Anordnung bzw. den Standard.
    @Test func newerOrMissingVersionIsRejected() {
        #expect(throws: DecodingError.self) { try decode(#"{"version":2,"tiles":[]}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"tiles":[]}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"version":0,"tiles":[]}"#) }
    }

    @Test func emptyBoardStaysEmpty() throws {
        #expect(try decode(#"{"version":1,"tiles":[]}"#).tiles.isEmpty)
    }

    /// Migration aus #495: Wer Karten ausgeblendet hat, bekommt den Standard ohne diese Kacheln; „Last und Laufzeit“
    /// waren eine Karte und sind jetzt zwei Kacheln.
    @Test func hiddenCardsOfTheOverviewAreTakenOver() {
        let migrated = OverviewBoardLayout(migratingHiddenCards: [.processes, .summary], configured: all)
        let removed: Set<OverviewTileKind> = [.processes, .loadAverage, .uptime]
        let expected = OverviewTileKind.allCases.filter { !removed.contains($0) }
        #expect(migrated.tiles.map(\.kind) == expected)
        #expect(OverviewBoardLayout(migratingHiddenCards: [], configured: all) == .standard(configured: all))
    }

    @Test func everyCardOfTheOverviewHasTiles() {
        let covered = Set(MenuBarOverviewCard.allCases.flatMap(\.tileKinds))
        #expect(covered == Set(OverviewTileKind.allCases))
    }
}
