import SwiftUI

/// Tab-Leiste im Inhalt (§3.9, #463): die Segmente eines Bereichs links, rechts daneben `accessory` (etwa Takt und
/// Sprungknöpfe). Alle Segmente bleiben bei jeder Breite sichtbar – in einer Zeile wie `InstrumentSegments`, sonst mit
/// engerem Innenabstand, zuletzt umbrochen in ausgeglichene Zeilen. Nie ein Überlaufmenü: In der Symbolleiste
/// verschwand die Auswahl mit zehn Tabs komplett hinter dem Chevron. Die Leiste hängt nur an Auswahl und Breite,
/// nicht am Messtakt.
public struct InstrumentTabs<Value: Hashable, Accessory: View>: View {
    let label: String
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    let accessory: Accessory

    public init(_ label: String, selection: Binding<Value>, options: [(value: Value, label: String)],
                @ViewBuilder accessory: () -> Accessory) {
        self.label = label
        _selection = selection
        self.options = options
        self.accessory = accessory()
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            line(.regular)
            line(.compact)
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                segments(.compact, wraps: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                accessory.fixedSize()
            }
        }
    }

    private func line(_ density: SegmentDensity) -> some View {
        HStack(spacing: InstrumentSpacing.panel) {
            segments(density, wraps: false)
            Spacer(minLength: 0)
            accessory.fixedSize()
        }
    }

    private func segments(_ density: SegmentDensity, wraps: Bool) -> some View {
        SegmentGroup(label: label, selection: $selection, options: options, density: density, wraps: wraps)
    }
}

/// Ordnet Segmente in Zeilen an, die so breit sind, wie der Platz erlaubt – und so ausgeglichen wie möglich: Bei
/// gleicher Zeilenzahl gewinnt die schmalste Anordnung (5 + 5 statt 7 + 3).
struct SegmentFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = SegmentRows.frames(for: sizes(of: subviews), maxWidth: proposal.width, spacing: spacing)
        return frames.reduce(CGRect.null) { $0.union($1) }.standardized.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = SegmentRows.frames(for: sizes(of: subviews), maxWidth: bounds.width, spacing: spacing)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func sizes(of subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }
}

/// Reine Geometrie von `SegmentFlowLayout`, ohne SwiftUI prüfbar.
enum SegmentRows {
    /// Rahmen in Lesereihenfolge; ohne (endliche) Breite eine Zeile. Ein Segment, das allein breiter ist als
    /// `maxWidth`, steht in eigener Zeile.
    static func frames(for sizes: [CGSize], maxWidth: CGFloat?, spacing: CGFloat) -> [CGRect] {
        guard let maxWidth, maxWidth.isFinite else { return place([Array(sizes.indices)], sizes, spacing: spacing) }
        var narrow = sizes.map(\.width).max() ?? 0
        var wide = max(maxWidth, narrow)
        let count = rows(sizes, within: wide, spacing: spacing).count
        // Die Zeilenzahl fällt mit der Breite; gesucht ist die schmalste Breite mit gleich wenigen Zeilen.
        while wide - narrow > 0.5 {
            let middle = (narrow + wide) / 2
            if rows(sizes, within: middle, spacing: spacing).count > count { narrow = middle } else { wide = middle }
        }
        return place(rows(sizes, within: wide, spacing: spacing), sizes, spacing: spacing)
    }

    private static func rows(_ sizes: [CGSize], within width: CGFloat, spacing: CGFloat) -> [[Int]] {
        var rows: [[Int]] = []
        var x: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            if let last = rows.indices.last, x + spacing + size.width <= width {
                rows[last].append(index)
                x += spacing + size.width
            } else {
                rows.append([index])
                x = size.width
            }
        }
        return rows
    }

    private static func place(_ rows: [[Int]], _ sizes: [CGSize], spacing: CGFloat) -> [CGRect] {
        var frames = [CGRect](repeating: .zero, count: sizes.count)
        var y: CGFloat = 0
        for row in rows {
            var x: CGFloat = 0
            for index in row {
                frames[index] = CGRect(origin: CGPoint(x: x, y: y), size: sizes[index])
                x += sizes[index].width + spacing
            }
            y += (row.map { sizes[$0].height }.max() ?? 0) + spacing
        }
        return frames
    }
}
