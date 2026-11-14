import SwiftUI

// Anordnungen, die sich nach dem Platz richten, ohne `ViewThatFits` (#626): `ViewThatFits` hält je Variante einen eigenen
// Teilbaum und misst bei jeder Änderung eines Werts alle Varianten samt ihren Stapeln neu. Im Popover der Menüleiste
// kostete das je Takt mehr als das Vierfache des übrigen Layouts (Time Profiler: 98 von 133 Proben). Hier gibt es jede
// Unteransicht genau einmal; die Variante folgt aus den Wunschbreiten.

/// Teile nebeneinander, solange sie in die Breite passen, sonst untereinander und linksbündig. Untereinander bekommt
/// jedes Teil die ganze Breite angeboten: Was sich streckt (Tabellenzeile mit `Spacer`), füllt sie, der Rest bleibt
/// schmal. Ersetzt `ViewThatFits(in: .horizontal) { HStack { … }; VStack(alignment: .leading) { … } }`.
public struct FittingLine: Layout {
    public enum Arrangement: Equatable, Sendable {
        case inline, stacked
    }

    let spacing: CGFloat
    let stackedSpacing: CGFloat
    let isJustified: Bool

    /// - Parameters:
    ///   - spacing: Abstand nebeneinander.
    ///   - stackedSpacing: Abstand untereinander.
    ///   - isJustified: Nebeneinander füllt die Zeile die Breite, das letzte Teil steht am rechten Rand.
    public init(spacing: CGFloat, stackedSpacing: CGFloat, isJustified: Bool = false) {
        self.spacing = spacing
        self.stackedSpacing = stackedSpacing
        self.isJustified = isJustified
    }

    /// Breite aller Teile nebeneinander.
    nonisolated static func inlineWidth(_ widths: [CGFloat], spacing: CGFloat) -> CGFloat {
        widths.reduce(0, +) + spacing * CGFloat(max(widths.count - 1, 0))
    }

    /// Nebeneinander, wenn die Wunschbreiten samt Abständen passen; ohne Vorgabe (`nil`) immer.
    nonisolated static func arrangement(widths: [CGFloat], spacing: CGFloat, available: CGFloat?) -> Arrangement {
        guard let available else { return .inline }
        return inlineWidth(widths, spacing: spacing) <= available ? .inline : .stacked
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified) }
        let widths = ideals.map(\.width)
        switch Self.arrangement(widths: widths, spacing: spacing, available: proposal.width) {
        case .inline:
            let width = Self.inlineWidth(widths, spacing: spacing)
            return CGSize(width: isJustified ? max(proposal.width ?? width, width) : width,
                          height: ideals.map(\.height).max() ?? 0)
        case .stacked:
            let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
            return CGSize(width: sizes.map(\.width).max() ?? 0,
                          height: sizes.map(\.height).reduce(0, +) + stackedSpacing * CGFloat(max(sizes.count - 1, 0)))
        }
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified) }
        switch Self.arrangement(widths: ideals.map(\.width), spacing: spacing, available: bounds.width) {
        case .inline:
            var left = bounds.minX
            for (index, subview) in subviews.enumerated() {
                let size = ideals[index]
                if isJustified, index > 0, index == subviews.count - 1 { left = max(left, bounds.maxX - size.width) }
                subview.place(at: CGPoint(x: left, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(size))
                left += size.width + spacing
            }
        case .stacked:
            var top = bounds.minY
            for subview in subviews {
                let proposal = ProposedViewSize(width: bounds.width, height: nil)
                subview.place(at: CGPoint(x: bounds.minX, y: top), anchor: .topLeading, proposal: proposal)
                top += subview.sizeThatFits(proposal).height + stackedSpacing
            }
        }
    }
}

/// Kopf einer Karte: Titel, Detail und Legende links, Wert am rechten Rand, alle auf der ersten Grundlinie. Reicht die
/// Breite nicht, rückt erst die Legende unter die Zeile, dann auch das Detail (`Arrangement`). Die Teile nennen ihre
/// Rolle mit `cardHeadline(_:)`; fehlende Teile (kein Detail, keine Legende, kein Wert) kosten keinen Abstand.
public struct CardHeadline: Layout {
    public enum Part: Sendable {
        case title, detail, legend, value
    }

    public enum Arrangement: Equatable, Sendable {
        /// Alles in einer Zeile.
        case inline
        /// Titel, Detail und Wert in einer Zeile, die Legende darunter.
        case legendBelow
        /// Titel und Wert in einer Zeile, darunter das Detail, darunter die Legende.
        case stacked
    }

    /// Wunschbreiten der Teile; `nil` für ein fehlendes Teil.
    struct Widths: Equatable, Sendable {
        var title: CGFloat
        var detail: CGFloat?
        var legend: CGFloat?
        var value: CGFloat?
    }

    struct PartKey: LayoutValueKey {
        static let defaultValue: Part? = nil
    }

    /// Abstand der Teile in der Zeile.
    let spacing: CGFloat
    /// Kleinster Abstand vor dem Wert, zusätzlich zu `spacing` auf beiden Seiten.
    let valueGap: CGFloat
    /// Abstand zwischen Titelzeile und Detail darunter.
    let detailSpacing: CGFloat
    /// Abstand über der Legende unter der Zeile.
    let legendSpacing: CGFloat

    public init(spacing: CGFloat = InstrumentSpacing.group, valueGap: CGFloat = InstrumentSpacing.inline,
                detailSpacing: CGFloat = InstrumentSpacing.stack, legendSpacing: CGFloat = InstrumentSpacing.item) {
        self.spacing = spacing
        self.valueGap = valueGap
        self.detailSpacing = detailSpacing
        self.legendSpacing = legendSpacing
    }

    /// Breite der Zeile aus Titel, den genannten Teilen links und dem Wert.
    nonisolated static func lineWidth(_ widths: Widths, leading: [CGFloat?], spacing: CGFloat, valueGap: CGFloat)
        -> CGFloat {
        let left = [widths.title] + leading.compactMap { $0 }
        let value = widths.value.map { spacing + $0 } ?? 0
        return left.reduce(0, +) + spacing * CGFloat(left.count - 1) + spacing + valueGap + value
    }

    /// Erste Anordnung, die in `available` passt; ohne Vorgabe (`nil`) alles in einer Zeile. Die Legende unter der
    /// Zeile muss selbst in die Breite passen, sonst rückt auch das Detail nach unten (wie zuvor mit `ViewThatFits`).
    nonisolated static func arrangement(_ widths: Widths, spacing: CGFloat, valueGap: CGFloat, available: CGFloat?)
        -> Arrangement {
        guard let available else { return .inline }
        let fits = { (leading: [CGFloat?]) in
            lineWidth(widths, leading: leading, spacing: spacing, valueGap: valueGap) <= available
        }
        if fits([widths.detail, widths.legend]) { return .inline }
        if widths.legend != nil, fits([widths.detail]), (widths.legend ?? 0) <= available { return .legendBelow }
        return .stacked
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(width: proposal.width, subviews: subviews)
        let width = proposal.width ?? frames.map(\.rect.maxX).max() ?? 0
        return CGSize(width: width, height: frames.map(\.rect.maxY).max() ?? 0)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for frame in frames(width: bounds.width, subviews: subviews) {
            frame.subview.place(at: CGPoint(x: bounds.minX + frame.rect.minX, y: bounds.minY + frame.rect.minY),
                                proposal: ProposedViewSize(frame.rect.size))
        }
    }

    private typealias Frame = (subview: LayoutSubview, rect: CGRect)

    /// Rahmen der Teile ab dem Ursprung des Kopfs; `width == nil` heißt Wunschbreite.
    private func frames(width: CGFloat?, subviews: Subviews) -> [Frame] {
        let part = { (part: Part) in subviews.first { $0[PartKey.self] == part } }
        guard let title = part(.title) else { return [] }
        let detail = part(.detail), legend = part(.legend), value = part(.value)
        let ideal = { (subview: LayoutSubview?) in subview?.sizeThatFits(.unspecified) }
        let widths = Widths(title: ideal(title)?.width ?? 0, detail: ideal(detail)?.width,
                            legend: ideal(legend)?.width, value: ideal(value)?.width)
        let arrangement = Self.arrangement(widths, spacing: spacing, valueGap: valueGap, available: width)
        let inLine: [LayoutSubview?] = switch arrangement {
        case .inline: [detail, legend]
        case .legendBelow: [detail]
        case .stacked: []
        }
        let leading = inLine.compactMap { $0 }
        let total = width ?? Self.lineWidth(widths, leading: leading.map { ideal($0)?.width }, spacing: spacing,
                                            valueGap: valueGap)
        // Titel zuerst kürzen, falls selbst Titel und Wert nicht passen (nur in der letzten Anordnung möglich).
        let reserved = spacing + valueGap + (widths.value.map { spacing + $0 } ?? 0)
            + leading.reduce(0) { $0 + spacing + (ideal($1)?.width ?? 0) }
        let titleWidth = min(widths.title, max(total - reserved, 0))
        var line: [(subview: LayoutSubview, left: CGFloat, size: CGSize)] = []
        var left: CGFloat = 0
        let titleProposal = titleWidth < widths.title ? ProposedViewSize(width: titleWidth, height: nil) : .unspecified
        for (subview, proposal) in [(title, titleProposal)] + leading.map({ ($0, ProposedViewSize.unspecified) }) {
            let size = subview.sizeThatFits(proposal)
            line.append((subview, left, size))
            left += size.width + spacing
        }
        if let value, let size = ideal(value) { line.append((value, total - size.width, size)) }
        // Erste Grundlinie wie `HStack(alignment: .firstTextBaseline)`.
        let baselines = line.map { $0.subview.dimensions(in: ProposedViewSize($0.size))[.firstTextBaseline] }
        let ascent = baselines.max() ?? 0
        let descent = zip(line, baselines).map { $0.size.height - $1 }.max() ?? 0
        var frames: [Frame] = zip(line, baselines).map { part, baseline in
            (part.subview, CGRect(origin: CGPoint(x: part.left, y: ascent - baseline), size: part.size))
        }
        var top = ascent + descent
        let below: [(subview: LayoutSubview?, spacing: CGFloat)] = switch arrangement {
        case .inline: []
        case .legendBelow: [(legend, legendSpacing)]
        case .stacked: [(detail, detailSpacing), (legend, legendSpacing)]
        }
        for (subview, spacing) in below {
            guard let subview else { continue }
            let size = subview.sizeThatFits(ProposedViewSize(width: total, height: nil))
            frames.append((subview, CGRect(origin: CGPoint(x: 0, y: top + spacing), size: size)))
            top += spacing + size.height
        }
        return frames
    }
}

extension View {
    /// Rolle der Ansicht in einem `CardHeadline`.
    public func cardHeadline(_ part: CardHeadline.Part) -> some View {
        layoutValue(key: CardHeadline.PartKey.self, value: part)
    }
}

/// Karten nebeneinander in gleicher Höhe: Die Zeile ist so hoch wie die höchste Karte, alle füllen sie. Die Karten
/// teilen die Breite gleichmäßig; mit `hugsLeading` nimmt die erste nur ihre Wunschbreite, der Rest geht an die anderen.
/// Ersetzt `HStack { … }.fixedSize(horizontal: false, vertical: true)`, der jede Karte zusätzlich mit kleinster und
/// größter Breite vermisst; hier sieht jede Karte nur ihre endgültige Breite.
public struct EqualHeightRow: Layout {
    let spacing: CGFloat
    let hugsLeading: Bool

    public init(spacing: CGFloat, hugsLeading: Bool = false) {
        self.spacing = spacing
        self.hugsLeading = hugsLeading
    }

    /// Breiten der Karten: `leading` ist die Wunschbreite der ersten Karte, wenn sie nur diese nimmt.
    nonisolated static func widths(count: Int, available: CGFloat, spacing: CGFloat, leading: CGFloat?) -> [CGFloat] {
        guard count > 0 else { return [] }
        let content = max(available - spacing * CGFloat(count - 1), 0)
        guard let leading, count > 1 else { return Array(repeating: content / CGFloat(count), count: count) }
        let first = min(leading, content)
        return [first] + Array(repeating: (content - first) / CGFloat(count - 1), count: count - 1)
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideals = { subviews.map { $0.sizeThatFits(.unspecified).width } }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? FittingLine.inlineWidth(ideals(), spacing: spacing)
        let heights = zip(subviews, widths(width, subviews: subviews)).map { subview, width in
            subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
        return CGSize(width: width, height: heights.max() ?? 0)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var left = bounds.minX
        for (subview, width) in zip(subviews, widths(bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: left, y: bounds.minY),
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            left += width + spacing
        }
    }

    private func widths(_ available: CGFloat, subviews: Subviews) -> [CGFloat] {
        let leading = hugsLeading ? subviews.first?.sizeThatFits(.unspecified).width : nil
        return Self.widths(count: subviews.count, available: available, spacing: spacing, leading: leading)
    }
}
