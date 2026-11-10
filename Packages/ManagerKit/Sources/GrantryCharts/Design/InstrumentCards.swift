import SwiftUI

/// Messkarte (§3.6): Peilring, Titel und Detail, rechts der Wert, darunter die Spur und optional ein stiller Verlauf.
/// Gewählt mit Rand im Grantry-Verlauf. Ersetzt Kacheln und Karten mit LED-Pegel.
public struct MeasureCard<Graph: View>: View {
    let title: String
    let detail: String
    let value: String
    let hue: InstrumentHue
    let fraction: Double?
    let isSelected: Bool
    let graph: Graph

    @Environment(\.self) private var environment

    public init(title: String, detail: String = "", value: String, hue: InstrumentHue, fraction: Double?,
                isSelected: Bool = false, @ViewBuilder graph: () -> Graph) {
        self.title = title
        self.detail = detail
        self.value = value
        self.hue = hue
        self.fraction = fraction
        self.isSelected = isSelected
        self.graph = graph()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
            // Schmal (Seitenleiste in „Leistung“, Popover) steht der Wert unter dem Titel statt daneben, damit weder
            // Titel noch Wert abgeschnitten werden (Bewertung Mangel 11).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: InstrumentSpacing.cell) {
                    ring
                    VStack(alignment: .leading, spacing: 0) {
                        titleText
                        detailText
                    }
                    Spacer(minLength: InstrumentSpacing.inline)
                    valueText
                }
                HStack(spacing: InstrumentSpacing.cell) {
                    ring
                    VStack(alignment: .leading, spacing: 0) {
                        titleText
                        valueText
                        detailText
                    }
                    Spacer(minLength: 0)
                }
            }
            graph.accessibilityHidden(true)
            Spur(fraction: fraction, color: environment.instrumentColor(hue))
                .frame(height: InstrumentSize.spurCard)
                .accessibilityHidden(true)
        }
        .instrumentPanel(padding: InstrumentSpacing.cell, radius: InstrumentRadius.card, focused: isSelected)
        .contentShape(RoundedRectangle(cornerRadius: InstrumentRadius.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var ring: some View {
        PeilRing(fraction: fraction, hue: hue)
            .frame(width: InstrumentSize.peilRingCard, height: InstrumentSize.peilRingCard)
    }

    private var titleText: some View {
        Text(verbatim: title).font(InstrumentFont.title).lineLimit(1).minimumScaleFactor(0.85)
    }

    @ViewBuilder
    private var detailText: some View {
        if !detail.isEmpty {
            Text(verbatim: detail).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary).lineLimit(1)
        }
    }

    private var valueText: some View {
        Text(verbatim: value).font(InstrumentFont.tileValue)
            .foregroundStyle(environment.instrumentTextColor(hue))
            .lineLimit(1).minimumScaleFactor(0.7)
    }
}

extension MeasureCard where Graph == EmptyView {
    public init(title: String, detail: String = "", value: String, hue: InstrumentHue, fraction: Double?,
                isSelected: Bool = false) {
        self.init(title: title, detail: detail, value: value, hue: hue, fraction: fraction, isSelected: isSelected) {
            EmptyView()
        }
    }
}

/// Zählkachel (§3.6): Punkt im Ton, Titel, große Zahl, Detail und Spur mit dem Anteil.
public struct CountTile: View {
    let title: String
    let value: Int
    let detail: String
    let tone: StatusTone
    let fraction: Double?

    @Environment(\.self) private var environment

    public init(title: String, value: Int, detail: String = "", tone: StatusTone, fraction: Double? = nil) {
        self.title = title
        self.value = value
        self.detail = detail
        self.tone = tone
        self.fraction = fraction
    }

    public var body: some View {
        let color = environment.statusColor(tone)
        VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
            HStack(spacing: InstrumentSpacing.item) {
                if tone == .finding {
                    FindingDot(size: InstrumentSize.findingDotSmall)
                } else {
                    Circle().fill(color).frame(width: InstrumentSize.findingDotSmall, height: InstrumentSize.findingDotSmall)
                }
                Text(verbatim: title).font(InstrumentFont.body.weight(.medium)).foregroundStyle(.instrumentSecondary)
            }
            Text(verbatim: value.formatted()).font(InstrumentFont.bigNumber)
            if !detail.isEmpty {
                Text(verbatim: detail).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary).lineLimit(1)
            }
            if let fraction {
                Spur(fraction: fraction, color: color).frame(height: InstrumentSize.spurTile).accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel(radius: InstrumentRadius.card)
        .accessibilityReading(Text(verbatim: "\(title): \(value.formatted())"), value: Text(verbatim: detail))
    }
}

/// Kennzahl als Messfeld (§3.6): Titel klein, Wert in runden Ziffern, auf der Mulde.
public struct MeasureField: View {
    let title: String
    let value: String

    public init(title: String, value: String) {
        self.title = title
        self.value = value
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
            Text(verbatim: title).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary).lineLimit(1)
            Text(verbatim: value).font(InstrumentFont.value)
                .foregroundStyle(value == "–" ? .instrumentSecondary : .primary)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .measureFieldWell()
        .accessibilityElement(children: .combine)
    }
}

/// Messfeld mit verdecktem Wert (§3.6, Spec 2026-11-08 § 4.5): wie `MeasureField`, rechts ein Knopf zum Ein- und
/// Ausblenden. Den Klartext reicht die Ansicht erst nach dem Klick herein; verdeckt erhält das Feld nur die Punkte.
public struct SecretMeasureField: View {
    let title: String
    let value: String
    let isRevealed: Bool
    let isBusy: Bool
    let identifier: String
    let toggle: () -> Void

    /// - Parameters:
    ///   - value: verdeckt die Punkte, eingeblendet der Klartext.
    ///   - identifier: Bedienungshilfen-Kennung; der Wert erhält „…Value“, der Knopf „…Toggle“ (UI-Tests).
    public init(title: String, value: String, isRevealed: Bool, isBusy: Bool = false, identifier: String,
                toggle: @escaping () -> Void) {
        self.title = title
        self.value = value
        self.isRevealed = isRevealed
        self.isBusy = isBusy
        self.identifier = identifier
        self.toggle = toggle
    }

    public var body: some View {
        HStack(spacing: InstrumentSpacing.item) {
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                Text(verbatim: title).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary).lineLimit(1)
                    .accessibilityHidden(true)
                Text(verbatim: value).font(InstrumentFont.value)
                    .foregroundStyle(!isRevealed || value == "–" ? .instrumentSecondary : .primary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .textSelection(.enabled)
                    .accessibilityLabel(isRevealed ? Text(verbatim: "\(title): \(value)") : Text("\(title): verdeckt"))
                    .accessibilityIdentifier(identifier + "Value")
            }
            Spacer(minLength: 0)
            if isBusy {
                ProgressView().controlSize(.small).accessibilityLabel(Text("Wird gelesen"))
            } else {
                Button(action: toggle) {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .font(InstrumentFont.body)
                        .foregroundStyle(.instrumentSecondary)
                }
                .buttonStyle(.plain)
                .help(isRevealed ? Text("Ausblenden") : Text("Einblenden"))
                .accessibilityLabel(isRevealed ? Text("\(title) ausblenden") : Text("\(title) einblenden"))
                .accessibilityIdentifier(identifier + "Toggle")
            }
        }
        .measureFieldWell()
        .accessibilityElement(children: .contain)
    }
}

extension View {
    /// Mulde eines Messfelds: volle Breite, Innenabstand 10 / 8, `radius.block`.
    fileprivate func measureFieldWell() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, InstrumentSpacing.cell)
            .padding(.vertical, InstrumentSpacing.group)
            .background(RoundedRectangle(cornerRadius: InstrumentRadius.block, style: .continuous)
                .fill(.primary.opacity(InstrumentOpacity.well)))
    }
}

/// Messfelder in gleich breiten Spalten: bis sechs in einer Reihe, mehr auf zwei gleich lange Reihen verteilt – nie ein
/// einzelnes Feld allein in einer Reihe (§3.1, Bewertung Mangel 11).
public struct MeasureFieldRow: View {
    let fields: [(title: String, value: String)]

    public init(fields: [(title: String, value: String)]) {
        self.fields = fields
    }

    nonisolated static func columns(for count: Int) -> Int {
        count <= 6 ? max(count, 1) : (count + 1) / 2
    }

    /// Spaltenzahlen von breit nach schmal: erst `columns(for:)`, dann halbiert bis zu zwei Spalten – im schmalen Panel
    /// (Akku in „Energie“) lieber mehr Reihen als abgeschnittene Titel.
    nonisolated static func columnOptions(for count: Int) -> [Int] {
        var options = [columns(for: count)]
        while let last = options.last, last > 2 { options.append((last + 1) / 2) }
        return options
    }

    public var body: some View {
        MeasureFieldGrid(count: fields.count) {
            ForEach(fields.indices, id: \.self) { index in
                MeasureField(title: fields[index].title, value: fields[index].value)
            }
        }
    }
}

/// Raster der Messfelder: die breiteste Spaltenzahl aus `MeasureFieldRow.columnOptions`, bei der jedes Feld mindestens
/// `InstrumentSize.measureField` breit bleibt; je Reihe so hoch wie ihr höchstes Feld.
struct MeasureFieldGrid: Layout {
    let count: Int
    var spacing: CGFloat = InstrumentSpacing.group

    func columns(width: CGFloat) -> Int {
        let options = MeasureFieldRow.columnOptions(for: count)
        guard width.isFinite else { return options[0] }
        return options.first { fieldWidth(width, columns: $0) >= InstrumentSize.measureField } ?? options[options.count - 1]
    }

    func fieldWidth(_ width: CGFloat, columns: Int) -> CGFloat {
        (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let natural = CGFloat(subviews.count) * (InstrumentSize.measureField + spacing) - spacing
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? natural
        let heights = rowHeights(subviews, width: width)
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = columns(width: bounds.width)
        let width = fieldWidth(bounds.width, columns: columns)
        let heights = rowHeights(subviews, width: bounds.width)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            for column in 0..<columns where row * columns + column < subviews.count {
                subviews[row * columns + column].place(
                    at: CGPoint(x: bounds.minX + CGFloat(column) * (width + spacing), y: y),
                    proposal: ProposedViewSize(width: width, height: height))
            }
            y += height + spacing
        }
    }

    private func rowHeights(_ subviews: Subviews, width: CGFloat) -> [CGFloat] {
        let columns = columns(width: width)
        let proposal = ProposedViewSize(width: fieldWidth(width, columns: columns), height: nil)
        return stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)].map { $0.sizeThatFits(proposal).height }.max() ?? 0
        }
    }
}

/// Verlaufsspur (§3.4): Name und Wert links, optional eine Detailzeile, rechts der Graph; mehrere Spuren teilen sich eine
/// Zeitachse.
public struct VerlaufLane<Graph: View>: View {
    let title: String
    let value: String
    let detail: String
    let hue: InstrumentHue
    let spokenTitle: String?
    let identifier: String?
    let graph: Graph

    @Environment(\.self) private var environment

    /// - Parameters:
    ///   - spokenTitle: Titel für VoiceOver, wenn er mehr sagt als der sichtbare (BSD-Name einer Schnittstelle).
    ///   - identifier: Bedienungshilfen-Kennung von Titel und Wert (UI-Tests); sonst der Titel.
    public init(title: String, value: String, detail: String = "", hue: InstrumentHue, spokenTitle: String? = nil,
                identifier: String? = nil, @ViewBuilder graph: () -> Graph) {
        self.title = title
        self.value = value
        self.detail = detail
        self.hue = hue
        self.spokenTitle = spokenTitle
        self.identifier = identifier
        self.graph = graph()
    }

    public var body: some View {
        HStack(spacing: InstrumentSpacing.panel) {
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                Text(verbatim: title).font(InstrumentFont.body.weight(.semibold)).lineLimit(1)
                Text(verbatim: value).font(InstrumentFont.label.weight(.medium).monospacedDigit())
                    .foregroundStyle(environment.instrumentTextColor(hue)).lineLimit(1).minimumScaleFactor(0.7)
                if !detail.isEmpty {
                    Text(verbatim: detail).font(InstrumentFont.label.monospacedDigit()).foregroundStyle(.instrumentSecondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .frame(width: InstrumentSize.laneLabel, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: [spokenTitle ?? title, value, detail].filter { !$0.isEmpty }
                .joined(separator: ", ")))
            .accessibilityIdentifier(identifier ?? title)
            graph.frame(maxWidth: .infinity, minHeight: InstrumentSize.laneHeight, maxHeight: .infinity)
        }
    }
}

/// Beschriftung der Zeitachse unter Verlaufsspuren und Graphen.
public struct TimeAxisLabels: View {
    let labels: [String]

    public init(window: TimeInterval) {
        labels = Self.labels(window: window)
    }

    /// Ganzes Fenster, Hälfte, „jetzt“: in Sekunden, ab 2 min in Minuten, ab 2 h in Stunden, ab 2 Tagen in Tagen
    /// (lange Zeiträume aus dem Wachbuch, TM-14.5).
    static func labels(window: TimeInterval) -> [String] {
        let half = Int((window / 2).rounded())
        let full = Int(window.rounded())
        let now = String(localized: "jetzt")
        switch full {
        case 172_800...:
            let days = { (seconds: Int) in
                (Double(seconds) / 86_400).formatted(.number.precision(.fractionLength(0...1))
                    .locale(Locale(identifier: "de_DE")))
            }
            return ["−\(days(full)) Tage", "−\(days(half)) Tage", now]
        case 7_200...: return ["−\(full / 3_600) h", "−\(half / 3_600) h", now]
        case 120...: return ["−\(full / 60) min", "−\(half / 60) min", now]
        default: return ["−\(full) s", "−\(half) s", now]
        }
    }

    public var body: some View {
        HStack {
            ForEach(labels.indices, id: \.self) { index in
                if index > 0 { Spacer() }
                Text(verbatim: labels[index])
            }
        }
        .font(InstrumentFont.micro.monospacedDigit())
        .foregroundStyle(.instrumentSecondary)
        .accessibilityHidden(true)
    }
}
