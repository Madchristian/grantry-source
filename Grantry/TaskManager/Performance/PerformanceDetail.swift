import GrantryCharts
import ManagerKit
import SwiftUI

/// Rechte Seite des Leistung-Tabs (§3.13): Peilkopf mit Titel, Wert und Anteil, Zeitraum 60 s | 5 min | 15 min, bei
/// CPU „Gesamt | Pro Kern“, großer Graph mit Achsen und Messfelder in einer Reihe. Die Leistungsaufnahme bietet dazu
/// 1 h bis 7 Tage aus dem Wachbuch und „Gesamt | Je Block“ (TM-14.5).
struct PerformanceDetail: View {
    let tile: PerformanceTile
    /// Anteil für den Peilring (wie der Pegel der Messkarte).
    let fraction: Double?
    let snapshot: TaskManagerSnapshot
    let history: ChartHistory
    let uptime: TimeInterval
    @Binding var window: HistoryWindow
    @Binding var perCore: Bool
    /// Langer Zeitraum der Leistungsaufnahme; `nil` heißt `window`.
    @Binding var powerPeriod: WatchbookPeriod?
    @Binding var perBlock: Bool
    var sensors: SensorReading?
    var sensorHistory: ChartHistory?
    /// `nil` ohne Wachbuch – dann nur die kurzen Zeiträume.
    var powerHistory: PowerHistoryAccess?

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            PeilHead(tile.title, detail: tile.detail, value: tile.value, hue: tile.metric.hue, fraction: fraction,
                     identifier: "performanceDetailTitle")
            // Zeitraum und Darstellung brechen bei 900 pt mit Seitenleiste um, statt rechts herauszuragen (#486).
            InstrumentControlRow {
                if tile.metric == .power, powerHistory != nil {
                    InstrumentSegments(String(localized: "Zeitraum"), selection: powerRange,
                                       options: PowerRange.allCases.map { ($0, $0.title) })
                } else {
                    InstrumentSegments(String(localized: "Zeitraum"), selection: $window,
                                       options: HistoryWindow.allCases.map { ($0, $0.title) })
                }
                if tile.metric == .power {
                    InstrumentSegments(String(localized: "Darstellung"), selection: $perBlock,
                                       options: [(false, String(localized: "Gesamt")),
                                                 (true, String(localized: "Je Block"))])
                }
                if tile.metric == .cpu {
                    InstrumentSegments(String(localized: "Darstellung"), selection: $perCore,
                                       options: [(false, String(localized: "Gesamt")),
                                                 (true, String(localized: "Pro Kern"))])
                }
            } trailing: {
                legend
            }
            if tile.metric == .power, let powerPeriod, let powerHistory {
                PowerHistorySection(period: powerPeriod, perBlock: perBlock, access: powerHistory)
            } else {
                PerformanceGraph(metric: tile.metric, snapshot: snapshot, history: history, window: window,
                                 isLarge: true, perCore: perCore, perBlock: perBlock, sensorHistory: sensorHistory)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                stats
            }
        }
        .instrumentPanel()
    }

    /// Ein Umschalter für beide Quellen: kurze Fenster aus dem Sensor-Verlauf, lange aus dem Wachbuch.
    private var powerRange: Binding<PowerRange> {
        Binding {
            powerPeriod.map(PowerRange.watchbook) ?? .live(window)
        } set: { range in
            switch range {
            case .live(let live):
                window = live
                powerPeriod = nil
            case .watchbook(let period):
                powerPeriod = period
            }
        }
    }

    @ViewBuilder
    private var legend: some View {
        switch tile.metric {
        case .memory:
            ForEach(MemoryComponents.Kind.allCases, id: \.self) { LegendItem(title: $0.title, hue: $0.hue) }
        case .drive:
            LegendItem(title: String(localized: "Lesen"), hue: .diskRead)
            LegendItem(title: String(localized: "Schreiben"), hue: .diskWrite)
        case .interface:
            LegendItem(title: String(localized: "Empfangen"), hue: .received)
            LegendItem(title: String(localized: "Senden"), hue: .sent)
        case .power where perBlock:
            ForEach(PowerPart.blocks, id: \.self) { LegendItem(title: $0.title, hue: $0.hue) }
        case .cpu, .gpu, .power:
            EmptyView()
        }
    }

    private var stats: some View {
        StatGrid(stats: PerformancePresentation.stats(for: tile.metric, in: snapshot, uptime: uptime, sensors: sensors,
                                                      thermalState: ProcessInfo.processInfo.thermalState))
    }
}
