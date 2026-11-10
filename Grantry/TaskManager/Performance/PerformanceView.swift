import GrantryCharts
import ManagerKit
import SwiftUI

/// Tab „Leistung“ (Spec 2026-11-06 §2, §4), Gestaltung „Lagebild“ (§3.13): links Messkarten mit Peilring und Spur zum
/// Wählen, rechts die gewählte Messgröße groß mit Achsen, Zeitraum und Messfeldern. Die Karten zeichnen keine eigenen
/// Verläufe – nur der große Graph tut es. Liest nur fertige Stände des Models.
struct PerformanceView: View {
    let frame: TaskManagerFrame
    let history: ChartHistory
    let configured: Set<TaskManagerSource>
    let uptime: TimeInterval
    /// Sensoren des Helpers (TM-9.4); `nil` ohne Helper – dann fehlt die Kachel „Leistungsaufnahme“.
    let sensors: SensorReading?
    let sensorHistory: ChartHistory?
    /// Längerer Leistungsverlauf aus dem Wachbuch (TM-14.5); `nil` ohne Wachbuch.
    let powerHistory: PowerHistoryAccess?

    @State private var selection: PerformanceMetric?
    /// Kachel, die gewählt werden soll (Sprung aus der Menüleiste); wird nach der Übernahme zurückgesetzt.
    @Binding private var focus: PerformanceMetric?
    @State private var window: HistoryWindow
    @State private var perCore: Bool
    @State private var powerPeriod: WatchbookPeriod?
    @State private var perBlock: Bool

    init(frame: TaskManagerFrame, measuredAt: Date, configured: Set<TaskManagerSource>,
         uptime: TimeInterval = SystemUptime.sinceBoot(), selection: PerformanceMetric? = nil,
         focus: Binding<PerformanceMetric?> = .constant(nil),
         window: HistoryWindow = .oneMinute, perCore: Bool = false, sensors: SensorReading? = nil,
         sensorHistory: SampleHistory? = nil, sensorsMeasuredAt: Date = .now, powerHistory: PowerHistoryAccess? = nil,
         powerPeriod: WatchbookPeriod? = nil, perBlock: Bool = false) {
        self.frame = frame
        history = ChartHistory(history: frame.history, measuredAt: measuredAt)
        self.configured = configured
        self.uptime = uptime
        self.sensors = sensors
        self.sensorHistory = sensorHistory.map { ChartHistory(history: $0, measuredAt: sensorsMeasuredAt) }
        _selection = State(initialValue: selection)
        _focus = focus
        _window = State(initialValue: window)
        _perCore = State(initialValue: perCore)
        self.powerHistory = powerHistory
        _powerPeriod = State(initialValue: powerPeriod)
        _perBlock = State(initialValue: perBlock)
    }

    var body: some View {
        let tiles = PerformancePresentation.tiles(for: frame.snapshot, configured: configured, sensors: sensors)
        let selected = PerformancePresentation.resolvedSelection(selection, in: tiles)
        HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
            ChartScrollView {
                VStack(spacing: InstrumentSpacing.group) {
                    ForEach(tiles) { tile in
                        Button {
                            selection = tile.metric
                        } label: {
                            MeasureCard(title: tile.title, detail: tile.detail, value: tile.value, hue: tile.metric.hue,
                                        fraction: level(of: tile.metric), isSelected: tile.metric == selected)
                        }
                        .buttonStyle(.plain)
                        // Beschriftung aus der Präsentation statt aus den Texten der Karte (Mangel 12, #378).
                        .accessibilityLabel(Text(verbatim: tile.accessibilityLabel))
                        .accessibilityAddTraits(tile.metric == selected ? .isSelected : [])
                        .accessibilityIdentifier("performanceTile")
                    }
                }
                .padding(InstrumentSpacing.stack)
            }
            .frame(width: InstrumentSize.columnNarrow)
            if let tile = tiles.first(where: { $0.metric == selected }) {
                PerformanceDetail(tile: tile, fraction: level(of: tile.metric), snapshot: frame.snapshot,
                                  history: history, uptime: uptime, window: $window, perCore: $perCore,
                                  powerPeriod: $powerPeriod, perBlock: $perBlock, sensors: sensors,
                                  sensorHistory: sensorHistory, powerHistory: powerHistory)
            } else {
                ContentUnavailableView("Noch keine Messwerte", systemImage: "gauge.with.dots.needle.0percent",
                                       description: Text("Die erste Messung folgt mit dem nächsten Takt."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .instrumentPanel()
            }
        }
        .padding(InstrumentSpacing.page)
        .renderProbe("PerformanceView")
        .onChange(of: focus, initial: true) {
            guard let focus else { return }
            selection = focus
            self.focus = nil
        }
    }

    private func level(of metric: PerformanceMetric) -> Double? {
        history.level(of: metric, in: frame.snapshot, sensorHistory: sensorHistory)
    }
}

// `TaskManagerPreviewData` gibt es nur im Debug-Build.
#if DEBUG
#Preview("Leistung") {
    PerformanceView(frame: TaskManagerPreviewData.frame, measuredAt: .now, configured: TaskManagerPreviewData.configured,
                    uptime: TaskManagerPreviewData.uptime)
        .frame(width: 1180, height: 760)
        .instrumentBackground()
}

#Preview("Pro Kern") {
    PerformanceView(frame: TaskManagerPreviewData.frame, measuredAt: .now, configured: TaskManagerPreviewData.configured,
                    uptime: TaskManagerPreviewData.uptime, perCore: true)
        .frame(width: 1180, height: 760)
        .instrumentBackground()
}

#Preview("Arbeitsspeicher") {
    PerformanceView(frame: TaskManagerPreviewData.frame, measuredAt: .now, configured: TaskManagerPreviewData.configured,
                    uptime: TaskManagerPreviewData.uptime, selection: .memory)
        .frame(width: 1180, height: 760)
        .instrumentBackground()
}
#endif
