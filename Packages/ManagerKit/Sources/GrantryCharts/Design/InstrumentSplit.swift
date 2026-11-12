import SwiftUI

/// Liste-Detail-Gerüst im Lagebild (LB-1.2, #536; ersetzt `ListDetailSplit`): Auswahlliste links, Detail rechts, dazwischen
/// `space.panelGap`. Mit Platz steht die Liste in `column.wide` und das Detail füllt den Rest; wird es eng, gibt zuerst die
/// Liste bis `size.listMin` nach, dann das Detail. Nie breiter als der angebotene Platz (#507). Ohne `GeometryReader`.
public struct InstrumentSplit<ListContent: View, DetailContent: View>: View {
    let list: ListContent
    let detail: DetailContent

    public init(@ViewBuilder list: () -> ListContent, @ViewBuilder detail: () -> DetailContent) {
        self.list = list()
        self.detail = detail()
    }

    public var body: some View {
        InstrumentSplitLayout {
            list
            detail
        }
    }
}

/// Aufteilung von `InstrumentSplit`: genau zwei Teile, Liste und Detail, in voller Höhe.
struct InstrumentSplitLayout: Layout {
    static let gap = InstrumentSpacing.panel

    /// Breite der Liste bei `available` Punkten.
    nonisolated static func listWidth(available: CGFloat) -> CGFloat {
        min(InstrumentSize.columnWide, max(InstrumentSize.listMin, available - gap - InstrumentSize.detailMin))
    }

    /// Breite des Details: der Rest, nie unter 0.
    nonisolated static func detailWidth(available: CGFloat) -> CGFloat {
        max(0, available - gap - listWidth(available: available))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? InstrumentSize.columnWide + Self.gap + InstrumentSize.detailMin
        let height = proposal.height ?? subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let list = Self.listWidth(available: bounds.width)
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: list, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + list + Self.gap, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: Self.detailWidth(available: bounds.width),
                                                     height: bounds.height))
    }
}
