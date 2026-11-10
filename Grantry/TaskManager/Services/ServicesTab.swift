import ManagerKit
import SwiftUI

/// Tab „Dienste“ (Spec 2026-11-06 §6, Stufe 4): launchd-Dienste der Sitzung (`gui/<uid>`) und des Systems aus
/// `launchctl print` (`LaunchdServicesModel`, nur lesend, alle 5 s, solange der Tab sichtbar ist), verknüpft mit den
/// Autostart-Einträgen des letzten Scans. Starten und Stoppen nur für eigene Agenten über `ServiceControlFlow` mit
/// Bestätigung; jede ausgeführte Aktion steht mit Label und Benutzer im Verlauf, Dienste der Schutzliste stoppt der Ablauf
/// nie. System-Dienste nur Anzeige, bis der Helper sie steuern kann.
struct ServicesTab: View {
    let appModel: AppModel
    @Environment(MainWindowModel.self) private var window
    @State private var options = ServiceListOptions()
    @State private var selection: String?

    var body: some View {
        @Bindable var control = appModel.serviceControl
        let presentation = presentation
        let selected = presentation.rows.first { $0.id == selection }
        VStack(spacing: 0) {
            ServiceListView(presentation: presentation, selection: $selection, query: $options.query,
                            onShowAutostart: { window.show($0) })
            ServiceActionBar(row: selected, canStart: control.canStart,
                             onStart: { selected.map { control.prepare(.start, for: $0) } },
                             onStop: { selected.map { control.prepare(.stop, for: $0) } },
                             onShowAutostart: { selected?.autostartItem.map { window.show($0) } })
        }
        .confirmedTaskManagerAction($control.pendingRequest, actions: appModel.actions,
                                    confirmation: \.confirmation) { await control.confirm($0) }
        .toolbar {
            ToolbarItem {
                Picker("Bereich", selection: $options.scope) {
                    ForEach(ServiceScope.allCases) { scope in
                        Text(verbatim: "\(scope.title) (\(presentation.counts[scope] ?? 0))").tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Eigene Agenten, alle Dienste der Sitzung oder System-Dienste")
            }
        }
        .refreshesPeriodically(every: LaunchdServicesModel.refreshInterval) {
            await appModel.launchdServices.refresh()
        }
    }

    private var presentation: ServiceListPresentation {
        let services = appModel.launchdServices
        let rows = ServiceListPresenter.rows(services.listings,
                                             autostartItems: appModel.presentation?.autostartSections
                                                 .flatMap(\.items) ?? [])
        return ServiceListPresenter.present(rows, options: options, failures: services.failures)
    }
}
