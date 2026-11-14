import SwiftUI
import Testing
@testable import GrantryCharts

/// Anordnungen nach Platz ohne `ViewThatFits` (#626): Die Entscheidung ist reine Rechnung, und das Bild muss dem der
/// bisherigen Stapel mit `ViewThatFits` Pixel für Pixel gleichen – das Popover der Menüleiste ist so abgenommen.
@MainActor
@Suite struct FittingLayoutsTests {
    // MARK: - Entscheidung

    @Test func lineStaysInlineWhileWidthsAndSpacingsFit() {
        #expect(FittingLine.inlineWidth([40, 60, 20], spacing: 10) == 140)
        #expect(FittingLine.inlineWidth([], spacing: 10) == 0)
        #expect(FittingLine.arrangement(widths: [40, 60], spacing: 10, available: 110) == .inline)
        #expect(FittingLine.arrangement(widths: [40, 60], spacing: 10, available: 109.5) == .stacked)
        // Ohne Vorgabe (Wunschgröße) nebeneinander, wie die erste Variante eines `ViewThatFits`.
        #expect(FittingLine.arrangement(widths: [400, 600], spacing: 10, available: nil) == .inline)
        #expect(FittingLine.arrangement(widths: [40, 60], spacing: 10, available: 0) == .stacked)
    }

    @Test func headlineMovesLegendThenDetailBelowTheLine() {
        let widths = CardHeadline.Widths(title: 50, detail: 40, legend: 100, value: 30)
        let arrangement = { (available: CGFloat?) in
            CardHeadline.arrangement(widths, spacing: 8, valueGap: 4, available: available)
        }
        // Titel 50 + 8 + Detail 40 + 8 + Legende 100, dann 8 + 4 vor dem Wert und 8 + 30.
        #expect(CardHeadline.lineWidth(widths, leading: [widths.detail, widths.legend], spacing: 8, valueGap: 4) == 256)
        #expect(arrangement(nil) == .inline)
        #expect(arrangement(256) == .inline)
        #expect(arrangement(255) == .legendBelow)
        // Ohne Legende in der Zeile: 50 + 8 + 40 + 8 + 4 + 8 + 30 = 148.
        #expect(arrangement(148) == .legendBelow)
        #expect(arrangement(147) == .stacked)
    }

    /// Passt die Legende auch allein nicht in die Breite, rückt das Detail mit nach unten.
    @Test func headlineStacksWhenLegendIsWiderThanTheCard() {
        let widths = CardHeadline.Widths(title: 50, detail: 40, legend: 300, value: nil)
        #expect(CardHeadline.arrangement(widths, spacing: 8, valueGap: 4, available: 200) == .stacked)
        #expect(CardHeadline.arrangement(widths, spacing: 8, valueGap: 4, available: 300) == .legendBelow)
    }

    /// Ohne Legende gibt es nur „in einer Zeile“ oder „Detail darunter“; fehlende Teile kosten keinen Abstand.
    @Test func headlineWithoutLegendOrValueNeedsNoSpaceForThem() {
        let widths = CardHeadline.Widths(title: 50, detail: 40, legend: nil, value: nil)
        #expect(CardHeadline.lineWidth(widths, leading: [widths.detail, widths.legend], spacing: 8, valueGap: 4) == 110)
        #expect(CardHeadline.arrangement(widths, spacing: 8, valueGap: 4, available: 110) == .inline)
        #expect(CardHeadline.arrangement(widths, spacing: 8, valueGap: 4, available: 109) == .stacked)
        let titleOnly = CardHeadline.Widths(title: 50, detail: nil, legend: nil, value: nil)
        #expect(CardHeadline.arrangement(titleOnly, spacing: 8, valueGap: 4, available: 62) == .inline)
    }

    @Test func rowSharesWidthEquallyOrLetsTheFirstCardHug() {
        #expect(EqualHeightRow.widths(count: 2, available: 408, spacing: 8, leading: nil) == [200, 200])
        #expect(EqualHeightRow.widths(count: 3, available: 316, spacing: 8, leading: nil) == [100, 100, 100])
        #expect(EqualHeightRow.widths(count: 2, available: 408, spacing: 8, leading: 150) == [150, 250])
        // Die erste Karte nimmt nie mehr als die Zeile; eine einzelne Karte füllt sie.
        #expect(EqualHeightRow.widths(count: 2, available: 108, spacing: 8, leading: 150) == [100, 0])
        #expect(EqualHeightRow.widths(count: 1, available: 408, spacing: 8, leading: 150) == [408])
        #expect(EqualHeightRow.widths(count: 0, available: 408, spacing: 8, leading: nil).isEmpty)
    }

    // MARK: - Gleiches Bild wie zuvor

    private static let widths: [CGFloat] = [80, 120, 160, 200, 260, 320, 412]

    private func legend(_ title: String, _ value: String, isSpread: Bool = false) -> some View {
        HStack(spacing: isSpread ? 0 : InstrumentSpacing.inline) {
            LegendItem(title: title, hue: .cpu).lineLimit(1)
            if isSpread { Spacer(minLength: InstrumentSpacing.inline) }
            Text(verbatim: value).font(InstrumentFont.numeric).lineLimit(1)
        }
    }

    /// Bild der Ansicht linksbündig oben in einer Fläche fester Größe, ohne Toleranz vergleichbar.
    private func image(_ view: some View, width: CGFloat) throws -> ChartImage {
        let framed = view.frame(width: width, alignment: .leading).frame(width: width, height: 120, alignment: .topLeading)
        return try #require(ChartImage(framed, size: CGSize(width: width, height: 120)))
    }

    /// Ohne Toleranz. Weichen die Bilder ab, zählt die Wiederholung: Einmal je Testprozess zeichnet `ImageRenderer`
    /// Text zwischen zwei Aufnahmen anders (auch zweimal dieselbe Ansicht); ein echter Unterschied bleibt.
    private func expectSameImage(_ new: some View, _ old: some View, width: CGFloat, _ comment: Comment) throws {
        var difference = try image(new, width: width).difference(to: image(old, width: width), tolerance: 0)
        if difference != 0 {
            difference = try image(new, width: width).difference(to: image(old, width: width), tolerance: 0)
        }
        #expect(difference == 0, "\(comment), Breite \(width)")
    }

    @Test func fittingLineDrawsLikeViewThatFitsWithStacks() throws {
        for width in Self.widths {
            let new = FittingLine(spacing: InstrumentSpacing.cell, stackedSpacing: InstrumentSpacing.inline) {
                legend("Leistungskerne (P)", "37 %")
                legend("Effizienzkerne (E)", "12 %")
            }
            let old = ViewThatFits(in: .horizontal) {
                HStack(spacing: InstrumentSpacing.cell) {
                    legend("Leistungskerne (P)", "37 %")
                    legend("Effizienzkerne (E)", "12 %")
                }
                VStack(alignment: .leading, spacing: InstrumentSpacing.inline) {
                    legend("Leistungskerne (P)", "37 %")
                    legend("Effizienzkerne (E)", "12 %")
                }
            }
            try expectSameImage(new, old, width: width, "Legenden")
        }
    }

    /// Tabellenzeilen: nebeneinander schmal, untereinander über die ganze Breite mit dem Wert am rechten Rand.
    @Test func fittingLineSpreadsRowsWhenStacked() throws {
        for width in Self.widths {
            let new = FittingLine(spacing: InstrumentSpacing.bar, stackedSpacing: InstrumentSpacing.inline) {
                legend("↓ Empfangen", "1,2 MB/s", isSpread: true)
                legend("↑ Gesendet", "310 KB/s", isSpread: true)
            }
            let old = ViewThatFits(in: .horizontal) {
                HStack(spacing: InstrumentSpacing.bar) {
                    legend("↓ Empfangen", "1,2 MB/s")
                    legend("↑ Gesendet", "310 KB/s")
                }
                VStack(spacing: InstrumentSpacing.inline) {
                    legend("↓ Empfangen", "1,2 MB/s", isSpread: true)
                    legend("↑ Gesendet", "310 KB/s", isSpread: true)
                }
            }
            try expectSameImage(new, old, width: width, "Tabellenzeilen")
        }
    }

    @Test func justifiedFittingLineDrawsLikeStackWithSpacer() throws {
        let chip = StatusChip("Druck normal", tone: .positive, isSmall: true)
        let usage = Text(verbatim: "17,75 GB von 48 GB").font(InstrumentFont.label.monospacedDigit()).lineLimit(1)
        for width in Self.widths {
            let new = FittingLine(spacing: 2 * InstrumentSpacing.group, stackedSpacing: InstrumentSpacing.inline,
                                  isJustified: true) {
                chip
                usage
            }
            let old = ViewThatFits(in: .horizontal) {
                HStack(spacing: InstrumentSpacing.group) {
                    chip
                    Spacer(minLength: 0)
                    usage
                }
                VStack(alignment: .leading, spacing: InstrumentSpacing.inline) {
                    chip
                    usage
                }
            }
            try expectSameImage(new, old, width: width, "Druck und Belegung")
        }
    }

    /// Kopf einer Karte wie bisher aus drei Varianten in einem `ViewThatFits`.
    private struct OldHeadline<Legend: View>: View {
        let title: String
        let detail: String
        let value: String
        let legend: Legend

        var body: some View {
            ViewThatFits(in: .horizontal) {
                line(showsDetail: true) { legend }
                VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
                    line(showsDetail: true) { EmptyView() }
                    legend
                }
                VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
                    VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                        line(showsDetail: false) { EmptyView() }
                        if !detail.isEmpty { detailText.truncationMode(.middle) }
                    }
                    legend
                }
            }
        }

        private func line(showsDetail: Bool, @ViewBuilder legend: () -> some View) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: InstrumentSpacing.group) {
                Text(verbatim: title).font(InstrumentFont.body.weight(.semibold)).lineLimit(1)
                if showsDetail, !detail.isEmpty { detailText }
                legend()
                Spacer(minLength: InstrumentSpacing.inline)
                if !value.isEmpty { Text(verbatim: value).font(InstrumentFont.tileValue).lineLimit(1) }
            }
        }

        private var detailText: some View {
            Text(verbatim: detail).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary).lineLimit(1)
        }
    }

    private struct NewHeadline<Legend: View>: View {
        let title: String
        let detail: String
        let value: String
        let legend: Legend

        var body: some View {
            CardHeadline {
                Text(verbatim: title).font(InstrumentFont.body.weight(.semibold)).lineLimit(1).cardHeadline(.title)
                if !detail.isEmpty {
                    Text(verbatim: detail).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                        .lineLimit(1).truncationMode(.middle).cardHeadline(.detail)
                }
                legend.cardHeadline(.legend)
                if !value.isEmpty {
                    Text(verbatim: value).font(InstrumentFont.tileValue).lineLimit(1).cardHeadline(.value)
                }
            }
        }
    }

    @Test func cardHeadlineDrawsLikeViewThatFitsWithStacks() throws {
        let texts: [(title: String, detail: String, value: String)] = [
            ("CPU", "3,2 GHz", "37 %"), ("Netz", "USB 10/100/1G/2.5G LAN", ""), ("Arbeitsspeicher", "", "64 %"),
            ("Prozesse", "höchste CPU-Last", ""), ("Kerne", "", ""),
        ]
        for width in Self.widths {
            for text in texts {
                let legends = HStack(spacing: InstrumentSpacing.cell) {
                    legend("Benutzer", "25 %")
                    legend("System", "12 %")
                }
                try expectSameImage(
                    NewHeadline(title: text.title, detail: text.detail, value: text.value, legend: legends),
                    OldHeadline(title: text.title, detail: text.detail, value: text.value, legend: legends),
                    width: width, "\(text.title) mit Legende"
                )
                try expectSameImage(
                    NewHeadline(title: text.title, detail: text.detail, value: text.value, legend: EmptyView()),
                    OldHeadline(title: text.title, detail: text.detail, value: text.value, legend: EmptyView()),
                    width: width, "\(text.title) ohne Legende"
                )
            }
        }
    }

    /// Legende, die selbst umbricht (Kernklassen): im Kopf wie zuvor ein `ViewThatFits` im `ViewThatFits`.
    @Test func cardHeadlineWithFittingLegendDrawsLikeNestedViewThatFits() throws {
        for width in Self.widths {
            let new = NewHeadline(title: "Kerne", detail: "", value: "", legend: FittingLine(
                spacing: InstrumentSpacing.cell, stackedSpacing: InstrumentSpacing.inline
            ) {
                legend("Super-Kerne (S)", "41 %")
                legend("Leistungskerne (P)", "37 %")
                legend("Effizienzkerne (E)", "12 %")
            })
            let old = OldHeadline(title: "Kerne", detail: "", value: "", legend: ViewThatFits(in: .horizontal) {
                HStack(spacing: InstrumentSpacing.cell) {
                    legend("Super-Kerne (S)", "41 %")
                    legend("Leistungskerne (P)", "37 %")
                    legend("Effizienzkerne (E)", "12 %")
                }
                VStack(alignment: .leading, spacing: InstrumentSpacing.inline) {
                    legend("Super-Kerne (S)", "41 %")
                    legend("Leistungskerne (P)", "37 %")
                    legend("Effizienzkerne (E)", "12 %")
                }
            })
            try expectSameImage(new, old, width: width, "Kernklassen")
        }
    }

    private func card(_ lines: Int, hue: InstrumentHue) -> some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
            ForEach(0..<lines, id: \.self) { line in
                Text(verbatim: "Zeile \(line) der Karte").font(InstrumentFont.label).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .instrumentPanel(padding: InstrumentSpacing.cell, radius: InstrumentRadius.card)
    }

    /// Kartenpaare: gleich hoch, hälftig geteilt oder die erste Karte nur so breit wie ihr Inhalt.
    @Test func equalHeightRowDrawsLikeStackWithFixedHeight() throws {
        for (width, hugs) in [(412.0, false), (412.0, true), (320.0, false), (320.0, true)] {
            let new = EqualHeightRow(spacing: InstrumentSpacing.group, hugsLeading: hugs) {
                card(2, hue: .gpu)
                card(4, hue: .memory)
            }
            let old = HStack(alignment: .top, spacing: InstrumentSpacing.group) {
                card(2, hue: .gpu).fixedSize(horizontal: hugs, vertical: false)
                card(4, hue: .memory)
            }
            .fixedSize(horizontal: false, vertical: true)
            try expectSameImage(new, old, width: width, "Kartenpaar, erste Karte schmal: \(hugs)")
        }
    }
}
