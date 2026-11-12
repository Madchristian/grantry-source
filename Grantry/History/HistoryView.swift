import GrantryCharts
import ManagerKit
import SwiftUI

/// Verlauf im Lagebild (Spec §6; LB-3.3, #545, Entwurf LB-3.1): Zustandszeile, aktiver Filter als Zeile, Ergebnis einer
/// Aktion, darunter in einem Panel „Wiederherstellbar“ und die Änderungen nach Tag, neueste zuerst, seitenweise
/// nachgeladen. Filter und „Alle als gelesen markieren“ bleiben in der Symbolleiste. „Wiederherstellen“ an Ereignissen
/// mit Beleg (entfernte Autostart-Einträge, von Grantry geänderte Agenten-Konfigurationen) und an Belegen ohne geladenes
/// Ereignis (nach demselben Filter). Filter und Zuordnung kommen aus dem Kit (`HistoryFilter`, `RestoreMatching`).
struct HistoryView: View {
    let appModel: AppModel
    @Environment(MainWindowModel.self) private var window
    @State private var pendingRestore: RestorableChange?

    private var history: HistoryModel { appModel.history }

    var body: some View {
        @Bindable var window = window
        // Ein Minutentakt für relative Zeiten, Tagesköpfe und den Zeitraumfilter (bisher ein Takt je Zeile).
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
        .toolbar {
            ToolbarItem {
                HistoryFilterMenu(filter: $window.historyFilter)
            }
            ToolbarItem {
                Button("Alle als gelesen markieren", systemImage: "checkmark.circle") {
                    Task { await appModel.markAllRead() }
                }
                .disabled(appModel.monitoring.unreadCount == 0)
                .help("Alle als gelesen markieren")
            }
        }
        // Neu laden bei neuen Events, geändertem Gelesen-Zustand und nach Aktionen (Belege).
        .task(id: ReloadTrigger(state: appModel.monitoring, result: appModel.actions.lastResult)) {
            await history.reload()
        }
        .actionConfirmation(for: $pendingRestore, confirmation: { ActionConfirmation.restore($0) }) { entry in
            Task { await appModel.actions.restore(entry, context: .history) }
        }
    }

    private func content(now: Date) -> some View {
        let filter = window.historyFilter
        let events = filter.apply(history.events, now: now)
        let restorable = RestoreMatching.unmatchedRestorables(
            receipts: history.receipts, changes: history.agentChanges, matches: history.restorablesByEvent,
            filter: filter, now: now
        )
        let sections = HistoryBoardMapping.sections(events: events, restorable: restorable, now: now,
                                                    entry: entry, restorableEntry: { entry($0, now: now) })
        return VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            let head = HistoryBoardMapping.head(verdict(matchingCount: events.count, now: now))
            StatusLine(verdict: head.verdict, shield: head.shield, items: head.items, facts: head.facts)
            if let text = HistoryBoardMapping.filterText(filter) {
                ActiveFilterLine(text) { window.historyFilter = HistoryFilter() }
            }
            if let result = appModel.actions.result(in: .history) {
                ActionResultBanner(result: result, dismiss: appModel.actions.dismissResult)
            }
            if let error = history.loadError {
                InstrumentNote(error, kind: .critical)
            }
            if !sections.isEmpty {
                HistoryList(sections: sections, focusedID: window.focusedRecordID,
                            loadMore: loadMore(filter: filter, now: now),
                            restore: { pendingRestore = restorableChange(for: $0, in: restorable) },
                            copy: CommandClipboard.copy) {
                    Task { await history.loadMore() }
                }
            } else if let state = filter.emptyState(loaded: history.events, hasRows: false, hasMore: history.hasMore,
                                                    isLoading: history.isLoading, now: now) {
                emptyState(state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .instrumentPanel()
            }
        }
        .padding(InstrumentSpacing.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .instrumentBackground()
    }

    // MARK: - Zustandszeile

    private func verdict(matchingCount: Int, now: Date) -> HistoryVerdict {
        let unmatched = RestoreMatching.unmatchedRestorables(
            receipts: history.receipts, changes: history.agentChanges, matches: history.restorablesByEvent,
            filter: HistoryFilter(), now: now
        )
        let incomplete = appModel.presentation?.coverage.incomplete ?? []
        return HistoryVerdict(events: history.events, hasMore: history.hasMore,
                              unreadCount: appModel.monitoring.unreadCount,
                              restorableCount: history.restorablesByEvent.count + unmatched.count,
                              filter: window.historyFilter, matchingCount: matchingCount,
                              missingSources: incomplete.reduce(0) { $0 + max($1.gaps.count, 1) },
                              isLoading: history.isLoading, loadError: history.loadError)
    }

    // MARK: - Zeilen

    private func entry(_ event: HistoryEvent) -> HistoryEntry {
        HistoryBoardMapping.entry(
            event, badges: appModel.presentation?.badges.badges(for: event.event.subject.recordID) ?? [],
            restore: history.restorablesByEvent[event.id].map(restoreState)
        )
    }

    private func entry(_ change: RestorableChange, now: Date) -> HistoryEntry {
        HistoryBoardMapping.entry(change, restore: restoreState(change), now: now)
    }

    private func restoreState(_ change: RestorableChange) -> HistoryEntry.Restore {
        HistoryBoardMapping.restore(change, runningRecordID: appModel.actions.runningRecordID,
                                    canStart: appModel.actions.canStart)
    }

    /// Beleg zur Zeile: am Ereignis über `restorablesByEvent`, sonst unter „Wiederherstellbar“.
    private func restorableChange(for entryID: String, in unmatched: [RestorableChange]) -> RestorableChange? {
        if let id = UUID(uuidString: entryID), let change = history.restorablesByEvent[id] { return change }
        return unmatched.first { HistoryBoardMapping.restorableEntryID($0) == entryID }
    }

    private func loadMore(filter: HistoryFilter, now: Date) -> HistoryLoadMore {
        guard filter.mayFindMoreEvents(hasMore: history.hasMore, olderThan: history.events.last, now: now) else {
            return .hidden
        }
        return history.isLoading ? .loading : .available
    }

    // MARK: - Leerzustände

    @ViewBuilder
    private func emptyState(_ state: HistoryEmptyState) -> some View {
        switch state {
        case .noFilterMatches:
            NoFilterMatchesView(description: "Keine Änderung passt zu den gewählten Filtern.") {
                window.historyFilter = HistoryFilter()
            }
        case .noChanges:
            let isIncomplete = appModel.monitoring.snapshot?.hasIncompleteCoverage ?? false
            InstrumentEmptyState(symbol: "clock", title: String(localized: "Keine Änderungen"),
                                 message: isIncomplete
                                     ? CoverageTexts.noChanges(hasIncompleteCoverage: true)
                                     : String(localized: "Seit dem ersten Scan hat sich nichts geändert."))
        }
    }
}

/// Anlass zum Neuladen: neue oder gelesene Events, Ergebnis einer Aktion.
private struct ReloadTrigger: Equatable {
    let recentEvents: [HistoryEvent]
    let unreadCount: Int
    let result: ActionRunner.Result?

    init(state: MonitoringState, result: ActionRunner.Result?) {
        recentEvents = state.recentEvents
        unreadCount = state.unreadCount
        self.result = result
    }
}

/// Filtermenü des Verlaufs: Art, Änderungsart, Zeitraum.
private struct HistoryFilterMenu: View {
    @Binding var filter: HistoryFilter

    var body: some View {
        FilterMenu(isActive: filter.isActive, help: "Verlauf filtern", reset: { filter = HistoryFilter() }) {
            Picker("Art", selection: $filter.category) {
                ForEach(HistoryFilter.Category.allCases, id: \.self) { category in
                    Text(verbatim: category.displayName).tag(category)
                }
            }
            .pickerStyle(.inline)
            Picker("Änderung", selection: $filter.kind) {
                Text("Alle Änderungen").tag(ChangeEvent.Kind?.none)
                ForEach([ChangeEvent.Kind.added, .modified, .removed], id: \.self) { kind in
                    Text(verbatim: kind.displayName).tag(Optional(kind))
                }
            }
            .pickerStyle(.inline)
            Picker("Zeitraum", selection: $filter.period) {
                ForEach(HistoryFilter.Period.allCases, id: \.self) { period in
                    Text(verbatim: period.displayName).tag(period)
                }
            }
            .pickerStyle(.inline)
        }
    }
}
