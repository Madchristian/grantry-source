import Darwin
import ManagerKit
import SwiftUI

/// Tab „Energie“ mit Daten aus dem `TaskManagerModel` (gemessen, solange `TaskManagerView` sichtbar ist). Gruppiert wie
/// der Tab „Prozesse“, sortiert nach Energie; Beenden bleibt im Tab „Prozesse“.
struct EnergyTab: View {
    let appModel: AppModel
    @State private var options = EnergyPresentation.defaultOptions
    @State private var selection: String?
    /// Zeilen je Takt und Bedienzustand (#478): Ein Klick auf eine Zeile baut sie nicht neu.
    @State private var presentations = PresentationCache<TableKey<ProcessListOptions>, ProcessListPresentation>()

    var body: some View {
        let model = appModel.taskManager
        let presentation = presentations.value(for: TableKey(measuredAt: model.frameDate, options: options)) {
            ProcessListPresenter.present(model.frame.snapshot, apps: WorkspaceRunningApplications.regularApps(),
                                         currentUID: getuid(), network: nil, options: options)
        }
        EnergyView(frame: model.frame, measuredAt: model.frameDate, presentation: presentation, sort: options.sort,
                   selection: $selection, onSort: { options.sort = options.sort.selecting($0) },
                   onToggle: { options.toggle($0) })
    }
}
