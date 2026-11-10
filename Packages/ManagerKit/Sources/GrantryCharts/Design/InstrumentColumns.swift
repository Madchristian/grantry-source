import SwiftUI

/// Spalten einer selbst gezeichneten Tabelle (Kopf und Zeilen mit demselben Layout, #480): genau eine Spalte trägt den
/// Namen und nimmt den Rest, die übrigen stehen in ihrer üblichen Breite. Wird es eng, schrumpfen zuerst die übrigen
/// Spalten anteilig bis zu ihrer Mindestbreite, erst dann der Name bis zu seiner. Mit festen Breiten wurde der Name bei
/// 1358 pt in „Erweiterungen“ zu „c…er“ und bei 900 pt in TM › Dienste zu „a…“ (Bewertung 2026.11.9/1492, Mängel 4, 6).
public struct InstrumentColumns: Equatable, Sendable {
    /// Breite einer Spalte: üblich `ideal`, im Gedränge bis `minimum`. Die Namensspalte nimmt den Rest, mindestens
    /// `minimum`.
    public struct Column: Equatable, Sendable {
        public let minimum: CGFloat
        public let ideal: CGFloat
        public let isName: Bool

        public static func fixed(_ ideal: CGFloat, minimum: CGFloat) -> Column {
            Column(minimum: min(minimum, ideal), ideal: ideal, isName: false)
        }

        public static func name(minimum: CGFloat) -> Column {
            Column(minimum: minimum, ideal: minimum, isName: true)
        }
    }

    public let columns: [Column]
    public let spacing: CGFloat

    public init(_ columns: [Column], spacing: CGFloat) {
        precondition(columns.count(where: \.isName) == 1, "Genau eine Namensspalte")
        self.columns = columns
        self.spacing = spacing
    }

    /// Kleinste Breite, in der alle Spalten ihre Mindestbreite haben.
    public var minimumWidth: CGFloat { columns.map(\.minimum).reduce(0, +) + gaps }

    /// Übliche Breite: alle Spalten wie üblich, der Name in Mindestbreite.
    public var idealWidth: CGFloat { columns.map(\.ideal).reduce(0, +) + gaps }

    private var gaps: CGFloat { spacing * CGFloat(max(columns.count - 1, 0)) }

    /// Breite jeder Spalte in `available` (ohne Abstände); unter `minimumWidth` alle in Mindestbreite.
    public func widths(in available: CGFloat) -> [CGFloat] {
        let room = available - gaps
        let others = columns.filter { !$0.isName }
        let othersIdeal = others.map(\.ideal).reduce(0, +)
        let othersMinimum = others.map(\.minimum).reduce(0, +)
        let name = columns.first(where: \.isName)?.minimum ?? 0
        // Anteil, um den die übrigen Spalten von üblich auf minimal schrumpfen (0 = üblich, 1 = minimal).
        let shrink: CGFloat = if room >= othersIdeal + name { 0 } else if othersIdeal > othersMinimum {
            min(max((othersIdeal + name - room) / (othersIdeal - othersMinimum), 0), 1)
        } else { 1 }
        let fixed = columns.map { $0.isName ? 0 : $0.ideal - ($0.ideal - $0.minimum) * shrink }
        let rest = max(room - fixed.reduce(0, +), name)
        return zip(columns, fixed).map { column, width in column.isName ? rest : width }
    }
}

/// Ordnet die Unteransichten (eine je Spalte, in derselben Reihenfolge) nach `InstrumentColumns` an; Kopf und Zeilen
/// einer Tabelle stehen so bei jeder Breite bündig.
public struct InstrumentColumnsLayout: Layout {
    let columns: InstrumentColumns
    let alignment: VerticalAlignment

    /// `alignment`: `.center` für Zeilen, `.bottom` für Köpfe mit unterschiedlich hohen Spalten.
    public init(_ columns: InstrumentColumns, alignment: VerticalAlignment = .center) {
        self.columns = columns
        self.alignment = alignment
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.map { max($0, columns.minimumWidth) } ?? columns.idealWidth
        let widths = columns.widths(in: width)
        let height = zip(subviews, widths).map { subview, width in
            subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (y, anchor): (CGFloat, UnitPoint) = switch alignment {
        case .top: (bounds.minY, .topLeading)
        case .bottom: (bounds.maxY, .bottomLeading)
        default: (bounds.midY, .leading)
        }
        var x = bounds.minX
        for (subview, width) in zip(subviews, columns.widths(in: bounds.width)) {
            subview.place(at: CGPoint(x: x, y: y), anchor: anchor, proposal: ProposedViewSize(width: width, height: nil))
            x += width + columns.spacing
        }
    }
}
