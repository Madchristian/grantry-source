import GrantryCharts
import ManagerKit
import SwiftUI

/// Popover eines Menüleisten-Elements (TM17, Spec 2026-11-09 § 3, Lagebild): Peilkopf mit Wert, Verlauf der letzten
/// Minute, Kennzahlen wie im Leistung-Tab und der Sprung in den passenden Tab. Liest nur fertige Stände; ohne `isLive`
/// (Popover geschlossen) zeichnet es keinen Graphen.
struct MenuBarMeterPopover: View {
    let kind: MenuBarMeterKind
    let frame: TaskManagerFrame
    let measuredAt: Date
    let configured: Set<TaskManagerSource>
    var isLive = true
    /// Laufzeit des Macs für die Kennzahl „Laufzeit“; fest nur in Sichtprüfungen.
    var uptime: () -> TimeInterval = { SystemUptime.sinceBoot() }
    /// Sprung in den Task-Manager; in „Leistung“ auf diese Kachel.
    let open: (PerformanceMetric?) -> Void

    var body: some View {
        content.renderProbe("MenuBarMeterPopover")
    }

    @ViewBuilder private var content: some View {
        let snapshot = frame.snapshot
        switch kind {
        case .thermal:
            let detail = TaskManagerMenuBarPresentation.thermalDetail(snapshot.thermal)
            MeterPopoverPanel(title: kind.title, detail: String(localized: "Zustand laut macOS"), value: detail.value,
                              statusItems: detail.items.map { StatusItem($0.text, tone: $0.tone.statusTone) },
                              note: detail.note, fields: fields(detail.fields),
                              linkTitle: String(localized: "Takt und Thermik im Chip-Tab")) { open(nil) }
        case .battery:
            if let battery = snapshot.battery {
                MeterPopoverPanel(title: kind.title, detail: EnergyPresentation.stateText(battery),
                                  value: EnergyPresentation.chargeText(battery), hue: .battery, fraction: battery.charge,
                                  fields: fields(EnergyPresentation.batteryStats(battery)),
                                  linkTitle: String(localized: "Im Task-Manager öffnen")) { open(nil) }
            } else {
                empty
            }
        default:
            if let tile = TaskManagerMenuBarPresentation.tile(for: kind, in: snapshot, configured: configured) {
                tilePanel(tile)
            } else {
                empty
            }
        }
    }

    private func tilePanel(_ tile: PerformanceTile) -> some View {
        let history = ChartHistory(history: frame.history, measuredAt: measuredAt)
        let stats = TaskManagerMenuBarPresentation.stats(for: tile, in: frame.snapshot, uptime: uptime())
        return MeterPopoverPanel(title: tile.title, detail: tile.detail, value: tile.value, hue: tile.metric.hue,
                                 fraction: history.level(of: tile.metric, in: frame.snapshot, sensorHistory: nil),
                                 fields: fields(stats), linkTitle: String(localized: "Im Task-Manager öffnen")) {
            open(tile.metric)
        } graph: {
            if isLive {
                PerformanceGraph(metric: tile.metric, snapshot: frame.snapshot, history: history, window: .oneMinute,
                                 isLarge: false)
            } else {
                Color.clear
            }
        }
    }

    private var empty: some View {
        ContentUnavailableView("Noch keine Messwerte", systemImage: "gauge.with.dots.needle.0percent",
                               description: Text("Die erste Messung folgt mit dem nächsten Takt."))
            .frame(width: InstrumentSize.columnWide)
            .padding(InstrumentSpacing.page)
            .instrumentBackground()
    }

    private func fields(_ stats: [PerformanceStat]) -> [(title: String, value: String)] {
        stats.map { (title: $0.title, value: $0.value) }
    }
}

// `TaskManagerPreviewData` gibt es nur im Debug-Build.
#if DEBUG
#Preview("Menüleiste – CPU") {
    MenuBarMeterPopover(kind: .cpu, frame: TaskManagerPreviewData.frame, measuredAt: .now,
                        configured: TaskManagerPreviewData.configured) { _ in }
}

#Preview("Menüleiste – Thermik") {
    MenuBarMeterPopover(kind: .thermal, frame: TaskManagerPreviewData.frame, measuredAt: .now,
                        configured: TaskManagerPreviewData.configured) { _ in }
}
#endif
