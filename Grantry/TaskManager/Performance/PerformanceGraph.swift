import GrantryCharts
import ManagerKit
import SwiftUI

/// Graph einer Messgröße: klein in den Messkarten des Popovers, groß in der Detailansicht (Punktraster, Achsen, Rahmen
/// in der Farbe der Messgröße, Hover, Scrubbing, Zeitraum; bei CPU wahlweise je Kerncluster ein Block, der die Höhe
/// füllt). Jede Messgröße zeichnet in ihrer festen Farbe (`PerformanceMetric.hue`). Kleine Graphen zeigen kein Raster
/// und keine Mittellinie, damit eine Lücke ohne Messung überall leer bleibt (Bewertung 2026.11.7, Mangel 7), und bestehen
/// aus Formen statt `Canvas`: Ein `Canvas` legt einen eigenen Grafikpuffer an, im Popover rund 280 MB (Bewertung
/// 2026.11.9/1510, Mangel 1).
struct PerformanceGraph: View {
    let metric: PerformanceMetric
    let snapshot: TaskManagerSnapshot
    let history: ChartHistory
    let window: HistoryWindow
    let isLarge: Bool
    var perCore = false
    /// Leistungsaufnahme je Block (CPU, GPU, Neural Engine) statt gesamt (TM-14.5).
    var perBlock = false
    /// Verlauf der Sensoren (`SensorModel`, TM-9.4) für `.power`.
    var sensorHistory: ChartHistory?

    @Environment(\.self) private var environment

    private var seconds: TimeInterval { window.duration.seconds }

    private func color(_ hue: InstrumentHue) -> Color { environment.instrumentColor(hue) }

    var body: some View {
        switch metric {
        case .cpu where isLarge && perCore:
            CoreGrid(clusters: coreClusters, window: seconds)
        case .cpu:
            axes(GraphAxisLabels.percent) { line(.cpuTotal, hue: .cpu) }
        case .memory where isLarge:
            HStack(spacing: InstrumentSpacing.empty) {
                axes(GraphAxisLabels.marks(.fixed(0...physicalBytes), values: [], format: GraphAxisLabels.bytes)) {
                    StackedAreaGraph(layers: memoryLayers, total: physicalBytes, window: seconds)
                }
                PressureRing(fraction: usedShare, level: pressureLevel)
                    .frame(width: InstrumentSize.arcGauge + InstrumentSpacing.empty, height: InstrumentSize.arcGauge)
            }
        case .memory:
            line(.memoryUsed, scale: .fixed(0...physicalBytes), hue: .memory,
                 format: { ProcessCleanupPresentation.memoryText(UInt64(max($0, 0))) })
        case .drive(let id):
            mirror(upper: history.series(.diskRead(id), in: window), lower: history.series(.diskWrite(id), in: window),
                   hues: (.diskRead, .diskWrite))
        case .interface(let name):
            mirror(upper: history.series(.received(name), in: window), lower: history.series(.sent(name), in: window),
                   hues: (.received, .sent))
        case .gpu:
            axes(GraphAxisLabels.percent) { line(.gpu, hue: .gpu) }
        case .power where perBlock:
            // Drei Reihen auf gemeinsamer Watt-Skala (Standard §3.4: höchstens drei je Graph).
            let series = [MetricKey.cpuPower, .gpuPower, .neuralEnginePower].map {
                sensorHistory?.series($0, in: window) ?? .empty
            }
            let scale = TrendGraph.sharedScale(series, minimum: 5)
            let hues = PowerPart.blocks.map(\.hue)
            axes(GraphAxisLabels.marks(scale, values: [], format: GraphAxisLabels.watts)) {
                LiveGraph(series: series[0],
                          overlays: zip(series, hues).dropFirst().map {
                              LiveGraph.Overlay(series: $0.0, scale: scale, color: color($0.1))
                          },
                          scale: scale, window: seconds, color: color(hues[0]), showsGrid: isLarge,
                          isInteractive: isLarge, format: GraphAxisLabels.watts)
            }
        case .power:
            // Eigener Takt (2 s) und eigene Skala: Watt statt Anteil, weich mitwachsend wie bei Disk/Netz.
            let series = sensorHistory?.series(.power, in: window) ?? .empty
            let scale = ChartHistory.wattsScale
            axes(GraphAxisLabels.marks(scale, values: series.values, format: GraphAxisLabels.watts)) {
                LiveGraph(series: series, scale: scale, window: seconds, color: color(.power), showsGrid: isLarge,
                          isInteractive: isLarge, format: GraphAxisLabels.watts)
            }
        }
    }

    /// Achsen nur im großen Graphen; die Mini-Graphen der Kacheln bleiben ohne Beschriftung.
    @ViewBuilder
    private func axes(_ labels: [String], @ViewBuilder graph: () -> some View) -> some View {
        if isLarge {
            GraphAxes(leading: labels, frameColor: color(metric.hue), graph: graph)
        } else {
            graph()
        }
    }

    @ViewBuilder
    private func line(_ key: MetricKey, scale: ChartScale = .fixed(0...1), hue: InstrumentHue,
                      format: (@Sendable (Double) -> String)? = nil) -> some View {
        let series = history.series(key, in: window)
        if !isLarge {
            Sparkline(series: series, window: seconds, scale: scale, color: color(hue))
        } else if let format {
            LiveGraph(series: series, scale: scale, window: seconds, color: color(hue), format: format)
        } else {
            LiveGraph(series: series, scale: scale, window: seconds, color: color(hue))
        }
    }

    /// Lesen/Schreiben bzw. Empfangen/Senden um die Nulllinie; die Achse zeigt oben und unten dieselbe Obergrenze.
    private func mirror(upper: ChartSeries, lower: ChartSeries, hues: (InstrumentHue, InstrumentHue)) -> some View {
        let maximum = GraphAxisLabels.rate(MirrorGraph.scale.upperBound(for: upper.values + lower.values))
        return axes([maximum, "0", maximum]) {
            if isLarge {
                MirrorGraph(upper: upper, lower: lower, window: seconds, colors: (color(hues.0), color(hues.1)))
            } else {
                MirrorSparkline(upper: upper, lower: lower, window: seconds, colors: (color(hues.0), color(hues.1)))
            }
        }
    }

    /// Je Kerncluster der Verlauf des Mittels und je Kern seiner; alles aus dem vorhandenen Verlauf je Kern.
    private var coreClusters: [CoreGrid.Cluster] {
        PerformancePresentation.coreClusters(snapshot.cpu?.cores ?? []).map { cluster in
            CoreGrid.Cluster(kind: cluster.kind.chartKind, title: cluster.title, detail: cluster.detail,
                             value: PerformancePresentation.percent(cluster.load),
                             series: history.averageSeries(cluster.cores.map(MetricKey.cpuCore), in: window),
                             cores: cluster.cores.map { CoreGrid.Core(id: $0, series: history.series(.cpuCore($0), in: window)) })
        }
    }

    private var memoryLayers: [StackedAreaGraph.Layer] {
        MemoryComponents.Kind.allCases.map { kind in
            StackedAreaGraph.Layer(id: kind.title, series: history.series(.memory(kind), in: window),
                                   color: color(kind.hue))
        }
    }

    private var physicalBytes: Double { max(Double(snapshot.memory?.physicalBytes ?? 0), 1) }

    private var usedShare: Double { Double(snapshot.memory?.usedBytes ?? 0) / physicalBytes }

    private var pressureLevel: PressureRing.Level {
        switch snapshot.memory?.pressure {
        case .warning: .warning
        case .critical: .critical
        case .normal, nil: .normal
        }
    }
}

/// Beschriftungen der Achsen (oben, Mitte, unten) für `GraphAxes`; die Nulllinie heißt schlicht „0“.
enum GraphAxisLabels {
    static let percent = ["100 %", "50 %", "0 %"]

    static func marks(_ scale: ChartScale, values: [Double?], format: (Double) -> String) -> [String] {
        scale.axisMarks(for: values).map { $0 == 0 ? "0" : format($0) }
    }

    static func bytes(_ value: Double) -> String { ProcessCleanupPresentation.memoryText(UInt64(max(value, 0))) }

    static func rate(_ value: Double) -> String { TrafficFormat.rate(value) }

    @Sendable static func watts(_ value: Double) -> String { PerformancePresentation.watts(value * 1000) }
}

extension PerformanceMetric {
    /// Feste Farbe der Messgröße in Kachel, Graph und Popover.
    var hue: InstrumentHue {
        switch self {
        case .cpu: .cpu
        case .memory: .memory
        case .drive: .diskRead
        case .interface: .received
        case .gpu: .gpu
        case .power: .power
        }
    }
}

extension CoreKind {
    /// Darstellung der Kernklasse in Kernraster, Chip-Tab und Menüleiste (#589): Super- und Leistungskerne in der Farbe
    /// der CPU mit Blitz, Effizienzkerne Lila, unbekannte Klassen neutral; unterschieden werden sie über Titel und Kürzel.
    var chartKind: CoreGrid.Cluster.Kind {
        switch self {
        case .super, .performance: .performance
        case .efficiency: .efficiency
        case .other, .unknown: .uniform
        }
    }

    /// Farbe der Kernklasse (§2.3), dieselbe wie im Kernraster.
    var hue: InstrumentHue { chartKind.hue }
}

extension MemoryComponents.Kind {
    /// Farbe der Ebene in der Speicher-Stapelfläche: App in der Farbe des Arbeitsspeichers, die übrigen abgesetzt
    /// (§2.3).
    var hue: InstrumentHue {
        switch self {
        case .app: .memory
        case .wired: .sent
        case .compressed: .diskWrite
        case .cached: .efficiencyCores
        }
    }
}
