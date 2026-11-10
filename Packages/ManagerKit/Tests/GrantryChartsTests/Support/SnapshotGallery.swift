import SwiftUI
@testable import GrantryCharts

/// Die Bausteine des Task-Managers mit festen Fake-Daten wie im Prototyp (TM-2.9), aber ohne Zufall und Uhr – so sind
/// die Snapshot-Bilder reproduzierbar. Jeder Baustein liegt wie in der App in einem Panel der Instrumententafel.
@MainActor
enum SnapshotGallery {
    static let latest = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func series(count: Int = 61, _ value: (Double) -> Double) -> ChartSeries {
        ChartSeries(values: (0..<count).map { value(Double($0)) }, spacing: 1, latest: latest)
    }

    /// CPU mit Lastspitze kurz vor Schluss.
    static let cpu = series { 0.30 + 0.18 * sin($0 / 5) + ($0 > 44 && $0 < 52 ? 0.42 : 0) }
    static let gpu = series { 0.16 + 0.1 * sin($0 / 7 + 1) }
    static let read = series { 42e6 + 30e6 * sin($0 / 6) }
    static let write = series { 14e6 + 11e6 * cos($0 / 4) }
    static let memoryTotal = 32.0 * 1_073_741_824

    static func panel(_ content: some View) -> some View {
        content
            .instrumentPanel(padding: 12)
            .padding(10)
            .instrumentBackground()
    }

    static var liveGraph: some View { panel(LiveGraph(series: cpu)) }

    static var mirrorGraph: some View { panel(MirrorGraph(upper: read, lower: write)) }

    static var memory: some View {
        let gib = 1_073_741_824.0
        return panel(HStack(spacing: 16) {
            StackedAreaGraph(layers: [
                .init(id: "App", series: series { (9 + sin($0 / 9)) * gib }, color: .blue),
                .init(id: "Zugeordnet", series: series { (4 + 0.5 * cos($0 / 7)) * gib }, color: .purple),
                .init(id: "Komprimiert", series: series { (3 + 0.8 * sin($0 / 11)) * gib }, color: .pink),
                .init(id: "Cache", series: series { (6 + 0.4 * sin($0 / 5)) * gib }, color: .teal),
            ], total: memoryTotal)
            PressureRing(fraction: 0.68, level: .warning)
                .frame(width: 110, height: 110)
        })
    }

    /// Wie macOS: Effizienzkerne 0–3, Leistungskerne 4–11; je Cluster der Verlauf des Mittels.
    static var coreGrid: some View {
        func core(_ index: Int) -> CoreGrid.Core {
            CoreGrid.Core(id: index, series: series {
                min(1, max(0, 0.25 + 0.2 * sin($0 / 4 + Double(index)) + (index == 6 ? 0.45 : 0)))
            })
        }
        func cluster(_ kind: CoreGrid.Cluster.Kind, _ title: String, cores: [Int]) -> CoreGrid.Cluster {
            let cores = cores.map(core)
            let average = series { offset in
                let values = cores.compactMap { $0.series.values[Int(offset)] }
                return values.reduce(0, +) / Double(values.count)
            }
            let value = "\(Int(((average.current ?? 0) * 100).rounded())) %"
            return CoreGrid.Cluster(kind: kind, title: title, detail: "\(cores.count) Kerne", value: value,
                                    series: average, cores: cores)
        }
        return panel(CoreGrid(clusters: [cluster(.performance, "Leistungskerne", cores: Array(4...11)),
                                         cluster(.efficiency, "Effizienzkerne", cores: Array(0...3))]))
    }

    static var tiles: some View { InstrumentTiles().padding(12).instrumentBackground() }

    static var metricCards: some View { InstrumentCards().padding(12).instrumentBackground() }

    /// Panel der Übersicht: Segmentanzeige, LED-Pegel, Graph mit Achsen und zweiter Reihe (Leistung).
    static var instrument: some View { panel(InstrumentSample()) }

    /// Lagezeile der Übersicht mit Datenträger-Befunden (TM-15.5): SMART-Fehler führt kritisch, volles Volume und alte
    /// Snapshots als Chips – Texte wie `SystemVerdictPresentation` und `FindingRules` sie liefern.
    static var verdictStorage: some View {
        VerdictBar(verdict: "SMART-Fehler",
                   reason: "Der Datenträger „APPLE SSD AP1024Z“ meldet einen SMART-Fehler – Daten sichern.",
                   finding: true,
                   items: [StatusItem("Speicherdruck normal", tone: .positive),
                           StatusItem("Thermik normal", tone: .positive),
                           StatusItem("Volume fast voll", tone: .finding),
                           StatusItem("Alte lokale Snapshots", tone: .finding),
                           StatusItem("SMART-Fehler", tone: .critical)],
                   facts: "Takt 1 s · 642 Prozesse · 2.814 Threads · Laufzeit 3:04:17")
            .padding(10)
            .instrumentBackground()
    }

    static var heatTable: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                HeatColumnHeader(title: "CPU", value: "38 %", heat: 0.38, sortAscending: false)
                HeatColumnHeader(title: "Speicher", value: "21,4 GB", heat: 0.67, sortAscending: nil)
                HeatColumnHeader(title: "Netzwerk", value: "1,2 MB/s", heat: 0.12, sortAscending: nil)
            }
            HStack(spacing: 4) {
                HeatCell("12,3 %", heat: 0.5)
                HeatCell("2,1 GB", heat: 0.9, hue: .memory)
                HeatCell("–", heat: nil)
            }
            Sparkline(series: cpu, color: InstrumentHue.cpu.color(in: .dark))
                .frame(height: 22)
        }
        .padding(12)
    }
}

/// Messkarten der Auswahlspalte (Leistung): gewählt und in Ruhe.
private struct InstrumentTiles: View {
    var body: some View {
        VStack(spacing: 10) {
            MeasureCard(title: "CPU", detail: "8 P + 4 E", value: "38 %", hue: .cpu, fraction: 0.38, isSelected: true)
            MeasureCard(title: "GPU", value: "16 %", hue: .gpu, fraction: 0.16)
        }
    }
}

/// Messkarten mit stillem Verlauf (Popover der Menüleiste).
private struct InstrumentCards: View {
    @Environment(\.self) private var environment

    var body: some View {
        HStack(spacing: 10) {
            MeasureCard(title: "CPU", value: "38 %", hue: .cpu, fraction: 0.38) {
                Sparkline(series: SnapshotGallery.cpu, scale: .fixed(0...1), color: environment.instrumentColor(.cpu))
                    .frame(height: 40)
            }
            MeasureCard(title: "SSD", value: "42 MB/s", hue: .diskRead, fraction: 0.4) {
                MirrorGraph(upper: SnapshotGallery.read, lower: SnapshotGallery.write,
                            colors: (environment.instrumentColor(.diskRead), environment.instrumentColor(.diskWrite)),
                            showsGrid: false)
                    .frame(height: 40)
            }
        }
    }
}

/// Panel der Übersicht: Peilkopf, Bogen, Graph mit Achsen und zweiter Reihe (Leistung), Spur.
private struct InstrumentSample: View {
    @Environment(\.self) private var environment

    var body: some View {
        let cpu = environment.instrumentColor(.cpu)
        let power = environment.instrumentColor(.power)
        VStack(spacing: 8) {
            PeilHead("CPU-Verlauf", detail: "letzte 60 Sekunden", value: "38 %", hue: .cpu, fraction: 0.38,
                     finding: true)
            HStack(spacing: 10) {
                ArcGauge(fraction: 0.38, color: cpu, textColor: environment.instrumentTextColor(.cpu), value: "38 %",
                         caption: "CPU")
                    .frame(width: 110)
                GraphAxes(leading: ["100 %", "50 %", "0 %"], trailing: ["40 W", "20 W", "0 W"], leadingColor: cpu,
                          trailingColor: power) {
                    LiveGraph(series: SnapshotGallery.cpu,
                              overlays: [.init(series: SnapshotGallery.gpu, scale: .fixed(0...1), color: power)],
                              color: cpu, isInteractive: false)
                }
            }
            Spur(fraction: 0.55, color: environment.instrumentColor(.received)).frame(height: 8)
        }
    }
}
