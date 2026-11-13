import GrantryCharts
import ManagerKit
import SwiftUI

/// Popover der Übersicht in der Menüleiste (#495, Ausbau des Popovers „Auslastung“ aus #317, Gestaltung „Lagebild“):
/// Karten untereinander – CPU, Kerne, Prozesse –, dann paarweise nebeneinander GPU und Arbeitsspeicher, Datenträger und
/// Netz, Thermik und Akku (`MenuBarOverview.rows`), darunter Durchschnittslast und Laufzeit. Was nicht gemessen ist, fehlt. Ein Klick auf eine Karte meldet sie samt Kachel in
/// „Leistung“ (`open`), „Task-Manager öffnen“ meldet keine Karte. Liest nur fertige Stände; ohne `isLive` (Popover geschlossen) zeichnet es keine
/// Graphen. Höher als `maximumHeight` läuft es im Bildlauf.
struct TaskManagerMenuBarPopover: View {
    let frame: TaskManagerFrame
    let measuredAt: Date
    let profile: ChipProfile
    let context: MenuBarOverviewContext
    var isLive = true
    var maximumHeight = CGFloat.infinity
    let open: (MenuBarOverviewCard?, PerformanceMetric?) -> Void
    @Environment(\.self) private var environment

    /// Zwei Kacheln je Zeile passten bei 360 pt nicht (Bewertung 2026.11.9/1510, Später 8); die Karten der Übersicht
    /// behalten dieselbe Breite.
    static let width: CGFloat = 440

    var body: some View {
        let overview = MenuBarOverviewPresentation.overview(for: frame.snapshot, profile: profile, context: context)
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            HStack(spacing: InstrumentSpacing.group) {
                PeilHead(String(localized: "Übersicht"))
                // In SwiftUI gezeichnet statt `.link`: Den AppKit-Knopf zeichnet `ImageRenderer` nicht (Sichtprüfung).
                Button { open(nil, nil) } label: {
                    Label("Task-Manager öffnen", systemImage: "arrow.up.forward.app")
                        .font(InstrumentFont.body.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(environment.statusTextColor(.info))
            }
            if !Self.hasMeasurements(overview) {
                ContentUnavailableView("Noch keine Messwerte", systemImage: "gauge.with.dots.needle.0percent",
                                       description: Text("Die erste Messung folgt mit dem nächsten Takt."))
                    .frame(maxWidth: .infinity)
                    .instrumentPanel()
            } else if maximumHeight.isFinite {
                HeightCappedScroll(limit: maximumHeight) { cards(overview) }
            } else {
                // Ohne Grenze (Snapshots) ohne Bildlauf: `ImageRenderer` zeichnet keinen `ScrollView`.
                cards(overview)
            }
        }
        .padding(InstrumentSpacing.page)
        .frame(width: Self.width)
        .instrumentBackground()
        .renderProbe("TaskManagerMenuBarPopover")
    }

    private func cards(_ overview: MenuBarOverview) -> some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.group) {
            ForEach(overview.rows, id: \.self) { row in
                if row.count > 1 {
                    // Gleich hohe Karten: Die Zeile nimmt die Höhe der höheren, beide füllen sie.
                    HStack(alignment: .top, spacing: InstrumentSpacing.group) {
                        ForEach(row) { card in
                            self.card(card, of: overview)
                                .fixedSize(horizontal: Self.hugsContent(card), vertical: false)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.overviewCardFillsRow, true)
                } else if let card = row.first {
                    self.card(card, of: overview)
                }
            }
        }
    }

    /// Die GPU-Karte braucht nur die Breite ihrer Ringe; den Rest der Zeile bekommt der Arbeitsspeicher für die Legende
    /// mit Werten. Alle anderen Paare teilen die Zeile hälftig.
    static func hugsContent(_ card: MenuBarOverviewCard) -> Bool { card == .gpu }

    /// Ohne Messung des Takts (nur Laufzeit oder Thermik) zeigt das Popover den Leerzustand.
    static func hasMeasurements(_ overview: MenuBarOverview) -> Bool {
        overview.cards.contains { ![.summary, .thermal].contains($0) }
    }

    @ViewBuilder
    private func card(_ card: MenuBarOverviewCard, of overview: MenuBarOverview) -> some View {
        let jump = { open(card, overview.metric(for: card)) }
        let history = isLive ? ChartHistory(history: frame.history, measuredAt: measuredAt) : nil
        switch card {
        case .cpu:
            if let cpu = overview.cpu {
                OverviewCPUCard(cpu: cpu, history: history.map {
                    ($0.series(.cpuTotal, in: .oneMinute), $0.series(.cpuSystem, in: .oneMinute))
                }, open: jump)
            }
        case .cores:
            if let cores = overview.cores { OverviewCoresCard(cores: cores, open: jump) }
        case .processes:
            if let processes = overview.processes { OverviewProcessesCard(processes: processes, open: jump) }
        case .gpu:
            if let gpu = overview.gpu { OverviewGPUCard(gpu: gpu, open: jump) }
        case .memory:
            if let memory = overview.memory { OverviewMemoryCard(memory: memory, open: jump) }
        case .disk:
            if let disk = overview.disk {
                OverviewDiskCard(disk: disk, history: history.flatMap { history in
                    disk.driveID.map {
                        (history.series(.diskRead($0), in: .oneMinute), history.series(.diskWrite($0), in: .oneMinute))
                    }
                }, open: jump)
            }
        case .network:
            if let network = overview.network {
                OverviewNetworkCard(network: network, history: history.map {
                    ($0.series(.received(network.interfaceName), in: .oneMinute),
                     $0.series(.sent(network.interfaceName), in: .oneMinute))
                }, open: jump)
            }
        case .thermal:
            if let thermal = overview.thermal { OverviewThermalCard(thermal: thermal, open: jump) }
        case .battery:
            if let battery = overview.battery { OverviewBatteryCard(battery: battery, open: jump) }
        case .summary:
            if let summary = overview.summary { OverviewSummaryRow(summary: summary) }
        }
    }
}

// `TaskManagerPreviewData` gibt es nur im Debug-Build.
#if DEBUG
#Preview("Menüleiste – Übersicht") {
    TaskManagerMenuBarPopover(frame: TaskManagerPreviewData.frame, measuredAt: .now, profile: .current,
                              context: MenuBarOverviewContext(uptime: TaskManagerPreviewData.uptime)) { _, _ in }
}

#Preview("Menüleiste – ohne Messwerte") {
    TaskManagerMenuBarPopover(frame: .empty(interval: .oneSecond), measuredAt: .now, profile: .current,
                              context: MenuBarOverviewContext()) { _, _ in }
}
#endif
