import Darwin
import GrantryCharts
import ManagerKit
import SwiftUI

/// Tab „Prozesse“ (Spec 2026-11-06 §2): Stand aus dem `TaskManagerModel` (gemessen, solange `TaskManagerView` sichtbar
/// ist), gruppiert nach Apps, Hintergrund und System, durchsuchbar nach Name oder PID. „Task beenden“ (⌫) und „Sofort
/// beenden“ (⌥⌫) laufen über `TaskTerminationFlow` mit Bestätigung, „Priorität“ über `TaskPriorityFlow` (beide
/// gemeinsam mit „Details“, `TaskManagerFlows`); Prozesse anderer Benutzer gehen einzeln an den Helper, der je Aktion
/// nach dem Administratorkennwort fragt (TM9). Die Netzspalte (`NetworkActivityModel`, nettop, ohne DNS-Abfragen) und
/// CPU/Speicher fremder Prozesse (`ForeignProcessUsageModel`, ps) messen nur, solange dieser Tab sichtbar ist.
struct ProcessesTab: View {
    let appModel: AppModel
    @State private var options = ProcessListOptions()
    @State private var selection: String?
    /// Zeilen je Takt und Bedienzustand (#478): `ps`, nettop und ein Klick auf eine Zeile bauen sie nicht neu.
    @State private var presentations = PresentationCache<TableKey<ProcessListOptions>, ProcessListPresentation>()
    @FocusState private var isTableFocused: Bool

    var body: some View {
        let flows = TaskManagerFlows(appModel)
        let presentation = presentation
        let currentUID = getuid()
        let selected = presentation.rows.first { $0.id == selection }
        let candidate = selected?.terminationCandidate(currentUID: currentUID, allowingForeign: true)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
                InstrumentSearchField(text: $options.query, prompt: String(localized: "Name oder PID"))
                ProcessTableView(presentation: presentation, sort: options.sort, selection: $selection,
                                 onSort: { options.sort = options.sort.selecting($0) }, onToggle: { options.toggle($0) })
                    .focusable()
                    .focused($isTableFocused)
                    .focusEffectDisabled()
                    .terminatesOnDelete(candidate, using: flows)
            }
            .padding(InstrumentSpacing.page)
            ProcessActionBar(candidate: candidate,
                             disabledReason: selected?.foreignTerminationNote(currentUID: currentUID),
                             needsAdmin: selected?.includesForeignProcess(currentUID: currentUID) ?? false,
                             flows: flows)
        }
        .taskManagerFlows(flows)
        .measuresWhileVisible(start: {
            appModel.networkActivity.start(for: .taskManager)
            appModel.foreignProcessUsage.start(for: .processesTab)
        }, stop: {
            appModel.networkActivity.stop(for: .taskManager)
            appModel.foreignProcessUsage.stop(for: .processesTab)
        })
        .onChange(of: selection) { isTableFocused = true }
    }

    private var presentation: ProcessListPresentation {
        let model = appModel.taskManager
        return presentations.value(for: TableKey(measuredAt: model.frameDate, options: options)) {
            ProcessListPresenter.present(appModel.tableSnapshot, apps: WorkspaceRunningApplications.regularApps(),
                                         currentUID: getuid(), network: appModel.networkActivity.processRates,
                                         options: options)
        }
    }
}

extension AppModel {
    /// Stand der Tabellen „Prozesse“, „Details“ und „Benutzer“: der letzte Takt, ergänzt um CPU und Speicher fremder
    /// Prozesse aus `ps`.
    var tableSnapshot: TaskManagerSnapshot {
        taskManager.frame.snapshot.fillingForeignUsage(foreignProcessUsage.usage, currentUID: getuid())
    }
}
