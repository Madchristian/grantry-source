import SwiftUI
import Testing
@testable import GrantryCharts

/// Spalten selbst gezeichneter Tabellen (#480): Der Name bleibt lesbar, solange die Tabelle ihre Mindestbreite hat –
/// vorher fraßen feste Nebenspalten ihn auf („c…er“ in Erweiterungen bei 1358 pt, „a…“ in TM › Dienste bei 900 pt).
@Suite struct InstrumentColumnsTests {
    private static let columns = InstrumentColumns([
        .fixed(116, minimum: 84), .name(minimum: 160), .fixed(84, minimum: 60), .fixed(120, minimum: 96),
    ], spacing: 4)

    @Test func nameTakesTheRestWhenThereIsRoom() {
        let widths = Self.columns.widths(in: 800)
        #expect(widths == [116, 800 - 12 - 116 - 84 - 120, 84, 120])
    }

    @Test func otherColumnsShrinkBeforeTheName() {
        // Üblich bräuchte es 116 + 160 + 84 + 120 + 12 = 492 pt.
        let widths = Self.columns.widths(in: 440)
        #expect(widths[1] == 160)
        #expect(widths[0] < 116 && widths[0] > 84)
        #expect(abs(widths.reduce(0, +) + 12 - 440) < 0.001)
    }

    @Test func belowTheMinimumEveryColumnKeepsItsMinimum() {
        let widths = Self.columns.widths(in: 300)
        #expect(widths == [84, 160, 60, 96])
        let minimum: CGFloat = 84 + 160 + 60 + 96 + 12
        let ideal: CGFloat = 116 + 160 + 84 + 120 + 12
        #expect(Self.columns.minimumWidth == minimum)
        #expect(Self.columns.idealWidth == ideal)
    }

    @Test func widthsNeverShrinkWithMoreRoom() {
        var previous = Self.columns.widths(in: Self.columns.minimumWidth)
        for available in stride(from: Self.columns.minimumWidth, through: 900, by: 7) {
            let widths = Self.columns.widths(in: available)
            #expect(zip(widths, previous).allSatisfy { $0 >= $1 - 0.001 })
            previous = widths
        }
    }
}
