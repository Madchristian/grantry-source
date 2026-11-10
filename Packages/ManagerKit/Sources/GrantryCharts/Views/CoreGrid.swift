import SwiftUI

/// Ansicht „Pro Kern“ (§3.13): je Kerncluster ein getönter Block in seiner Farbe – Leistungskerne Petrol-Türkis,
/// Effizienzkerne Lila – mit Peilkopf, dem Verlauf des Clusters (füllt die Höhe) und einer Zelle je Kern, nach
/// Last getönt wie die Hitze der Tabellen. Nur die Cluster-Graphen zeigen Verläufe; die Kern-Zellen zeichnen nur bei
/// neuem Wert. Der Chip-Tab nutzt dieselben Daten für seinen Grundriss.
public struct CoreGrid: View {
    public struct Core: Identifiable, Sendable {
        /// Kernnummer wie von macOS geliefert.
        public let id: Int
        public let series: ChartSeries

        public init(id: Int, series: ChartSeries) {
            self.id = id
            self.series = series
        }
    }

    /// Kerne eines physischen Clusters („Cluster P0“ mit Takt und Aktivität); ohne Titel ein schlichtes Raster.
    public struct Group: Identifiable, Sendable {
        public let title: String?
        public let detail: String
        public let cores: [Core]

        public var id: Int { cores.first?.id ?? -1 }

        public init(title: String?, detail: String = "", cores: [Core]) {
            self.title = title
            self.detail = detail
            self.cores = cores
        }
    }

    public struct Cluster: Identifiable, Sendable {
        public enum Kind: Sendable {
            /// `uniform`: ohne Kerntypen (Intel, virtuelle Maschine), in der Farbe der CPU.
            case performance, efficiency, uniform
        }

        public let kind: Kind
        public let title: String
        /// Kernzahl und Nummern, etwa „12 Kerne · CPU 4–15“.
        public let detail: String
        /// Aktuelle Auslastung des Clusters, fertig formatiert.
        public let value: String
        /// Verlauf der mittleren Auslastung des Clusters.
        public let series: ChartSeries
        public let groups: [Group]
        /// Kennzahlen unter dem Kopf (Chip-Tab: Takt, L1).
        public let facts: [PanelFact]
        /// Anteil an der Breite der Zeile (Chip-Tab: Kernzahl).
        public let weight: Double

        public var id: String { title }
        public var cores: [Core] { groups.flatMap(\.cores) }

        public init(kind: Kind, title: String, detail: String, value: String, series: ChartSeries, cores: [Core]) {
            self.init(kind: kind, title: title, detail: detail, value: value, series: series,
                      groups: [Group(title: nil, cores: cores)])
        }

        public init(kind: Kind, title: String, detail: String, value: String, series: ChartSeries, groups: [Group],
                    facts: [PanelFact] = [], weight: Double = 1) {
            self.kind = kind
            self.title = title
            self.detail = detail
            self.value = value
            self.series = series
            self.groups = groups
            self.facts = facts
            self.weight = weight
        }
    }

    let clusters: [Cluster]
    let window: TimeInterval

    public init(clusters: [Cluster], window: TimeInterval = 60) {
        self.clusters = clusters
        self.window = window
    }

    public var body: some View {
        WeightedRow(spacing: InstrumentSpacing.panel, fills: true) {
            ForEach(clusters) { cluster in
                CoreClusterPanel(cluster: cluster, window: window)
                    .layoutValue(key: WeightedRow.Weight.self, value: cluster.weight)
            }
        }
    }
}

private struct CoreClusterPanel: View {
    let cluster: CoreGrid.Cluster
    let window: TimeInterval

    @Environment(\.self) private var environment

    var body: some View {
        let color = environment.instrumentColor(cluster.kind.hue)
        VStack(alignment: .leading, spacing: InstrumentSpacing.group) {
            PeilHead(cluster.title, detail: cluster.detail, value: cluster.value, hue: cluster.kind.hue,
                     fraction: cluster.series.current)
            if !cluster.facts.isEmpty { FactRow(facts: cluster.facts) }
            LiveGraph(series: cluster.series, window: window, color: color, isInteractive: false)
                .graphFrame(color, cornerRadius: InstrumentRadius.graph)
                .frame(minHeight: InstrumentSize.cardGraph, maxHeight: .infinity)
            ForEach(cluster.groups) { group in
                VStack(alignment: .leading, spacing: InstrumentSpacing.inline) {
                    if let title = group.title { GroupTitle(title: title, detail: group.detail) }
                    CoreCells(cores: group.cores, hue: cluster.kind.hue, stretches: group.title != nil)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .instrumentPanel(tint: color)
    }
}

/// Titel eines physischen Clusters („Cluster P0 · 3,2 GHz“).
struct GroupTitle: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: InstrumentSpacing.item) {
            Text(verbatim: title).fontWeight(.semibold)
            if !detail.isEmpty {
                Text(verbatim: "· \(detail)").foregroundStyle(.instrumentSecondary)
            }
        }
        .font(InstrumentFont.label.monospacedDigit())
        .lineLimit(1)
    }
}

/// Eine Zelle je Kern: Nummer und Auslastung, Grund nach Last in der Farbe der Kernart (§2.6).
struct CoreCells: View {
    let cores: [CoreGrid.Core]
    let hue: InstrumentHue
    let stretches: Bool

    var body: some View {
        TileGrid(stretches: stretches) {
            ForEach(cores) { core in
                CoreCell(id: core.id, load: core.series.current, hue: hue)
            }
        }
    }
}

struct CoreCell: View {
    let id: Int
    let load: Double?
    let hue: InstrumentHue

    var body: some View {
        let load = load.map { min(max($0, 0), 1) }
        HStack(spacing: InstrumentSpacing.inline) {
            Text(verbatim: "\(id)").fontWeight(.semibold)
            Spacer(minLength: InstrumentSpacing.stack)
            Text(verbatim: load.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "–")
        }
        .renderProbe("CoreCell")
        .font(InstrumentFont.micro.monospacedDigit())
        .foregroundStyle(.primary)
        .lineLimit(1)
        .padding(.horizontal, InstrumentSpacing.item)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HeatTile(heat: load ?? 0, hue: hue))
        .accessibilityReading(Text("CPU \(id)"),
                              value: Text(verbatim: load.map { $0.formatted(.percent.precision(.fractionLength(0))) }
                                  ?? String(localized: "keine Messung")))
    }
}

/// Kacheln gleicher Größe in Reihen: so viele Spalten, wie bei `minimumWidth` passen – wie ein adaptives Raster. Mit
/// `stretches` höchstens so viele Spalten wie Kacheln, damit eine Clusterreihe die volle Breite füllt.
struct TileGrid: Layout {
    var stretches = false
    var spacing: CGFloat = InstrumentSpacing.item
    var minimumWidth: CGFloat = 78
    var height: CGFloat = InstrumentSize.coreCell

    func columns(width: CGFloat, count: Int) -> Int {
        // Beim Messen der Idealgröße kann die vorgeschlagene Breite unendlich sein; dann eine Reihe.
        guard width.isFinite else { return max(1, count) }
        let fitting = max(1, Int((width + spacing) / (minimumWidth + spacing)))
        return stretches ? max(1, min(fitting, count)) : fitting
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let natural = CGFloat(subviews.count) * (minimumWidth + spacing) - spacing
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? natural
        let columns = columns(width: width, count: subviews.count)
        let rows = (subviews.count + columns - 1) / columns
        return CGSize(width: width, height: CGFloat(rows) * height + CGFloat(max(rows - 1, 0)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = columns(width: bounds.width, count: subviews.count)
        let width = (bounds.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        for (index, subview) in subviews.enumerated() {
            let origin = CGPoint(x: bounds.minX + CGFloat(index % columns) * (width + spacing),
                                 y: bounds.minY + CGFloat(index / columns) * (height + spacing))
            subview.place(at: origin, proposal: ProposedViewSize(width: width, height: height))
        }
    }
}

/// Panels nebeneinander, Breite nach `Weight` (Chip-Tab: Kernzahl der Stufe), jedes mindestens `minimumWidth` breit.
/// Gleiche Gewichte teilen die Breite gleich auf.
struct WeightedRow: Layout {
    struct Weight: LayoutValueKey {
        static let defaultValue = 1.0
    }

    var spacing: CGFloat = InstrumentSpacing.panel
    var minimumWidth: CGFloat = 250
    /// Füllt eine vorgegebene Höhe (Pro Kern ohne Bildlauf); sonst so hoch wie das höchste Panel.
    var fills = false

    func widths(total: CGFloat, weights: [Double]) -> [CGFloat] {
        guard !weights.isEmpty else { return [] }
        let available = max(total - spacing * CGFloat(weights.count - 1), 0)
        let positive = weights.map { $0.isFinite && $0 > 0 ? $0 : 1 }
        let sum = positive.reduce(0, +)
        var widths = positive.map { available * CGFloat($0 / sum) }
        let narrow = widths.indices.filter { widths[$0] < minimumWidth }
        let deficit = narrow.reduce(CGFloat(0)) { $0 + minimumWidth - widths[$1] }
        let wide = widths.indices.filter { !narrow.contains($0) }
        let wideTotal = wide.reduce(CGFloat(0)) { $0 + widths[$1] }
        guard deficit > 0, wideTotal > deficit else { return widths }
        for index in narrow { widths[index] = minimumWidth }
        for index in wide { widths[index] -= deficit * widths[index] / wideTotal }
        return widths
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let natural = minimumWidth * CGFloat(subviews.count) + spacing * CGFloat(max(subviews.count - 1, 0))
        let total = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? natural
        let widths = widths(total: total, weights: subviews.map { $0[Weight.self] })
        let height = zip(subviews, widths).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max()
        // Mit vorgegebener Höhe (Pro Kern ohne Bildlauf) füllen die Panels sie; im Bildlauf (Chip) zählt ihr Inhalt.
        if fills, let proposed = proposal.height, proposed.isFinite, proposed > (height ?? 0) {
            return CGSize(width: total, height: proposed)
        }
        return CGSize(width: total, height: height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(total: bounds.width, weights: subviews.map { $0[Weight.self] })) {
            subview.place(at: CGPoint(x: x, y: bounds.minY),
                          proposal: ProposedViewSize(width: width, height: fills ? bounds.height : nil))
            x += width + spacing
        }
    }
}

extension CoreGrid.Cluster.Kind {
    /// Farbe der Kernart, auch für die Taktbänder des Chip-Tabs.
    public var hue: InstrumentHue {
        switch self {
        case .performance, .uniform: .cpu
        case .efficiency: .efficiencyCores
        }
    }

    var symbol: String {
        switch self {
        case .performance: "bolt.fill"
        case .efficiency: "leaf.fill"
        case .uniform: "cpu"
        }
    }
}
