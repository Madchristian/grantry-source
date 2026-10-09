import ManagerKit
import SwiftUI

/// Bereich „Apps“ (Spec v3 §5): Liste links, Detail rechts; Suche, Filter und Sortierung in der Symbolleiste, die
/// Scan-Abdeckung der App-Quelle (z. B. unlesbarer Ordner, #142) über der Liste. Liest aus `AppModel.presentation` und `AppModel.appDetails`.
struct AppsView: View {
    let appModel: AppModel
    @Environment(MainWindowModel.self) private var window
    @State private var selection: InstalledApp.ID?

    private var appDetails: AppDetailsModel { appModel.appDetails }

    var body: some View {
        @Bindable var window = window
        ListDetailSplit {
            VStack(spacing: 0) {
                SectionCoverageHeader(coverage: coverage)
                list
            }
        } detail: {
            ActionResultContainer(actions: appModel.actions, context: .apps) {
                detail
            }
        }
        .searchable(
            text: Binding(get: { window.query(for: .apps) }, set: { window.searchText[.apps] = $0 }),
            placement: .toolbar, prompt: Text("Apps durchsuchen")
        )
        .toolbar {
            ToolbarItem { AppFilterMenu(filter: $window.appFilter) }
        }
        // Verschwindet die ausgewählte App (entfernt), gilt „keine Auswahl“ – auch, falls sie später wiederkommt.
        .onChange(of: selectedApp == nil) { _, isGone in if isGone { selection = nil } }
        .onAppear { appDetails.refreshUsage() }
        .onChange(of: window.appFilter.sort, initial: true) { _, sort in appDetails.setLoadsAll(sort != .name) }
        .onDisappear { appDetails.setLoadsAll(false) }
    }

    // MARK: - Liste

    private var coverage: AreaCoverage? { appModel.presentation?.coverage[.apps] }

    private var list: some View {
        let rows = rows
        let badges = appModel.presentation?.badges
        return ScrollViewReader { proxy in
            List(rows, selection: $selection) { row in
                InstalledAppRowView(row: row, badges: badges?.badges(for: row.id) ?? [],
                                    isLoading: appDetails.details[row.id] == nil,
                                    isRiskAccepted: appModel.monitoring.acceptedAppIDs.contains(row.id))
                    .id(row.id)
                    .onAppear { appDetails.request(row.id) }
                    .onDisappear { appDetails.withdraw(row.id) }
                    .contextMenu { AppContextMenu(app: row.app, window: window) }
            }
            .focusedValue(\.removeSelectedApp, removeAction)
            .onChange(of: window.focusedRecordID, initial: true) { _, recordID in
                guard let recordID else { return }
                selection = recordID
                proxy.scrollTo(recordID, anchor: .center)
            }
        }
        .overlay {
            if rows.isEmpty { emptyState }
        }
    }

    private var rows: [InstalledAppRow] {
        guard let presentation = appModel.presentation else { return [] }
        return AppInventoryPresenter.rows(
            presentation.installedApps, details: appDetails.details, severity: presentation.highestSeverity(for:),
            query: window.query(for: .apps), filter: window.appFilter, now: .now
        )
    }

    @ViewBuilder
    private var emptyState: some View {
        if appModel.presentation == nil {
            ContentUnavailableView("Noch keine Daten", systemImage: "magnifyingglass",
                                   description: Text("Der erste Scan ist noch nicht abgeschlossen."))
        } else if !window.query(for: .apps).isEmpty {
            ContentUnavailableView.search(text: window.query(for: .apps))
        } else if window.appFilter == AppListFilter(onlyFlagged: true, sort: window.appFilter.sort) {
            CoverageAwareUnavailableView(title: "Nichts Auffälliges", systemImage: "checkmark.shield",
                                         description: "Keine App hat einen Prüfhinweis.", coverage: coverage)
        } else if window.appFilter.isActive {
            NoFilterMatchesView(description: "Keine App passt zu den gewählten Filtern.") {
                window.appFilter = AppListFilter(sort: window.appFilter.sort)
            }
        } else {
            CoverageAwareUnavailableView(title: "Keine Apps", systemImage: MainSection.apps.systemImage,
                                         description: "In den Programme-Ordnern wurde keine App gefunden.", coverage: coverage)
        }
    }

    // MARK: - Detail

    /// Ausgewählte App – unabhängig vom Filter, solange sie im aktuellen Snapshot existiert.
    /// ⌘⌫ nur mit Auswahl und Fokus in der Liste, nie während ein Blatt offen ist.
    private var removeAction: RemoveAppAction? {
        guard !window.presentsSheet, let app = selectedApp else { return nil }
        return RemoveAppAction { [window] in window.requestRemoval(of: app) }
    }

    private var selectedApp: InstalledApp? {
        appModel.presentation?.installedApps.first { $0.id == selection }
    }

    @ViewBuilder
    private var detail: some View {
        if let presentation = appModel.presentation, let app = selectedApp {
            InstalledAppDetailView(
                detail: InstalledAppDetail(
                    app: app, details: appDetails.details[app.id],
                    findings: appModel.monitoring.appFindings.filter { $0.recordID == app.id },
                    links: presentation.links(for: app), now: .now
                ),
                presentation: presentation, actions: appModel.actions,
                isRiskAccepted: appModel.monitoring.acceptedAppIDs.contains(app.id),
                acceptanceError: appModel.monitoring.riskAcceptanceError,
                setRiskAccepted: { try await appModel.setAppRiskAccepted($0, appID: app.id) }
            )
            .id(app.id)
            .onAppear { appDetails.request(app.id) }
            .onDisappear { appDetails.withdraw(app.id) }
        } else {
            NoSelectionView(hint: "Wähle links eine App, um Details zu sehen.")
        }
    }
}

/// Kontextmenü einer App in der Liste (Spec v3 §3, Einstiegspunkt 2).
private struct AppContextMenu: View {
    let app: InstalledApp
    let window: MainWindowModel

    var body: some View {
        Button("App entfernen …") { window.requestRemoval(of: app) }
        Button("Im Finder zeigen") { app.revealInFinder() }
        Button("Reste anzeigen") { window.requestRemoval(of: app, mode: .leftovers) }
    }
}
