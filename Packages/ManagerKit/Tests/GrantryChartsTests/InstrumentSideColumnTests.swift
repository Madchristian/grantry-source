import AppKit
import SwiftUI
import Testing
@testable import GrantryCharts

/// Seitenspalte neben oder unter dem Hauptinhalt (#486): Bei 900 pt mit Seitenleiste drückte die feste Spalte Tabellen
/// zusammen, bis Namen senkrecht standen (Nachbewertung 2026.11.9/1510, Sollte 2).
@MainActor
@Suite struct InstrumentSideColumnTests {
    private static let layout = InstrumentSideColumnLayout(side: .leading, width: 360, mainMinimum: 300, spacing: 12)

    @Test func sideBySideOnlyWhenTheMainContentKeepsItsMinimum() {
        #expect(Self.layout.sideBySideWidth == 672)
        #expect(Self.layout.isSideBySide(in: 672))
        #expect(!Self.layout.isSideBySide(in: 671))
    }

    @Test func wideProposalPlacesBothNextToEachOther() {
        let size = fittingSize(width: 900)
        #expect(size.height == 100)
    }

    @Test func narrowProposalStacksInsteadOfSqueezing() {
        // Untereinander: Spalte (100) über dem Hauptinhalt (50) mit Abstand.
        let size = fittingSize(width: 632)
        #expect(size.height == 162)
        #expect(size.width == 632)
    }

    @Test func withoutColumnTheMainContentFillsTheSpace() {
        // Ein leeres Detail (`EmptyView`) ist keine Unteransicht; vorher blieb der Hauptinhalt dann ungesetzt.
        let host = NSHostingView(rootView: Self.layout {
            Color.clear.frame(height: 50)
            EmptyView()
        }.frame(width: 900).fixedSize(horizontal: false, vertical: true))
        #expect(host.fittingSize == CGSize(width: 900, height: 50))
    }

    private func fittingSize(width: CGFloat) -> CGSize {
        let host = NSHostingView(rootView: Self.layout {
            Color.clear.frame(height: 100)
            Color.clear.frame(height: 50)
        }.frame(width: width).fixedSize(horizontal: false, vertical: true))
        return host.fittingSize
    }
}
