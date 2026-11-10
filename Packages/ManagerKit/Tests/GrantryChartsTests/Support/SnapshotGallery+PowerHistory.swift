import SwiftUI
@testable import GrantryCharts

/// Tab „Leistung“ mit gewählter Leistungsaufnahme über lange Zeiträume aus dem Wachbuch (TM-14.5, #398): Messkarten
/// links, rechts Peilkopf, Zeitraum bis 7 Tage, Darstellung „Gesamt | Je Block“, Verlauf mit Lücken, wo nicht gemessen
/// wurde, und Messfelder über den Zeitraum. Feste Beispieldaten ohne Uhr.
@MainActor
extension SnapshotGallery {
    enum PowerScene: String, CaseIterable, Sendable {
        case hour = "1h"
        case day = "24h-je-block"
        case week = "7-tage"
        case off = "wachbuch-aus"
    }

    static let powerHistorySize = CGSize(width: 1180, height: 760)

    static func powerHistory(_ scene: PowerScene) -> some View {
        PowerHistorySample(scene: scene)
    }

    /// Alle Lagen im Raster für `docs/design/galerie`.
    static var powerHistoryGallery: some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 16) {
            GridRow {
                powerHistory(.hour).frame(width: powerHistorySize.width, height: powerHistorySize.height)
                powerHistory(.day).frame(width: powerHistorySize.width, height: powerHistorySize.height)
            }
            GridRow {
                powerHistory(.week).frame(width: powerHistorySize.width, height: powerHistorySize.height)
                powerHistory(.off).frame(width: powerHistorySize.width, height: powerHistorySize.height)
            }
        }
        .padding(16)
    }
}

private struct PowerHistorySample: View {
    let scene: SnapshotGallery.PowerScene
    private static let periods = ["60 s", "5 min", "15 min", "1 h", "6 h", "24 h", "7 Tage"]
    private static let columns = 480

    var body: some View {
        HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
            VStack(spacing: InstrumentSpacing.group) {
                MeasureCard(title: "CPU", detail: "12 Kerne", value: "23 %", hue: .cpu, fraction: 0.23)
                MeasureCard(title: "Arbeitsspeicher", detail: "18,4 von 36 GB", value: "51 %", hue: .memory,
                            fraction: 0.51)
                MeasureCard(title: "SSD", detail: "Macintosh HD", value: "3,1 MB/s", hue: .diskRead, fraction: 0.08)
                MeasureCard(title: "WLAN", detail: "en0", value: "420 KB/s", hue: .received, fraction: 0.05)
                MeasureCard(title: "GPU", detail: "40 Kerne", value: "12 %", hue: .gpu, fraction: 0.12)
                MeasureCard(title: "Leistungsaufnahme", detail: "CPU 4,10 W · GPU 1,20 W", value: "6,42 W",
                            hue: .power, fraction: 0.32, isSelected: true)
                Spacer(minLength: 0)
            }
            .padding(InstrumentSpacing.stack)
            .frame(width: InstrumentSize.columnNarrow)
            detail
        }
        .padding(InstrumentSpacing.page)
        .instrumentBackground()
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            PeilHead("Leistungsaufnahme", detail: "CPU 4,10 W · GPU 1,20 W", value: "6,42 W", hue: .power,
                     fraction: 0.32)
            HStack(spacing: InstrumentSpacing.panel) {
                InstrumentSegments("Zeitraum", selection: .constant(period),
                                   options: Self.periods.map { ($0, $0) })
                InstrumentSegments("Darstellung", selection: .constant(scene == .day),
                                   options: [(false, "Gesamt"), (true, "Je Block")])
                Spacer()
                if scene == .day {
                    LegendItem(title: "CPU", hue: .cpu)
                    LegendItem(title: "GPU", hue: .gpu)
                    LegendItem(title: "Neural Engine", hue: .neuralEngine)
                }
            }
            if scene == .off {
                GraphNotice("Längere Zeiträume liest Grantry aus dem Wachbuch. Es ist ausgeschaltet.",
                            actionTitle: "Wachbuch einschalten", action: {})
            } else {
                TrendGraph("Leistungsaufnahme", lines: lines, window: window, minimum: 5, format: { Self.watts($0) })
            }
            if scene == .day || scene == .week {
                Label {
                    Text(verbatim: "Aus dem Wachbuch: gemessen, solange Leistung, Chip oder Übersicht offen war. "
                         + "Lücken bleiben leer.")
                } icon: { Image(systemName: "info.circle") }
                    .font(InstrumentFont.label)
                    .foregroundStyle(.instrumentSecondary)
            }
            MeasureFieldRow(fields: fields)
        }
        .instrumentPanel()
    }

    private var period: String {
        switch scene {
        case .hour, .off: "1 h"
        case .day: "24 h"
        case .week: "7 Tage"
        }
    }

    private var window: TimeInterval {
        switch scene {
        case .hour, .off: 3_600
        case .day: 86_400
        case .week: 604_800
        }
    }

    private var lines: [TrendGraph.Line] {
        switch scene {
        case .hour:
            [TrendGraph.Line(series: series { _ in true } value: { t in
                6 + 2.5 * sin(t * 25) + 0.8 * sin(t * 140) + (t > 0.62 && t < 0.74 ? 13 : 0)
            }, hue: .power)]
        case .day:
            [TrendGraph.Line(series: series(Self.dayMeasured) { t in
                3 + 1.5 * sin(t * 90) + (t > 0.84 && t < 0.88 ? 12 : 0)
            }, hue: .cpu),
             TrendGraph.Line(series: series(Self.dayMeasured) { t in
                 0.8 + 0.5 * sin(t * 60) + (t > 0.56 && t < 0.59 ? 9 : 0)
             }, hue: .gpu),
             TrendGraph.Line(series: series(Self.dayMeasured) { t in
                 0.05 + 0.04 * sin(t * 200) + (t > 0.32 && t < 0.34 ? 1.8 : 0)
             }, hue: .neuralEngine)]
        case .week:
            [TrendGraph.Line(series: series(Self.weekMeasured) { t in
                7 + 3 * sin(t * 300) + (t > 0.44 && t < 0.45 ? 15 : 0)
            }, hue: .power)]
        case .off:
            []
        }
    }

    private var fields: [(title: String, value: String)] {
        switch scene {
        case .hour:
            [("Mittel", "8,12 W"), ("Spitze", "21,3 W"), ("CPU", "5,94 W"), ("GPU", "1,41 W"),
             ("Neural Engine", "0,06 W"), ("Gemessen", "60 von 60 min")]
        case .day:
            [("Mittel", "5,87 W"), ("Spitze", "17,6 W"), ("CPU", "3,62 W"), ("GPU", "1,58 W"),
             ("Neural Engine", "0,12 W"), ("Gemessen", "6 h 43 min von 24 h")]
        case .week:
            [("Mittel", "7,04 W"), ("Spitze", "24,8 W"), ("CPU", "4,77 W"), ("GPU", "1,36 W"),
             ("Neural Engine", "0,08 W"), ("Gemessen", "11 h 20 min von 7 Tagen")]
        case .off:
            [("Mittel", "–"), ("Spitze", "–"), ("CPU", "–"), ("GPU", "–"), ("Neural Engine", "–"),
             ("Gemessen", "–")]
        }
    }

    /// Leistung, Chip oder Übersicht waren am Vormittag, kurz am Nachmittag und am Abend offen.
    private static func dayMeasured(_ t: Double) -> Bool {
        (0.30..<0.42).contains(t) || (0.55..<0.60).contains(t) || (0.80..<0.93).contains(t)
    }

    /// An fünf von sieben Tagen je knapp zwei Stunden.
    private static func weekMeasured(_ t: Double) -> Bool {
        let day = Int(t * 7), within = t * 7 - Double(day)
        return day != 2 && day != 5 && (0.38..<0.46).contains(within)
    }

    private func series(_ measured: (Double) -> Bool, value: (Double) -> Double) -> ChartSeries {
        let count = Self.columns
        return ChartSeries(values: (0..<count).map { index in
            let t = Double(index) / Double(count)
            return measured(t) ? max(value(t), 0) : nil
        }, spacing: window / Double(count), latest: SnapshotGallery.latest)
    }

    nonisolated private static func watts(_ value: Double) -> String {
        let digits = value < 10 ? 2 : 1
        return value.formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "de_DE"))) + " W"
    }
}
