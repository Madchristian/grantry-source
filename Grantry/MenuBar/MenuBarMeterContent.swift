import AppKit
import ManagerKit
import SwiftUI

/// Popover eines Elements: Graphen laufen nur, solange es offen ist; der Knopf schließt das Popover (`close`) und springt
/// in den passenden Tab (`open`, in der App `MainWindowNavigator.showTaskManager`). Die Übersicht (#495) misst offen
/// zusätzlich Prozesse, GPU und Akku (Abnehmer `menuBarPopover`) und liest das Startvolume einmal beim Öffnen; den Takt
/// aus dem Helper zeigt sie nur, wenn `sensors` ohnehin misst (Tab „Leistung“ oder „Chip“ sichtbar).
struct MenuBarMeterContent: View {
    let kind: MenuBarMeterKind
    let model: TaskManagerModel
    /// Ausgeblendete Karten der Übersicht (`MenuBarMetersModel.hiddenCards`).
    var meters: MenuBarMetersModel?
    var sensors: SensorModel?
    let close: () -> Void
    let open: (TaskManagerTab, PerformanceMetric?) -> Void
    @State private var isOpen = false
    @State private var startupVolume: VolumeUsage?

    /// Abstand des Popovers zum Rand des Bildschirms; darüber läuft die Übersicht im Bildlauf.
    private static let screenMargin: CGFloat = 80

    var body: some View {
        popover
            .measuresWhileVisible(hiddenDelay: .zero, start: start, stop: stop)
            .pausesChartsWhileHidden()
    }

    /// Tab des Sprungs: Thermik in „Chip“ (Takt und Thermik), Akku in „Energie“, sonst „Leistung“.
    private var tab: TaskManagerTab {
        switch kind {
        case .thermal: .chip
        case .battery: .energy
        default: .performance
        }
    }

    private func start() {
        isOpen = true
        guard kind == .overview else { return }
        model.start(for: .menuBarPopover,
                    sources: MenuBarOverviewPresentation.sources(hiding: meters?.hiddenCards ?? []))
        Task { startupVolume = await VolumeUsage.of("/") }
    }

    private func stop() {
        isOpen = false
        if kind == .overview { model.stop(for: .menuBarPopover) }
    }

    @ViewBuilder private var popover: some View {
        if kind == .overview {
            TaskManagerMenuBarPopover(frame: model.latestFrame, measuredAt: model.latestFrameDate,
                                      profile: .current, context: overviewContext, isLive: isOpen,
                                      maximumHeight: maximumHeight) { card, metric in
                close()
                open(card?.tab ?? .performance, metric)
            }
        } else {
            MenuBarMeterPopover(kind: kind, frame: model.latestFrame, measuredAt: model.latestFrameDate,
                                configured: model.configuredSources, isLive: isOpen) { metric in
                close()
                open(tab, metric)
            }
        }
    }

    /// Alles außer dem Takt, nur bei offenem Popover gelesen: Durchschnittslast, Laufzeit und laufende Apps sind
    /// Systemabfragen ohne Messung (Apps aus dem Zwischenspeicher des Prozess-Tabs).
    private var overviewContext: MenuBarOverviewContext {
        guard isOpen else { return MenuBarOverviewContext(hidden: meters?.hiddenCards ?? []) }
        return MenuBarOverviewContext(sensors: sensors?.reading, startupVolume: startupVolume,
                                      apps: WorkspaceRunningApplications.regularApps(),
                                      loadAverage: LoadAverage.current(), uptime: SystemUptime.sinceBoot(),
                                      hidden: meters?.hiddenCards ?? [])
    }

    private var maximumHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height).map { max($0 - Self.screenMargin, 200) } ?? .infinity
    }
}

extension MenuBarOverviewCard {
    /// Tab des Sprungs; in „Leistung“ wählt die Kachel `MenuBarOverview.metric(for:)`.
    var tab: TaskManagerTab {
        switch self {
        case .cpu, .gpu, .memory, .disk, .network, .summary: .performance
        case .cores, .thermal: .chip
        case .processes: .processes
        case .battery: .energy
        }
    }
}
