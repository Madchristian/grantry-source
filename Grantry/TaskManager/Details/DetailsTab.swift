import Darwin
import GrantryCharts
import ManagerKit
import SwiftUI

/// Tab „Details“ (Spec 2026-11-06 §2): alle Prozesse flach aus dem `TaskManagerModel`, durchsuchbar nach Name, PID oder
/// Benutzer; Spaltenwahl bleibt über Neustarts erhalten. CPU und Speicher fremder Prozesse kommen wie im Tab „Prozesse“
/// aus `ps` (`ForeignProcessUsageModel`, nur solange sichtbar). Beenden und Priorität wie dort: ⌫/⌥⌫, Leiste und
/// Kontextmenü über `TaskManagerFlows`, aber nur für eigene Prozesse – Prozesse anderer Benutzer beendet der Tab
/// „Prozesse“ über den Helper, die Leiste und das Kontextmenü verweisen darauf (`ProcessDetailRow.terminationNote`).
/// Optional als Prozessbaum (TM10, `ProcessTree`): Kinder eingerückt unter ihrem Elternprozess, Geschwister in der
/// gewählten Sortierung; ← klappt zu, → klappt auf. Ein Sprung aus dem Wachbuch (`MainWindowModel.focusedProcess`)
/// sucht nach der PID und wählt den Prozess.
struct DetailsTab: View {
    let appModel: AppModel
    @Environment(MainWindowModel.self) private var window
    @State private var options = ProcessDetailOptions()
    @State private var selection: String?
    @AppStorage("taskManager.details.columns") private var columns = ProcessDetailColumns.default
    @AppStorage("taskManager.details.tree") private var showsTree = false
    /// Zugeklappte Zeilen der Baumansicht; anfangs ist alles aufgeklappt.
    @State private var collapsed: Set<String> = []

    /// Symbolleiste, Bestätigungen und Messung hängen am Bedienzustand, nicht am Messtakt (#489): Je Takt wertet nur
    /// `DetailsContent` neu aus.
    var body: some View {
        let flows = TaskManagerFlows(appModel)
        DetailsContent(appModel: appModel, flows: flows, options: $options, selection: $selection, columns: $columns,
                       showsTree: showsTree, collapsed: $collapsed)
            .taskManagerFlows(flows)
            .toolbar { ProcessDetailToolbar(showsTree: $showsTree, columns: $columns) }
            .measuresWhileVisible(start: { appModel.foreignProcessUsage.start(for: .detailsTab) },
                                  stop: { appModel.foreignProcessUsage.stop(for: .detailsTab) })
            // Sprung aus dem Wachbuch: nach der PID suchen (dann steht der Prozess oben) und ihn wählen.
            .onChange(of: window.focusedProcess, initial: true) { _, key in
                guard let key else { return }
                options.query = String(key.pid)
                selection = key.id
                window.focusedProcess = nil
            }
    }
}

/// Suchfeld, Tabelle und Aktionsleiste von „Details“; der Teil des Tabs, der je Messtakt neu ausgewertet wird.
private struct DetailsContent: View {
    let appModel: AppModel
    let flows: TaskManagerFlows
    @Binding var options: ProcessDetailOptions
    @Binding var selection: String?
    @Binding var columns: ProcessDetailColumns
    let showsTree: Bool
    @Binding var collapsed: Set<String>
    /// Zeilen je Takt und Bedienzustand (#478): `ps` und ein Klick auf eine Zeile bauen sie nicht neu.
    @State private var presentations = PresentationCache<TableKey<ProcessDetailOptions>, ProcessDetailPresentation>()
    @FocusState private var isTableFocused: Bool

    var body: some View {
        let presentation = presentation
        let lines = showsTree ? ProcessTree.lines(presentation.rows, collapsed: collapsed) : nil
        // Hinter einem zugeklappten Elternprozess verborgene Zeilen gelten nicht als ausgewählt: ⌫ und Leiste träfen
        // sonst einen Prozess, den niemand sieht.
        let selected = (lines?.map(\.row) ?? presentation.rows).first { $0.id == selection }
        VStack(spacing: 0) {
            InstrumentSearchField(text: $options.query, prompt: String(localized: "Name, PID oder Benutzer"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], InstrumentSpacing.page)
            ProcessDetailTableView(
                presentation: presentation, columns: columns, sort: options.sort, history: history,
                selection: $selection, onSort: { options.sort = options.sort.selecting($0) },
                onToggleColumn: { columns.toggle($0) },
                menu: { row in
                    ProcessDetailContextMenu(row: row, canTerminate: flows.canStart) { candidate, force in
                        selection = row.id
                        flows.terminate(candidate, force: force)
                    }
                },
                lines: lines,
                onToggleBranch: toggleBranch
            )
            .focusable()
            .focused($isTableFocused)
            .focusEffectDisabled()
            .terminatesOnDelete(selected?.terminationCandidate, using: flows)
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                guard showsTree, let selection else { return .ignored }
                if press.key == .leftArrow { collapsed.insert(selection) } else { collapsed.remove(selection) }
                return .handled
            }
            .padding(InstrumentSpacing.page)
            ProcessActionBar(candidate: selected?.terminationCandidate, disabledReason: selected?.terminationNote,
                             flows: flows)
        }
        .onChange(of: selection) { isTableFocused = true }
    }

    private func toggleBranch(_ id: String) {
        if collapsed.remove(id) == nil { collapsed.insert(id) }
    }

    private var presentation: ProcessDetailPresentation {
        presentations.value(for: TableKey(measuredAt: appModel.taskManager.frameDate, options: options)) {
            ProcessDetailPresenter.present(appModel.tableSnapshot, currentUID: getuid(), options: options,
                                           userName: UserNameCache.shared.name(for:))
        }
    }

    private var history: ChartHistory {
        ChartHistory(history: appModel.taskManager.frame.history, measuredAt: appModel.taskManager.frameDate)
    }
}
