import GrantryCharts
import ManagerKit
import SwiftUI

/// Bereich „Task-Manager“ (Spec 2026-11-06 §2): Tabs und Takt in der Tab-Leiste oben im Inhalt (#463), Messung nur
/// solange sichtbar; alle Tabs auf dem Grund der Instrumententafel, Gestaltung „Lagebild“ (docs/design/instrumententafel.md): oben das Urteil
/// über den Zustand – in der Übersicht als Lagezeile, in allen anderen Tabs als Zustandszeile (Entscheidung E9). „Übersicht“ (`OverviewTab`) seit der Optik, „Prozesse“
/// seit TM3, „Leistung“ (`PerformanceView`) seit TM4, „Details“ seit TM5, „Energie“ (`EnergyTab`) und
/// „App-Verlauf“ (`AppHistoryTab`) seit TM8, „Wachbuch“ (`WatchbookTab`) seit TM-12.5, „Benutzer“ (`UsersTab`) und
/// „Dienste“ (`ServicesTab`) seit TM10, „Chip“
/// (`ChipView`, Apple Silicon) seit 2026.11.7. „Leistung“ misst die Sensoren des Helpers
/// (`SensorModel`) nur, solange „Leistung“, „Chip“ oder „Übersicht“ sichtbar ist (TM9). Autostart bleibt eigener Bereich. Solange der Bereich sichtbar ist, verbucht
/// der App-Verlauf jeden Takt; beim Ausblenden schreibt er offene Stunden.
struct TaskManagerView: View {
    let appModel: AppModel
    @Environment(MainWindowModel.self) private var window

    private var model: TaskManagerModel { appModel.taskManager }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .instrumentBackground()
            .measuresWhileVisible(start: {
                appModel.appUsage.load()
                model.start(for: .window)
            }, stop: {
                model.stop(for: .window)
                appModel.appUsage.flush()
            })
            .pausesChartsWhileHidden()
    }

    private var content: some View {
        TaskManagerPage(showsStatus: !window.taskManagerTab.showsOwnVerdict) {
            TabBar(window: window, model: model)
        } status: {
            TaskManagerStatusLine(model: model)
        } content: {
            tabContent
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch window.taskManagerTab {
        case .overview, .performance, .chip:
            SensorTabs(appModel: appModel, window: window)
        case .processes:
            ProcessesTab(appModel: appModel)
        case .details:
            DetailsTab(appModel: appModel)
        case .energy:
            EnergyTab(appModel: appModel)
        case .appHistory:
            AppHistoryTab(appModel: appModel)
        case .watchbook:
            WatchbookTab(appModel: appModel)
        case .users:
            UsersTab(appModel: appModel)
        case .services:
            ServicesTab(appModel: appModel)
        }
    }
}

/// „Übersicht“, „Leistung“ und „Chip“ zeigen die Sensoren des Helpers (`powermetrics`, TM-9.4). Gemessen wird nur,
/// solange einer davon sichtbar ist – über einen gemeinsamen Zweig, damit ein Wechsel zwischen ihnen die Messung nicht
/// beendet (`SensorModel` kennt nur einen Besitzer). Als eigene Ansicht (#489): Nur sie hängt am Messtakt, nicht der
/// Rahmen samt Tab-Leiste, Bildlauf und Sichtbarkeitsprüfung.
private struct SensorTabs: View {
    let appModel: AppModel
    let window: MainWindowModel

    private var model: TaskManagerModel { appModel.taskManager }

    /// Längerer Leistungsverlauf aus dem Wachbuch (TM-14.5); „Wachbuch einschalten“ setzt die Einstellung.
    private var powerHistory: PowerHistoryAccess {
        let watchbook = appModel.watchbook
        return PowerHistoryAccess(model: appModel.powerHistory, isWatchbookEnabled: watchbook.isEnabled,
                                  enableWatchbook: { watchbook.isEnabled = true })
    }

    var body: some View {
        @Bindable var window = window
        // Zum Messtakt (#481); gemessen wird mit `appModel.sensors`.
        let sensors = appModel.frameSensors.value
        Group {
            switch window.taskManagerTab {
            case .overview:
                OverviewTab(appModel: appModel)
            case .chip:
                ChipView(frame: model.frame, measuredAt: model.frameDate, sensors: sensors.reading,
                         sensorHistory: sensors.history, sensorsMeasuredAt: sensors.measuredAt,
                         clockHistory: sensors.clockHistory, thermal: model.thermal.history, findings: model.findings)
            default:
                PerformanceView(frame: model.frame, measuredAt: model.frameDate, configured: model.configuredSources,
                                focus: $window.performanceFocus, sensors: sensors.reading, sensorHistory: sensors.history,
                                sensorsMeasuredAt: sensors.measuredAt, powerHistory: powerHistory)
            }
        }
        .measuresWhileVisible(start: appModel.sensors.start, stop: appModel.sensors.stop)
    }
}

/// Bindet die Tab-Leiste an Fenster und Messung. Als eigene Ansicht mit Modell-Referenzen hängt sie nur an Tab und Takt:
/// Der Rahmen wertet je Messtakt die Zustandszeile neu aus, die Leiste nicht.
private struct TabBar: View {
    let window: MainWindowModel
    let model: TaskManagerModel

    var body: some View {
        @Bindable var window = window
        @Bindable var model = model
        TaskManagerTabBar(tab: $window.taskManagerTab, interval: $model.interval) { window.show(.autostart) }
    }
}
