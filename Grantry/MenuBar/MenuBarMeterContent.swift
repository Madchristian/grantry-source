import AppKit
import ManagerKit
import SwiftUI

/// Popover eines Elements: Graphen laufen nur, solange es offen ist; der Knopf schließt das Popover (`close`) und springt
/// in den passenden Tab (`open`, in der App `MainWindowNavigator.showTaskManager`). Die Übersicht (#495, Baukasten #499)
/// misst offen zusätzlich die Quellen der Kacheln auf ihrer Tafel (`MenuBarMetersModel.beginOverviewMeasurement`) und
/// liest Kontextwerte nur, wenn eine Kachel sie verlangt: das Startvolume einmal beim Öffnen, den Takt aus dem Helper
/// nur, wenn `sensors` ohnehin misst (Tab „Leistung“ oder „Chip“ sichtbar).
struct MenuBarMeterContent: View {
    let kind: MenuBarMeterKind
    let model: TaskManagerModel
    let meters: MenuBarMetersModel
    var sensors: SensorModel?
    let close: () -> Void
    let open: (TaskManagerTab, PerformanceMetric?) -> Void
    @State private var isOpen = false
    @State private var startupVolume: VolumeUsage?
    @Environment(\.statusItemScreenFrame) private var screenFrame

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
        meters.beginOverviewMeasurement()
    }

    private func stop() {
        isOpen = false
        if kind == .overview { meters.endOverviewMeasurement() }
    }

    @ViewBuilder private var popover: some View {
        if kind == .overview {
            TaskManagerMenuBarPopover(frame: model.latestFrame, measuredAt: model.latestFrameDate,
                                      profile: .current, context: overviewContext,
                                      placements: meters.overviewPlacements, editing: meters.overviewEditing,
                                      isLive: isOpen, maximumHeight: maximumHeight) { tile, metric in
                close()
                open(tile?.tab ?? .performance, metric)
            }
            .readsStartupVolume(for: meters.overviewLayout, while: isOpen, into: $startupVolume)
        } else {
            MenuBarMeterPopover(kind: kind, frame: model.latestFrame, measuredAt: model.latestFrameDate,
                                configured: model.configuredSources, isLive: isOpen) { metric in
                close()
                open(tab, metric)
            }
        }
    }

    /// Kontext nur bei offenem Popover gelesen: Durchschnittslast, Laufzeit und laufende Apps sind Systemabfragen ohne
    /// Messung (Apps aus dem Zwischenspeicher des Prozess-Tabs), und nur für Kacheln auf der Tafel.
    private var overviewContext: MenuBarOverviewContext {
        let board = meters.overviewLayout
        guard isOpen else { return MenuBarOverviewContext(tiles: Set(board.tiles.map(\.kind))) }
        return MenuBarOverviewContext(board: board, sensors: sensors?.reading, startupVolume: startupVolume)
    }

    /// Grenze der Tafel aus dem Bildschirm des Statusobjekts; bis 2026.11.14 aus `NSScreen.main` abzüglich geschätzter
    /// 80 pt, auf einem zweiten Bildschirm also aus dem falschen.
    private var maximumHeight: CGFloat {
        (screenFrame ?? NSScreen.main?.visibleFrame).map(TaskManagerMenuBarPopover.boardLimit(in:)) ?? .infinity
    }
}

extension EnvironmentValues {
    /// Sichtbarer Bereich des Bildschirms mit dem Statusobjekt, unter dem sein Popover öffnet; `nil` außerhalb.
    @Entry var statusItemScreenFrame: CGRect?
}

extension MenuBarMetersModel {
    /// Tafel der Übersicht zum Bearbeiten, im Popover wie in den Einstellungen (Spec 2026-11-09-uebersicht-baukasten
    /// § 5, E3).
    var overviewEditing: TaskManagerMenuBarPopover.Editing {
        .init(layout: Binding(get: { self.overviewLayout }, set: { self.setOverviewLayout($0) }),
              configured: configuredSources)
    }
}

extension View {
    /// Liest die Belegung des Startvolumes einmal, sobald die Tafel offen ist und eine Kachel sie verlangt (Datenträger).
    func readsStartupVolume(for board: OverviewBoardLayout, while isOpen: Bool,
                            into volume: Binding<VolumeUsage?>) -> some View {
        task(id: isOpen && board.requirements.context.contains(.startupVolume)) {
            guard isOpen, board.requirements.context.contains(.startupVolume) else { return }
            volume.wrappedValue = await VolumeUsage.of("/")
        }
    }
}

extension OverviewTileKind {
    /// Tab des Sprungs; in „Leistung“ wählt die Kachel `MenuBarOverview.metric(for:)`.
    var tab: TaskManagerTab {
        switch self {
        case .cpu, .gpu, .memory, .disk, .network, .loadAverage, .uptime: .performance
        case .cores, .thermal: .chip
        case .processes: .processes
        case .battery: .energy
        }
    }
}
