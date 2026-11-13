import SwiftUI

/// Kennzahl „Titel Wert“ in den Panels des Chip-Tabs (Takt, L1, Leistung …).
public struct PanelFact: Hashable, Sendable {
    public let title: String
    public let value: String

    public init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }
}

/// Kennzahlen in einer Zeile; zu schmal, untereinander.
struct FactRow: View {
    let facts: [PanelFact]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: InstrumentSpacing.page) {
                pairs
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) { pairs }
        }
        .font(InstrumentFont.label)
        .lineLimit(1)
    }

    private var pairs: some View {
        ForEach(facts, id: \.title) { fact in
            HStack(spacing: InstrumentSpacing.inline) {
                Text(verbatim: fact.title).foregroundStyle(.instrumentSecondary)
                Text(verbatim: fact.value).fontWeight(.medium).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// GPU oder Neural Engine im Chip-Tab: Kopfdaten, Kennzahlen, Verlauf (ohne Messung `placeholder`) und, falls bekannt,
/// die Zahl der Kerne für den Grundriss.
public struct ChipUnit: Sendable {
    public let title: String
    public let detail: String
    public let value: String
    public let facts: [PanelFact]
    public let series: ChartSeries?
    public let placeholder: String
    public let scale: ChartScale
    public let hue: InstrumentHue
    /// Zellen im Grundriss; `nil` ohne bekannte Kernzahl.
    public let cores: Int?
    public let format: @Sendable (Double) -> String

    public init(title: String, detail: String, value: String, facts: [PanelFact], series: ChartSeries?,
                placeholder: String = "", scale: ChartScale = .fixed(0...1), hue: InstrumentHue, cores: Int? = nil,
                format: @escaping @Sendable (Double) -> String = { $0.formatted(.percent.precision(.fractionLength(0))) }) {
        self.title = title
        self.detail = detail
        self.value = value
        self.facts = facts
        self.series = series
        self.placeholder = placeholder
        self.scale = scale
        self.hue = hue
        self.cores = cores
        self.format = format
    }

    /// Anteil für Zellen und Spur: aktueller Wert relativ zur Skala.
    var fraction: Double? {
        guard let series, let current = series.current else { return nil }
        let upper = scale.upperBound(for: series.values)
        return upper > 0 ? current / upper : nil
    }
}

/// Leistung je Block (Chip-Tab): Zeilen mit Titel, Wert und Spur; der thermische Zustand als Zustandschip. Darunter
/// optional ein Hinweis.
public struct ReadoutStrip: View {
    public struct Readout: Identifiable, Sendable {
        public let title: String
        public let value: String
        /// Füllstand der Spur (0…1); `nil` ohne Messung.
        public let fraction: Double?
        public let hue: InstrumentHue
        /// Gesetzt: Zustand statt Messwert (thermisch), als Chip.
        public let tone: StatusTone?

        public var id: String { title }

        public init(title: String, value: String, fraction: Double?, hue: InstrumentHue) {
            self.title = title
            self.value = value
            self.fraction = fraction
            self.hue = hue
            tone = nil
        }

        public init(title: String, state: String, tone: StatusTone) {
            self.title = title
            value = state
            fraction = nil
            hue = .cpu
            self.tone = tone
        }
    }

    let readouts: [Readout]
    let note: String?

    @Environment(\.self) private var environment

    public init(readouts: [Readout], note: String? = nil) {
        self.readouts = readouts
        self.note = note
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
            ForEach(readouts) { readout in
                if let tone = readout.tone {
                    HStack {
                        Text(verbatim: readout.title).font(InstrumentFont.body)
                        Spacer()
                        StatusChip(readout.value, tone: tone)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    VStack(alignment: .leading, spacing: InstrumentSpacing.inline) {
                        HStack {
                            Text(verbatim: readout.title).font(InstrumentFont.body)
                            Spacer()
                            Text(verbatim: readout.value).font(InstrumentFont.tileValue)
                                .foregroundStyle(readout.fraction == nil ? AnyShapeStyle(.instrumentSecondary)
                                    : AnyShapeStyle(environment.instrumentTextColor(readout.hue)))
                        }
                        Spur(fraction: readout.fraction, color: environment.instrumentColor(readout.hue))
                            .frame(height: InstrumentSize.spurList)
                            .accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let note {
                Label { Text(verbatim: note) } icon: { Image(systemName: "info.circle") }
                    .font(InstrumentFont.label)
                    .foregroundStyle(.instrumentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Chip-Tab (§3.13): Peilkopf mit Chipname und Gesamtleistung, darunter der Grundriss – je physischem Cluster ein Block
/// mit einer Zelle je Kern, GPU mit einer Zelle je GPU-Kern, Neural Engine –, rechts die Leistung je Block; darunter
/// „Takt und Thermik“ (`ClockThermalPanel`) und der Verlauf je Block als Spuren. Zeigt nur gemessene oder aus dem
/// Gerätebaum gelesene Werte.
public struct ChipDashboard: View {
    let title: String
    let summary: String
    let engines: String?
    let total: ReadoutStrip.Readout?
    let energy: ReadoutStrip
    let levels: [CoreGrid.Cluster]
    let gpu: ChipUnit
    let neuralEngine: ChipUnit
    let clock: ClockThermalPanel?
    let window: TimeInterval

    public init(title: String, summary: String, engines: String?, total: ReadoutStrip.Readout?, energy: ReadoutStrip,
                levels: [CoreGrid.Cluster], gpu: ChipUnit, neuralEngine: ChipUnit, clock: ClockThermalPanel? = nil,
                window: TimeInterval = 60) {
        self.title = title
        self.summary = summary
        self.engines = engines
        self.total = total
        self.energy = energy
        self.levels = levels
        self.gpu = gpu
        self.neuralEngine = neuralEngine
        self.clock = clock
        self.window = window
    }

    public var body: some View {
        ChartScrollView(showsIndicators: true) {
            VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
                floorplanPanel
                clock
                historyPanel
            }
            .padding(InstrumentSpacing.page)
        }
    }

    private var floorplanPanel: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
            PeilHead(title, detail: summary, value: total?.value ?? "", hue: .power, fraction: total?.fraction,
                     identifier: "chipTitle")
            if let engines {
                Text(verbatim: engines).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
            }
            // Passen die Blöcke nicht neben die Leistung, steht die Leistung darunter, statt die Cluster zu stauchen
            // („Clus… 1,8…“ bei 900 pt mit Seitenleiste, #486).
            InstrumentSideColumnLayout(side: .trailing, width: InstrumentSize.columnNarrow - InstrumentSpacing.page,
                                       mainMinimum: Self.blocksMinimum(levels)) {
                VStack(spacing: InstrumentSpacing.group) {
                    WeightedRow(spacing: InstrumentSpacing.group, minimumWidth: 160) {
                        ForEach(levels) { level in
                            ForEach(level.groups) { group in
                                DieBlock(title: group.title ?? level.title,
                                         detail: group.title == nil ? level.detail : group.detail,
                                         value: Self.mean(group.cores), hue: level.kind.hue) {
                                    CoreCells(cores: group.cores, hue: level.kind.hue, stretches: true)
                                }
                                .layoutValue(key: WeightedRow.Weight.self, value: Double(group.cores.count))
                            }
                        }
                    }
                    WeightedRow(spacing: InstrumentSpacing.group, minimumWidth: 160) {
                        unitBlock(gpu).layoutValue(key: WeightedRow.Weight.self, value: 2)
                        unitBlock(neuralEngine).layoutValue(key: WeightedRow.Weight.self, value: 1)
                    }
                }
                .frame(maxWidth: .infinity)
                energy
            }
        }
        .instrumentPanel()
    }

    /// Schmalster Block im Grundriss, mit dem die Leistung daneben bleibt: Titel und Wert noch lesbar (so passt der
    /// M2 Ultra mit sechs Clustern bei 1180 pt; der M4 Max mit drei bei 900 pt mit Seitenleiste nicht mehr).
    static let blockMinimum: CGFloat = 136

    /// Breite aller Blöcke einer Reihe in Mindestbreite (die Cluster; GPU und Neural Engine sind zwei).
    static func blocksMinimum(_ levels: [CoreGrid.Cluster]) -> CGFloat {
        let count = max(levels.reduce(0) { $0 + $1.groups.count }, 2)
        return CGFloat(count) * blockMinimum + CGFloat(count - 1) * InstrumentSpacing.group
    }

    private func unitBlock(_ unit: ChipUnit) -> some View {
        DieBlock(title: unit.title, detail: unit.detail, value: unit.value, hue: unit.hue) {
            if unit.series == nil {
                Text(verbatim: unit.placeholder).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
            } else if let cores = unit.cores {
                UnitCells(count: cores, load: unit.fraction, hue: unit.hue)
            } else {
                UnitSpur(fraction: unit.fraction, hue: unit.hue)
            }
        }
    }

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.group) {
            PeilHead(String(localized: "Verlauf je Block"), detail: String(localized: "letzte 60 Sekunden"))
            ForEach(levels) { level in
                VerlaufLane(title: level.title, value: level.value, hue: level.kind.hue) {
                    LaneGraph(series: level.series, scale: .fixed(0...1), window: window, hue: level.kind.hue)
                }
                if !level.facts.isEmpty { FactRow(facts: level.facts).padding(.leading, InstrumentSize.laneLabel) }
            }
            unitLane(gpu)
            unitLane(neuralEngine)
            TimeAxisLabels(window: window).padding(.leading, InstrumentSize.laneLabel + InstrumentSpacing.panel)
        }
        .instrumentPanel()
    }

    @ViewBuilder
    private func unitLane(_ unit: ChipUnit) -> some View {
        VerlaufLane(title: unit.title, value: unit.value, hue: unit.hue) {
            if let series = unit.series {
                LaneGraph(series: series, scale: unit.scale, window: window, hue: unit.hue, format: unit.format)
            } else {
                Text(verbatim: unit.placeholder).font(InstrumentFont.body).foregroundStyle(.instrumentSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .graphFrame()
            }
        }
        if !unit.facts.isEmpty { FactRow(facts: unit.facts).padding(.leading, InstrumentSize.laneLabel) }
    }

    /// Mittlere Auslastung der Kerne eines Clusters aus deren letztem Wert.
    static func mean(_ cores: [CoreGrid.Core]) -> String {
        let loads = cores.compactMap(\.series.current)
        guard !loads.isEmpty else { return "–" }
        return (loads.reduce(0, +) / Double(loads.count)).formatted(.percent.precision(.fractionLength(0)))
    }
}

/// Verlauf einer Spur in der Farbe ihrer Messgröße, mit Punktraster und Peilpunkt.
private struct LaneGraph: View {
    let series: ChartSeries
    let scale: ChartScale
    let window: TimeInterval
    let hue: InstrumentHue
    var format: @Sendable (Double) -> String = { $0.formatted(.percent.precision(.fractionLength(0))) }
    @Environment(\.self) private var environment

    var body: some View {
        LiveGraph(series: series, scale: scale, window: window, color: environment.instrumentColor(hue),
                  isInteractive: false, format: format)
    }
}

/// Spur eines Blocks ohne bekannte Kernzahl.
private struct UnitSpur: View {
    let fraction: Double?
    let hue: InstrumentHue
    @Environment(\.self) private var environment

    var body: some View {
        Spur(fraction: fraction, color: environment.instrumentColor(hue)).frame(height: InstrumentSize.spurTile)
    }
}

/// Block im Grundriss: getönte Fläche mit Titel, Detail und Wert, darunter die Zellen.
struct DieBlock<Cells: View>: View {
    let title: String
    let detail: String
    let value: String
    let hue: InstrumentHue
    @ViewBuilder let cells: Cells
    @Environment(\.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
            HStack(alignment: .firstTextBaseline, spacing: InstrumentSpacing.item) {
                Text(verbatim: title).font(InstrumentFont.body.weight(.semibold)).lineLimit(1)
                Text(verbatim: detail).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary).lineLimit(1)
                Spacer(minLength: InstrumentSpacing.inline)
                Text(verbatim: value).font(InstrumentFont.tileValue)
                    .foregroundStyle(environment.instrumentTextColor(hue))
            }
            .accessibilityElement(children: .combine)
            cells
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel(padding: InstrumentSpacing.cell, radius: InstrumentRadius.block,
                         tint: environment.instrumentColor(hue))
    }
}

/// Zellen eines Blocks ohne Messung je Kern (GPU, #614): Pegel der gesamten Auslastung. Die Zellen füllen sich der Reihe
/// nach in der Farbe der Messgröße, die Grenzzelle anteilig, die übrigen bleiben in der Bahn (wie die Spur, §3.5).
/// Darunter der Hinweis, dass der Pegel die Gesamtauslastung zeigt und nicht einzelne Kerne. Ohne Messung bleibt jede
/// Zelle in der Bahn.
struct UnitCells: View {
    let count: Int
    let load: Double?
    let hue: InstrumentHue
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.self) private var environment

    static let note = String(localized: "Gesamtauslastung, nicht je Kern")

    /// Füllung je Zelle (0…1) in fester Reihenfolge. Die Auslastung zählt in ganzen Prozent: Rauschen unter einem
    /// Prozentpunkt ändert den Pegel nicht und zeichnet nichts neu.
    nonisolated static func fills(count: Int, load: Double?) -> [Double] {
        let percent = (min(max(load.flatMap { $0.isFinite ? $0 : nil } ?? 0, 0), 1) * 100).rounded()
        let filled = percent * Double(count) / 100
        return (0..<max(count, 0)).map { min(max(filled - Double($0), 0), 1) }
    }

    var body: some View {
        let columns = max(min(count, 10), 1)
        let fills = Self.fills(count: count, load: load)
        let color = environment.instrumentColor(hue)
        VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
            Grid(horizontalSpacing: InstrumentSpacing.stack + 1, verticalSpacing: InstrumentSpacing.stack + 1) {
                ForEach(0..<((count + columns - 1) / columns), id: \.self) { row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            if row * columns + column < count {
                                LevelCell(fill: fills[row * columns + column], color: color,
                                          outlined: contrast == .increased)
                            }
                        }
                    }
                }
            }
            Text(verbatim: Self.note).font(InstrumentFont.micro).foregroundStyle(.instrumentSecondary).lineLimit(1)
        }
        .accessibilityReading(Text(verbatim: Self.note),
                              value: Text(verbatim: load.map { min(max($0, 0), 1)
                                  .formatted(.percent.precision(.fractionLength(0))) }
                                  ?? String(localized: "keine Messung")))
    }
}

/// Zelle des Pegels: Bahn in der Messgröße, darüber die Füllung von links bis zum Anteil. „Kontrast erhöhen“ umrandet
/// gefüllte Zellen.
private struct LevelCell: View {
    let fill: Double
    let color: Color
    let outlined: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: InstrumentStroke.ring, style: .continuous)
        ZStack {
            Rectangle().fill(color.opacity(InstrumentOpacity.track))
            Rectangle().fill(color).scaleEffect(x: fill, anchor: .leading)
        }
        .clipShape(shape)
        .overlay {
            if outlined && fill > 0 { shape.strokeBorder(color, lineWidth: InstrumentStroke.border) }
        }
        .frame(height: InstrumentSize.gpuCell)
    }
}
