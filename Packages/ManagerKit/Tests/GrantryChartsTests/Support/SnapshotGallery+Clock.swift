import SwiftUI
@testable import GrantryCharts

/// Panel „Takt und Thermik“ mit festen Beispieldaten: Taktstufen der echten `powermetrics`-Ausgabe (M4 Max, M2 Ultra),
/// Anteile erfunden.
@MainActor
extension SnapshotGallery {
    static let m4PerformanceSteps = [1260.0, 1512, 1800, 2088, 2352, 2616, 2868, 3096, 3300, 3468, 3624, 3756, 3828, 3888,
                                     3948, 3996, 4044, 4104, 4416, 4512]
    static let m4EfficiencySteps = [1020.0, 1404, 1788, 2112, 2352, 2532, 2592]
    static let ultraPerformanceSteps = [660.0, 924, 1188, 1452, 1704, 1968, 2208, 2400, 2568, 2724, 2868, 2988, 3096,
                                        3204, 3324, 3408, 3504, 3576, 3624, 3696]

    /// Anteile als Glocke um `peak` (Index), dazu `top` auf der höchsten Stufe; zusammen 1.
    static func shares(count: Int, peak: Double, width: Double, top: Double = 0) -> [Double] {
        let bell = (0..<count).map { exp(-pow((Double($0) - peak) / width, 2)) }
        let sum = bell.reduce(0, +)
        var shares = bell.map { $0 / sum * (1 - top) }
        shares[count - 1] += top
        return shares
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded())) %" }

    static func gigahertz(_ megahertz: Double) -> String {
        (megahertz / 1000).formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "de_DE")))
    }

    static func band(_ title: String, hue: InstrumentHue, steps: [Double], shares: [Double]) -> ClockBand {
        let mostFrequent = zip(steps, shares).max { $0.1 < $1.1 }?.0 ?? 0
        let top = shares.last ?? 0
        let value = "meist \(gigahertz(mostFrequent)) GHz"
        let detail = "Höchsttakt \(percent(top))"
        return ClockBand(id: title, title: title, value: value, detail: detail, hue: hue,
                         steps: zip(steps, shares).map { step, share in
                             ClockBand.Step(id: step, frequency: gigahertz(step), share: share < 0.005 ? "–" : percent(share),
                                            heat: share / (shares.max() ?? 1))
                         },
                         accessibilityValue: "häufigste Stufe \(gigahertz(mostFrequent)) GHz, Höchsttakt \(percent(top))")
    }

    /// Ohne Helper eine Zeile für alle Cluster statt je Cluster ein leerer Rahmen.
    static func unmeasured(clusters: Int) -> ClockBand {
        ClockBand(id: "unmeasured", title: "Taktstufen", value: "–", detail: "\(clusters) Cluster", hue: .cpu, steps: [],
                  placeholder: "Ohne Helper nicht messbar", accessibilityValue: "ohne Helper nicht messbar")
    }

    static func thermal(_ segments: [ThermalBand.Segment], current: StatusItem, detail: String) -> ThermalBand {
        ThermalBand(current: current, detail: detail, segments: segments, window: 900,
                    accessibilityValue: "letzte 15 Minuten: " + segments.map(\.title).joined(separator: ", dann "))
    }

    /// M4 Max mit Helper: P0 unter Last nahe am Höchsttakt, P1 meist in Ruhe, kurz mäßige Thermik vor 9 Minuten.
    static var clockPanel: ClockThermalPanel {
        ClockThermalPanel(
            head: .init(title: "Takt und Thermik",
                        detail: "Leistungskerne: 2 Cluster à 6 Kerne, je 16 MB L2 · Effizienzkerne: 1 Cluster, 4 Kerne, 4 MB L2",
                        value: "4,10 GHz", fraction: 0.91, finding: nil),
            caption: "Anteil der aktiven Zeit je Taktstufe, letzte 60 Sekunden",
            bands: [
                band("Cluster P0", hue: .cpu, steps: m4PerformanceSteps,
                     shares: shares(count: 20, peak: 16.5, width: 2.2, top: 0.34)),
                band("Cluster P1", hue: .cpu, steps: m4PerformanceSteps,
                     shares: shares(count: 20, peak: 0.6, width: 1.6, top: 0.02)),
                band("Cluster E", hue: .efficiencyCores, steps: m4EfficiencySteps,
                     shares: shares(count: 7, peak: 3, width: 1.6, top: 0.08)),
            ],
            thermal: thermal([.init(start: 0, end: 0.31, title: "Normal", tone: .positive),
                              .init(start: 0.31, end: 0.44, title: "Mäßig", tone: .finding),
                              .init(start: 0.44, end: 1, title: "Normal", tone: .positive)],
                             current: StatusItem("Normal", tone: .positive), detail: "Druck: nominal"),
            thermalTitle: "Thermik"
        )
    }

    /// M2 Ultra mit Helper unter Dauerlast: Druck ernst, Leistungscluster deutlich unter dem Höchsttakt – Drosselung.
    static var clockPanelThrottled: ClockThermalPanel {
        let ultra = { (title: String, peak: Double) in
            band(title, hue: .cpu, steps: ultraPerformanceSteps, shares: shares(count: 20, peak: peak, width: 1.8))
        }
        return ClockThermalPanel(
            head: .init(title: "Takt und Thermik",
                        detail: "Leistungskerne: 4 Cluster à 4 Kerne, je 16 MB L2 · Effizienzkerne: 2 Cluster à 4 Kerne, je 4 MB L2",
                        value: "2,40 GHz", fraction: 0.65,
                        finding: "Drosselung: Die Leistungskerne laufen seit 3 Minuten unter Last mit 65 % des Höchsttakts."),
            caption: "Anteil der aktiven Zeit je Taktstufe, letzte 60 Sekunden",
            bands: [ultra("Cluster P0", 7.4), ultra("Cluster P1", 7), ultra("Cluster P2", 6.6), ultra("Cluster P3", 7.2),
                    band("Cluster E0", hue: .efficiencyCores, steps: [912, 1284, 1752, 2004, 2256, 2424],
                         shares: shares(count: 6, peak: 2.4, width: 1.2)),
                    band("Cluster E1", hue: .efficiencyCores, steps: [912, 1284, 1752, 2004, 2256, 2424],
                         shares: shares(count: 6, peak: 2.2, width: 1.2))],
            thermal: thermal([.init(start: 0, end: 0.52, title: "Normal", tone: .positive),
                              .init(start: 0.52, end: 0.78, title: "Mäßig", tone: .finding),
                              .init(start: 0.78, end: 1, title: "Ernst", tone: .finding)],
                             current: StatusItem("Ernst", tone: .finding), detail: "Druck: stark"),
            thermalTitle: "Thermik"
        )
    }

    /// M2 Ultra ohne Helper: Cluster bekannt, Takt nicht messbar; das Thermikband aus `thermalState` bleibt, vor dem
    /// ersten bekannten Stand eine Lücke.
    static var clockPanelWithoutHelper: ClockThermalPanel {
        ClockThermalPanel(
            head: .init(title: "Takt und Thermik",
                        detail: "Leistungskerne: 4 Cluster à 4 Kerne, je 16 MB L2 · Effizienzkerne: 2 Cluster à 4 Kerne, je 4 MB L2",
                        value: "–", fraction: nil, finding: nil),
            caption: "Anteil der aktiven Zeit je Taktstufe, letzte 60 Sekunden",
            bands: [unmeasured(clusters: 6)],
            thermal: thermal([.init(start: 0.62, end: 1, title: "Normal", tone: .positive)],
                             current: StatusItem("Normal", tone: .positive), detail: ""),
            thermalTitle: "Thermik"
        )
    }

    static func clockGallery(_ panel: ClockThermalPanel) -> some View {
        panel.padding(InstrumentSpacing.page).instrumentBackground()
    }
}
