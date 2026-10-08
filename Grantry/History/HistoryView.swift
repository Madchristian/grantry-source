import ManagerKit
import SwiftUI

/// Verlauf (Spec §6): Änderungen neueste zuerst, seitenweise nachgeladen; Filter nach Art, Änderungsart und Zeitraum;
/// „Wiederherstellen“ an Ereignissen mit Beleg (entfernte Autostart-Einträge, von Grantry geänderte
/// Agenten-Konfigurationen) sowie eine Liste „Wiederherstellbar“ für Belege ohne geladenes Ereignis (nach demselben
/// Filter). Filter und Zuordnung kommen aus dem Kit (`HistoryFilter`, `RestoreMatching`).
struct HistoryView: View {
    let appModel: AppModel
    @Environment(MainWindowModel.self) private var window
    @State private var pendingRestore: RestorableChange?

    private var history: HistoryModel { appModel.history }

    var body: some View {
        @Bindable var window = window
        // Kein eigener Takt: Zeilen aktualisieren ihre relativen Zeitangaben selbst, der Zeitraumfilter gilt ab dem
        // letzten Neuzeichnen.
        content(now: .now)
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
        let events = window.historyFilter.apply(history.events, now: now)
        let restorable = RestoreMatching.unmatchedRestorables(
            receipts: history.receipts, changes: history.agentChanges, matches: history.restorablesByEvent,
            filter: window.historyFilter, now: now
        )
        return List {
            if let result = appModel.actions.result(in: .history) {
                ActionResultBanner(result: result, dismiss: appModel.actions.dismissResult)
                    .listRowSeparator(.hidden)
            }
            if let error = history.loadError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
            if !restorable.isEmpty {
                Section("Wiederherstellbar") {
                    ForEach(restorable) { entry in
                        RestorableChangeRow(change: entry, actions: appModel.actions) { pendingRestore = entry }
                    }
                }
            }
            Section {
                ForEach(events) { event in
                    HistoryEventRow(event: event, restorable: history.restorablesByEvent[event.id], actions: appModel.actions) {
                        pendingRestore = $0
                    }
                }
                if history.hasMore && window.historyFilter.canMatchEvents(olderThan: history.events.last, now: now) {
                    LoadMoreRow(isLoading: history.isLoading) { Task { await history.loadMore() } }
                }
            } header: {
                if !restorable.isEmpty { Text("Änderungen") }
            }
        }
        .overlay {
            if events.isEmpty && restorable.isEmpty && !history.hasMore {
                emptyState
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if window.historyFilter.isActive && !history.events.isEmpty {
            NoFilterMatchesView(description: "Keine Änderung passt zu den gewählten Filtern.") {
                window.historyFilter = HistoryFilter()
            }
        } else if !history.isLoading {
            let isIncomplete = appModel.monitoring.snapshot?.hasIncompleteCoverage ?? false
            ContentUnavailableView("Keine Änderungen", systemImage: "clock",
                                   description: Text(verbatim: isIncomplete
                                       ? CoverageTexts.noChanges(hasIncompleteCoverage: true)
                                       : String(localized: "Seit dem ersten Scan hat sich nichts geändert.")))
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
