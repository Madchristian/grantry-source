import GrantryCharts
import ManagerKit
import SwiftUI

/// Akku als Panel der Instrumententafel (§3.6): Peilkopf mit Ladestand, Bogen mit Ladestand im Zustandston (bis 20 %
/// kritisch, sonst in Ordnung) und Zustand, darunter Leistung, Restzeit, Zyklen und Kapazität als Messfelder.
struct BatteryCard: View {
    let battery: BatteryReading
    @Environment(\.self) private var environment

    /// Ab hier gilt der Ladestand als kritisch.
    private static let criticalCharge = 0.2

    var body: some View {
        let charge = battery.charge
        let tone: StatusTone = (charge ?? 1) <= Self.criticalCharge ? .critical : .positive
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            PeilHead(String(localized: "Akku"), value: EnergyPresentation.chargeText(battery), hue: .battery,
                     fraction: charge)
            ArcGauge(fraction: charge, color: environment.statusColor(tone),
                     textColor: tone == .critical ? environment.statusTextColor(tone) : .primary,
                     value: EnergyPresentation.chargeText(battery), caption: EnergyPresentation.stateText(battery))
                .frame(height: InstrumentSize.arcGauge)
                .frame(maxWidth: .infinity)
            StatGrid(stats: EnergyPresentation.batteryStats(battery))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }
}

/// Netzteil und Laden als Panel (Spec 2026-11-08 § 5.3): Peilkopf mit Beschreibung des Netzteils und der Leistung, die
/// es liefert, Peilring als Anteil an der Nennleistung, darunter Netzteil, Ladeleistung, Ladezustand und Auslastung als
/// Messfelder; lädt macOS nicht, sagt ein Satz darunter, woran das liegen kann.
struct ChargingCard: View {
    let panel: ChargingPanel

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            PeilHead(String(localized: "Netzteil und Laden"), detail: panel.detail, value: panel.value, hue: .power,
                     fraction: panel.fraction)
            StatGrid(stats: panel.stats)
            if let note = panel.note {
                Text(verbatim: note)
                    .font(InstrumentFont.label)
                    .foregroundStyle(.instrumentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }
}

/// Großer Graph der Leistungsaufnahme (mit Akku) bzw. der Summe der eigenen Prozesse, mit Zeitraum und Achse.
struct PowerCard: View {
    let metric: MetricKey
    let snapshot: TaskManagerSnapshot
    let history: ChartHistory
    @Binding var window: HistoryWindow
    @Environment(\.self) private var environment

    var body: some View {
        let series = history.series(metric, in: window)
        let scale = ChartScale.automatic(minimum: 1_000)
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            PeilHead(EnergyPresentation.powerTitle(for: metric),
                     value: EnergyPresentation.powerValue(for: metric, in: snapshot), hue: .power,
                     fraction: series.current.map { $0 / scale.upperBound(for: series.values) })
            InstrumentSegments(String(localized: "Zeitraum"), selection: $window,
                               options: HistoryWindow.allCases.map { ($0, $0.title) })
            GraphAxes(leading: GraphAxisLabels.marks(scale, values: series.values, format: { EnergyFormat.power($0) }),
                      frameColor: environment.instrumentColor(.power)) {
                LiveGraph(series: series, scale: scale, window: window.duration.seconds,
                          color: environment.instrumentColor(.power), format: { EnergyFormat.power($0) })
            }
            .frame(minHeight: InstrumentSize.mainGraph)
        }
        .instrumentPanel()
    }
}
