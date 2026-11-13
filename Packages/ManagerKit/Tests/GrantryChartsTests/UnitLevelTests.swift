import SwiftUI
import Testing
@testable import GrantryCharts

/// GPU-Zellen im Chip-Grundriss als Pegel der Gesamtauslastung (#614): Es gibt keine Messung je GPU-Kern, deshalb füllt
/// die Auslastung die Zellen der Reihe nach, die Grenzzelle anteilig.
@MainActor
@Suite struct UnitLevelTests {
    @Test func withoutMeasurementNoCellIsFilled() {
        #expect(UnitCells.fills(count: 4, load: nil) == [0, 0, 0, 0])
        #expect(UnitCells.fills(count: 4, load: 0) == [0, 0, 0, 0])
        #expect(UnitCells.fills(count: 4, load: .nan) == [0, 0, 0, 0])
    }

    /// 40 % von 40 Kernen: 16 Zellen gefüllt, die übrigen in der Grundtönung.
    @Test func loadFillsCellsInOrder() {
        let fills = UnitCells.fills(count: 40, load: 0.4)
        #expect(fills.prefix(16).allSatisfy { $0 == 1 })
        #expect(fills.dropFirst(16).allSatisfy { $0 == 0 })
    }

    /// 27 % von 40 Kernen: 10,8 Zellen – die elfte zu vier Fünfteln.
    @Test func boundaryCellIsPartlyFilled() {
        let fills = UnitCells.fills(count: 40, load: 0.27)
        #expect(fills.prefix(10).allSatisfy { $0 == 1 })
        #expect(abs(fills[10] - 0.8) < 1e-9)
        #expect(fills.dropFirst(11).allSatisfy { $0 == 0 })
    }

    @Test func fullLoadFillsEveryCellAndOverloadIsClamped() {
        #expect(UnitCells.fills(count: 10, load: 1) == Array(repeating: 1, count: 10))
        #expect(UnitCells.fills(count: 10, load: 1.7) == Array(repeating: 1, count: 10))
        #expect(UnitCells.fills(count: 0, load: 0.5).isEmpty)
    }

    /// Ruhig: Schwankungen unter einem Prozentpunkt ändern den Pegel nicht (keine neue Zeichnung je Rauschen).
    @Test func subPercentNoiseKeepsTheLevel() {
        #expect(UnitCells.fills(count: 40, load: 0.4) == UnitCells.fills(count: 40, load: 0.4031))
        #expect(UnitCells.fills(count: 40, load: 0.4) == UnitCells.fills(count: 40, load: 0.3972))
    }

    /// Abnahme #614: Bei 0, 40 und 100 % Last unterscheiden sich die Pegel im Bild deutlich.
    @Test(arguments: ChartAppearance.allCases)
    func levelsDifferInTheImage(_ appearance: ChartAppearance) throws {
        let size = CGSize(width: 420, height: 90)
        func image(_ load: Double) throws -> ChartImage {
            try #require(ChartImage(UnitCells(count: 40, load: load, hue: .gpu).padding(8).instrumentBackground(),
                                    size: size, appearance: appearance))
        }
        let (empty, forty, full) = (try image(0), try image(0.4), try image(1))
        #expect(empty.difference(to: forty) > 0.05)
        #expect(forty.difference(to: full) > 0.05)
        #expect(empty.difference(to: full) > forty.difference(to: full))
    }

    /// VoiceOver liest den Hinweis als Beschriftung und die Auslastung in Prozent als Wert, nicht die Zahl der Zellen.
    @Test func voiceOverReadsTotalLoadInPercent() async throws {
        let nodes = try await AccessibilityTree.nodes(of: UnitCells(count: 40, load: 0.4, hue: .gpu))
        #expect(nodes == [AccessibilityTree.Node(role: "AXStaticText", label: "Gesamtauslastung, nicht je Kern",
                                                 value: 0.4.formatted(.percent.precision(.fractionLength(0))))])
    }

    @Test func voiceOverReadsMissingMeasurement() async throws {
        let nodes = try await AccessibilityTree.nodes(of: UnitCells(count: 40, load: nil, hue: .gpu))
        #expect(nodes == [AccessibilityTree.Node(role: "AXStaticText", label: "Gesamtauslastung, nicht je Kern",
                                                 value: "keine Messung")])
    }
}
