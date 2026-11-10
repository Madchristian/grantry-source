import Darwin
import ManagerKit
import SwiftUI

/// Tab „Übersicht“ (Optik 2026-11-07): Dashboard aus dem `TaskManagerModel` (gemessen, solange `TaskManagerView`
/// sichtbar ist). CPU und Speicher fremder Prozesse für die Top-Prozesse kommen wie in „Prozesse“ aus `ps`
/// (`ForeignProcessUsageModel`), nur solange dieser Tab sichtbar ist; die Sensoren des Helpers misst `TaskManagerView`
/// gemeinsam für „Übersicht“ und „Leistung“. Beides liest der Tab zum Messtakt (`AppModel.frameSensors`, #481). Nur
/// Anzeige, keine Aktionen.
struct OverviewTab: View {
    let appModel: AppModel

    var body: some View {
        let model = appModel.taskManager
        let sensors = appModel.frameSensors.value
        OverviewView(frame: model.frame, measuredAt: model.frameDate, configured: model.configuredSources,
                     processes: model.frame.snapshot
                         .fillingForeignUsage(appModel.frameForeignUsage.value, currentUID: getuid()).processes,
                     interval: model.interval.title, findings: model.findings, sensors: sensors.reading,
                     sensorHistory: sensors.history,
                     sensorsMeasuredAt: sensors.measuredAt)
            .measuresWhileVisible(start: { appModel.foreignProcessUsage.start(for: .overviewTab) },
                                  stop: { appModel.foreignProcessUsage.stop(for: .overviewTab) })
    }
}
