import SwiftUI
import Testing
@testable import GrantryCharts

/// Belegungsband (Spec 2026-11-08 § 5.4): Teile nebeneinander in Deckkraftstufen, frei als Bahn.
@Suite struct ShareBandTests {
    private static func part(_ id: String, _ fraction: Double, level: Int = 0) -> ShareBand.Part {
        ShareBand.Part(id: id, title: id, value: "", fraction: fraction, level: level)
    }

    /// Auf Hundertstel gerundet, damit Gleitkomma-Reste nicht zählen.
    private static func rounded(_ values: [CGFloat]) -> [CGFloat] { values.map { ($0 * 100).rounded() / 100 } }

    @Test func segmentsFollowTheirShares() {
        let segments = ShareBand.segments([Self.part("a", 0.5), Self.part("b", 0.25, level: 1)], width: 200, minimum: 3)
        #expect(Self.rounded(segments.map(\.x)) == [0, 100])
        #expect(Self.rounded(segments.map(\.width)) == [100, 50])
        #expect(segments.map(\.level) == [0, 1])
    }

    /// Kleine Teile bleiben sichtbar; die Breite dafür gibt der größte Teil ab, die Summe bleibt gleich.
    @Test func tinyPartsKeepAMinimumWidth() {
        let segments = ShareBand.segments([Self.part("a", 0.6), Self.part("b", 0.001), Self.part("c", 0.1)], width: 100,
                                          minimum: 3)
        #expect(Self.rounded(segments.map(\.width)) == [57.1, 3, 10])
        #expect(Self.rounded(segments.map(\.x)) == [0, 57.1, 60.1])
    }

    /// Mehr als das Ganze (etwa überlappende Messungen) wird am Ende abgeschnitten; leere und ungültige Teile fehlen.
    @Test func overflowIsClippedAndEmptyPartsAreDropped() {
        let segments = ShareBand.segments([Self.part("a", 0.7), Self.part("leer", 0), Self.part("nan", .nan),
                                           Self.part("b", 0.5)], width: 100, minimum: 3)
        #expect(segments.map(\.id) == ["a", "b"])
        #expect(Self.rounded(segments.map(\.width)) == [70, 30])
    }

    @Test func levelsStayWithinTheTokens() {
        let segments = ShareBand.segments([Self.part("a", 0.1, level: -1), Self.part("b", 0.1, level: 99)], width: 100,
                                          minimum: 3)
        #expect(segments.map(\.level) == [0, InstrumentOpacity.bandLevels.count - 1])
    }

    /// VoiceOver liest das Band als Liste: jeder Teil mit Wert, frei zuletzt.
    @Test func accessibilityValueListsEveryPart() {
        let parts = [ShareBand.Part(id: "s", title: "System", value: "40 GB", fraction: 0.4, level: 0),
                     ShareBand.Part(id: "b", title: "Benutzer", value: "10 GB", fraction: 0.1, level: 2)]
        #expect(ShareBand.accessibilityValue(parts: parts, free: "50 GB frei") == "System 40 GB, Benutzer 10 GB, 50 GB frei")
    }
}
