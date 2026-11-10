import GrantryCharts
import ManagerKit
import SwiftUI

/// Tab „Energie“ (Spec 2026-11-06 §6 Stufe 2): links Akku (nur mit Akku), Netzteil und Laden (nur mit Akku am
/// Netzteil, Spec 2026-11-08 § 5.3) und großer Graph der Leistungsaufnahme,
/// rechts Apps und Prozesse nach Energie mit Stufe („Trend“, zwei Minuten) wie Windows 11. Liest nur fertige Stände;
/// Messung und Bedienzustand liegen beim `EnergyTab`.
struct EnergyView: View {
    let frame: TaskManagerFrame
    let history: ChartHistory
    let presentation: ProcessListPresentation
    let sort: ProcessSort
    @Binding var selection: String?
    let onSort: (ProcessColumn) -> Void
    let onToggle: (ProcessListRow) -> Void

    @State private var window: HistoryWindow

    init(frame: TaskManagerFrame, measuredAt: Date, presentation: ProcessListPresentation, sort: ProcessSort,
         selection: Binding<String?>, window: HistoryWindow = .fiveMinutes,
         onSort: @escaping (ProcessColumn) -> Void, onToggle: @escaping (ProcessListRow) -> Void) {
        self.frame = frame
        history = ChartHistory(history: frame.history, measuredAt: measuredAt)
        self.presentation = presentation
        self.sort = sort
        _selection = selection
        _window = State(initialValue: window)
        self.onSort = onSort
        self.onToggle = onToggle
    }

    var body: some View {
        let metric = EnergyPresentation.powerMetric(for: frame.snapshot.battery)
        // Bei 900 pt mit Seitenleiste stehen die Karten über der Tabelle, statt den Namen senkrecht zu stauchen (#486).
        InstrumentSideColumnLayout(side: .leading, width: InstrumentSize.columnWide, mainMinimum: Self.tableMinimum) {
            VStack(spacing: InstrumentSpacing.panel) {
                if let battery = frame.snapshot.battery {
                    BatteryCard(battery: battery)
                }
                if let charging = EnergyPresentation.chargingPanel(for: frame.snapshot.battery) {
                    ChargingCard(panel: charging)
                }
                PowerCard(metric: metric, snapshot: frame.snapshot, history: history, window: $window)
                Label(EnergyPresentation.foreignNote, systemImage: "info.circle")
                    .font(InstrumentFont.label)
                    .foregroundStyle(.instrumentSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .instrumentPanel()
            }
            TaskManagerTable {
                ProcessTableHeader(presentation: presentation, sort: sort, columns: EnergyPresentation.columns,
                                   onSort: onSort)
            } rows: {
                ProcessTableRows(presentation: presentation, columns: EnergyPresentation.columns,
                                 selection: $selection, onToggle: onToggle)
            }
        }
        .padding(InstrumentSpacing.page)
        .renderProbe("EnergyView")
    }

    /// Schmalste lesbare Tabelle: Name und Wertspalten in Mindestbreite samt Innenrand.
    static let tableMinimum = ProcessTableLayout.columns(values: EnergyPresentation.columns.count).minimumWidth
        + ProcessTableLayout.horizontalInset
}

// `EnergyPreviewData` gibt es nur im Debug-Build.
#if DEBUG
#Preview("Energie") {
    EnergyView(frame: EnergyPreviewData.frame, measuredAt: .now,
               presentation: EnergyPreviewData.presentation(for: EnergyPreviewData.frame),
               sort: EnergyPresentation.defaultOptions.sort, selection: .constant(nil), onSort: { _ in },
               onToggle: { _ in })
        .frame(width: 1180, height: 760)
        .instrumentBackground()
}

#Preview("Laden") {
    EnergyView(frame: EnergyPreviewData.frameCharging, measuredAt: .now,
               presentation: EnergyPreviewData.presentation(for: EnergyPreviewData.frameCharging),
               sort: EnergyPresentation.defaultOptions.sort, selection: .constant(nil), onSort: { _ in },
               onToggle: { _ in })
        .frame(width: 1180, height: 760)
        .instrumentBackground()
}

#Preview("Ohne Akku") {
    EnergyView(frame: EnergyPreviewData.frameWithoutBattery, measuredAt: .now,
               presentation: EnergyPreviewData.presentation(for: EnergyPreviewData.frameWithoutBattery),
               sort: EnergyPresentation.defaultOptions.sort, selection: .constant(nil), onSort: { _ in },
               onToggle: { _ in })
        .frame(width: 1180, height: 760)
        .instrumentBackground()
}
#endif
