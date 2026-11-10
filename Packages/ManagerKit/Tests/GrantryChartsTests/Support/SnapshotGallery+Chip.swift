import SwiftUI
@testable import GrantryCharts

/// Chip-Tab mit festen Beispieldaten: M4 Max mit Helper (Werte dieses Entwicklungs-Macs, Last erfunden) und M2 Ultra
/// ohne Helper (Kernnummern beider Chips verschränkt, Takt und Watt „–“).
@MainActor
extension SnapshotGallery {
    /// Kernlast mit gemeinsamer Welle je Stufe und eigener je Kern.
    static func coreLoad(_ core: Int, busy: Double) -> ChartSeries {
        series { offset in
            min(1, max(0, 0.06 + busy * (0.5 + 0.25 * sin(offset / 4 + Double(core) * 1.7)
                + 0.35 * sin(offset / 11)) + (offset > 40 && core % 5 == 1 ? 0.25 : 0)))
        }
    }

    static func level(_ kind: CoreGrid.Cluster.Kind, _ title: String, detail: String, facts: [PanelFact],
                      clusters: [(title: String, detail: String, cores: [Int], busy: Double)]) -> CoreGrid.Cluster {
        let groups = clusters.map { cluster in
            CoreGrid.Group(title: cluster.title, detail: cluster.detail,
                           cores: cluster.cores.map { CoreGrid.Core(id: $0, series: coreLoad($0, busy: cluster.busy)) })
        }
        let cores = groups.flatMap(\.cores)
        let average = series { offset in
            let values = cores.compactMap { $0.series.values[Int(offset)] }
            return values.reduce(0, +) / Double(values.count)
        }
        return CoreGrid.Cluster(kind: kind, title: title, detail: detail,
                                value: "\(Int(((average.current ?? 0) * 100).rounded())) %", series: average,
                                groups: groups, facts: facts, weight: Double(cores.count))
    }

    /// Gesamtleistung für den Kopf, darunter CPU, GPU, Neural Engine und der thermische Zustand.
    static func readouts(_ values: [String], fractions: [Double?], thermal: String)
        -> (total: ReadoutStrip.Readout, strip: ReadoutStrip) {
        let titles = ["Gesamt", "CPU", "GPU", "Neural Engine"]
        let hues: [InstrumentHue] = [.power, .cpu, .gpu, .neuralEngine]
        let readouts = (0..<4).map { ReadoutStrip.Readout(title: titles[$0], value: values[$0], fraction: fractions[$0],
                                                           hue: hues[$0]) }
        return (readouts[0], ReadoutStrip(
            readouts: Array(readouts.dropFirst())
                + [ReadoutStrip.Readout(title: "Thermischer Zustand", state: thermal, tone: .positive)],
            note: fractions.allSatisfy { $0 == nil }
                ? "Leistung, Takt und Cluster-Aktivität misst der Helper (powermetrics) – ohne ihn bleiben sie leer."
                : nil
        ))
    }

    static func gpuUnit(cores: Int, value: Double, facts: [PanelFact]) -> ChipUnit {
        ChipUnit(title: "GPU", detail: "\(cores) Kerne", value: "\(Int((value * 100).rounded())) %", facts: facts,
                 series: series { value + 0.12 * sin($0 / 6) }, hue: .gpu, cores: cores)
    }

    static var chip: some View {
        let energy = readouts(["18,4 W", "12,9 W", "4,71 W", "0,82 W"], fractions: [0.46, 0.32, 0.12, 0.02],
                              thermal: "Normal")
        return ChipDashboard(
            title: "Apple M4 Max",
            summary: "12 Leistungskerne · 4 Effizienzkerne · 40 GPU-Kerne · 64 GB gemeinsamer Arbeitsspeicher",
            engines: "Media Engine: 2 Videoencoder · 1 Videodecoder · 2 ProRes-Engines · Neural Engine",
            total: energy.total, energy: energy.strip,
            levels: [
                level(.performance, "Leistungskerne", detail: "12 Kerne · 2 Cluster à 6 Kerne · je 16 MB L2",
                      facts: [PanelFact("Takt max.", "4,5 GHz"), PanelFact("L1 Befehle/Daten", "192 kB/128 kB")],
                      clusters: [("Cluster P0", "4,1 GHz · 9,8 W", Array(4...9), 0.66),
                                 ("Cluster P1", "1,3 GHz · 0,6 W", Array(10...15), 0.05)]),
                level(.efficiency, "Effizienzkerne", detail: "4 Kerne · 1 Cluster · 4 MB L2",
                      facts: [PanelFact("Takt max.", "2,6 GHz"), PanelFact("L1 Befehle/Daten", "128 kB/64 kB")],
                      clusters: [("Cluster E", "2,1 GHz · 0,4 W", Array(0...3), 0.47)]),
            ],
            gpu: gpuUnit(cores: 40, value: 0.27, facts: [PanelFact("Takt", "1,1 GHz"), PanelFact("Leistung", "4,71 W"),
                                                         PanelFact("Gemeinsamer Speicher", "3,4 GB")]),
            neuralEngine: ChipUnit(title: "Neural Engine", detail: "1 Block", value: "0,82 W",
                                   facts: [PanelFact("Zustand", "aktiv")],
                                   series: series { $0 > 30 ? 0.16 * (0.7 + 0.3 * sin($0 / 3)) : 0 },
                                   scale: .automatic(minimum: 1), hue: .neuralEngine, format: { "\($0) W" }),
            clock: clockPanel
        )
        .instrumentBackground()
    }

    static var chipUltra: some View {
        let energy = readouts(["–", "–", "–", "–"], fractions: [nil, nil, nil, nil], thermal: "Normal")
        return ChipDashboard(
            title: "Apple M2 Ultra",
            summary: "16 Leistungskerne · 8 Effizienzkerne · 76 GPU-Kerne · 192 GB gemeinsamer Arbeitsspeicher",
            engines: "Media Engine: 4 Videoencoder · 2 Videodecoder · 4 ProRes-Engines · Neural Engine: 2 Blöcke",
            total: energy.total, energy: energy.strip,
            levels: [
                level(.performance, "Leistungskerne", detail: "16 Kerne · 4 Cluster à 4 Kerne · je 16 MB L2",
                      facts: [PanelFact("Takt max.", "–"), PanelFact("L1 Befehle/Daten", "192 kB/128 kB")],
                      clusters: [("Cluster P0", "", Array(4...7), 0.66), ("Cluster P1", "", Array(8...11), 0.05),
                                 ("Cluster P2", "", Array(16...19), 0.38), ("Cluster P3", "", Array(20...23), 0.03)]),
                level(.efficiency, "Effizienzkerne", detail: "8 Kerne · 2 Cluster à 4 Kerne · je 4 MB L2",
                      facts: [PanelFact("Takt max.", "–"), PanelFact("L1 Befehle/Daten", "128 kB/64 kB")],
                      clusters: [("Cluster E0", "", Array(0...3), 0.52), ("Cluster E1", "", Array(12...15), 0.21)]),
            ],
            gpu: gpuUnit(cores: 76, value: 0.41, facts: [PanelFact("Takt", "–"), PanelFact("Leistung", "–"),
                                                         PanelFact("Gemeinsamer Speicher", "12,8 GB")]),
            neuralEngine: ChipUnit(title: "Neural Engine", detail: "2 Blöcke", value: "–",
                                   facts: [PanelFact("Zustand", "–")], series: nil,
                                   placeholder: "Nur mit Helper messbar", hue: .neuralEngine),
            clock: clockPanelWithoutHelper
        )
        .instrumentBackground()
    }
}
