import SwiftUI

/// Kachelraster des Übersichts-Baukastens (Spec 2026-11-09-uebersicht-baukasten § 3): setzt jede Unteransicht in den
/// Rahmen aus `boardGridFrame(_:)` und schlägt jeder genau die Größe ihrer Zellen vor. Die Höhe folgt aus der untersten
/// Kachel; ohne Rahmen liegt eine Ansicht links oben in einer Zelle. Rechnet nur bei geänderten Rahmen oder Breite neu,
/// nicht je Messtakt.
public struct BoardGrid: Layout {
    public let metrics: BoardGridMetrics

    public init(metrics: BoardGridMetrics) {
        self.metrics = metrics
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = subviews.map { $0[BoardGridFrameKey.self].map { $0.row + $0.rows } ?? 1 }.max() ?? 0
        return CGSize(width: metrics.width, height: metrics.height(rows: rows))
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let frame = metrics.frame(of: subview[BoardGridFrameKey.self]
                ?? BoardGridFrame(column: 0, row: 0, columns: 1, rows: 1))
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(frame.size))
        }
    }
}

private struct BoardGridFrameKey: LayoutValueKey {
    static let defaultValue: BoardGridFrame? = nil
}

extension View {
    /// Lage einer Kachel im `BoardGrid`; der Inhalt füllt die Zellen ganz aus.
    public func boardGridFrame(_ frame: BoardGridFrame) -> some View {
        self.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .layoutValue(key: BoardGridFrameKey.self, value: frame)
    }
}
