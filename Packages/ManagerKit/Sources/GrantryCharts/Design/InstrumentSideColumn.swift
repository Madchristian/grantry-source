import SwiftUI

/// Hauptinhalt und eine Seitenspalte fester Breite (Akku-Karten in Energie, „Zu diesem Zeitpunkt“ im Wachbuch, Leistung
/// im Chip-Tab, #486): nebeneinander, solange der Hauptinhalt dabei mindestens `mainMinimum` breit bleibt, sonst
/// untereinander in der Reihenfolge der Unteransichten. Vorher drückte die feste Spalte den Hauptinhalt bei 900 pt mit
/// Seitenleiste zusammen – Namen standen senkrecht („A p p s“), oder der Inhalt lief rechts aus dem Fenster
/// (Nachbewertung 2026.11.9/1510, Sollte 2).
///
/// Entschieden wird nur aus der vorgeschlagenen Breite, nicht aus dem Inhalt: Ein Messtakt misst nichts zusätzlich, und
/// beim Wechsel der Anordnung bleibt die Identität der Unteransichten (Bildlauf, Auswahl) erhalten.
public struct InstrumentSideColumnLayout: Layout {
    /// Seite der Spalte im Nebeneinander; `.leading` heißt, die erste Unteransicht ist die Seitenspalte.
    let side: HorizontalEdge
    let sideWidth: CGFloat
    let mainMinimum: CGFloat
    let spacing: CGFloat

    public init(side: HorizontalEdge, width sideWidth: CGFloat, mainMinimum: CGFloat,
                spacing: CGFloat = InstrumentSpacing.panel) {
        self.side = side
        self.sideWidth = sideWidth
        self.mainMinimum = mainMinimum
        self.spacing = spacing
    }

    /// Kleinste Breite, in der Seitenspalte und Hauptinhalt nebeneinander stehen.
    public var sideBySideWidth: CGFloat { sideWidth + spacing + mainMinimum }

    public func isSideBySide(in width: CGFloat) -> Bool { width >= sideBySideWidth }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let (main, column) = parts(of: subviews) else { return subviews.first?.sizeThatFits(proposal) ?? .zero }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? sideBySideWidth
        if isSideBySide(in: width) {
            let mainSize = main.sizeThatFits(ProposedViewSize(width: width - sideWidth - spacing, height: proposal.height))
            let columnSize = column.sizeThatFits(ProposedViewSize(width: sideWidth, height: proposal.height))
            return CGSize(width: max(width, sideWidth + spacing + mainSize.width),
                          height: max(mainSize.height, columnSize.height))
        }
        let mainSize = main.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        let columnSize = column.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: max(width, mainSize.width, columnSize.width),
                      height: mainSize.height + spacing + columnSize.height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let (main, column) = parts(of: subviews) else {
            subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
            return
        }
        if isSideBySide(in: bounds.width) {
            let mainWidth = bounds.width - sideWidth - spacing
            let (columnX, mainX) = side == .leading ? (bounds.minX, bounds.minX + sideWidth + spacing)
                : (bounds.maxX - sideWidth, bounds.minX)
            column.place(at: CGPoint(x: columnX, y: bounds.minY), anchor: .topLeading,
                         proposal: ProposedViewSize(width: sideWidth, height: bounds.height))
            main.place(at: CGPoint(x: mainX, y: bounds.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(width: mainWidth, height: bounds.height))
            return
        }
        // Untereinander: Der Hauptinhalt bekommt die vorgeschlagene Höhe (Tabellen und Graphen füllen sie), die Spalte
        // ihre natürliche; was nicht passt, rollt im Detailbereich (`FittingScrollView`).
        let mainProposal = ProposedViewSize(width: bounds.width, height: proposal.height)
        let columnProposal = ProposedViewSize(width: bounds.width, height: nil)
        let (upper, lower) = side == .leading ? ((column, columnProposal), (main, mainProposal))
            : ((main, mainProposal), (column, columnProposal))
        upper.0.place(at: bounds.origin, anchor: .topLeading, proposal: upper.1)
        let y = bounds.minY + upper.0.sizeThatFits(upper.1).height + spacing
        lower.0.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: lower.1)
    }

    /// Hauptinhalt und Seitenspalte; ohne Spalte (etwa ein leeres Detail) füllt der Hauptinhalt allein den Platz.
    private func parts(of subviews: Subviews) -> (main: LayoutSubview, column: LayoutSubview)? {
        guard subviews.count == 2 else { return nil }
        return side == .leading ? (subviews[1], subviews[0]) : (subviews[0], subviews[1])
    }
}

extension InstrumentSideColumnLayout {
    /// Bereich „Sicherheit“: links der Steckbrief, rechts das Panel „Schutz“. Bei 900 pt mit Seitenleiste blieben dem
    /// Panel 260 pt, die Prüfungen kürzten sich zu „Automati…“ und „Hinw…“ (Nachbewertung 2026.11.9/1510, Später 10).
    public static let profileAndChecks = InstrumentSideColumnLayout(side: .leading, width: InstrumentSize.columnWide,
                                                                    mainMinimum: 400)
}

/// Bedienzeile über einem Graphen oder einer Tabelle (#486): Umschalter links, rechts Legende oder Hinweise. Reicht die
/// Breite nicht für eine Zeile, brechen die Teile in natürlicher Breite um, statt sich zu stauchen („Gemessen“ stand im
/// App-Verlauf senkrecht, „Schrei-ben“ im Wachbuch) oder den Inhalt zu verbreitern.
public struct InstrumentControlRow<Leading: View, Trailing: View>: View {
    let leading: Leading
    let trailing: Trailing

    public init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: InstrumentSpacing.panel) {
                leading
                Spacer(minLength: InstrumentSpacing.group)
                trailing
            }
            LegendFlow(spacing: InstrumentSpacing.panel, lineSpacing: InstrumentSpacing.group) {
                leading
                trailing
            }
        }
    }
}
