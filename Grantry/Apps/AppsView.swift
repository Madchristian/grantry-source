import GrantryCharts
import ManagerKit
import SwiftUI

/// Apps im Lagebild (Spec v3 §5; LB-2.5, #542, Entwurf LB-2.1): Zustandszeile mit Urteil, Scan-Abdeckung der App-Quelle
/// (z. B. unlesbarer Ordner, #142), links die Auswahlliste, rechts das Detail; Suche, Filter und Sortierung in der
/// Symbolleiste. Liest aus `AppModel.presentation` und `AppModel.appDetails`; zeichnet nur bei Scan, Angaben, Suche,
/// Filter, Auswahl und Aktion.
struct AppsView: View {
    let appModel: AppModel
    @Environment(MainWindowModel.self) private var window
    @State private var selection: InstalledApp.ID?

    private var appDetails: AppDetailsModel { appModel.appDetails }

    var body: some View {
        @Bindable var window = window
        let presentation = appModel.presentation
        InventoryBoard(head: AppsBoardMapping.head(presentation, acceptedCount: appModel.monitoring.acceptedAppIDs.count,
                                                   scannedAt: appModel.monitoring.snapshot?.takenAt)) {
            VStack(alignment: .leading, spacing: 0) {
                if let coverage { AreaCoverageBar(coverage: coverage) }
                FlaggedNoticeBar(breakdown: presentation?.metrics.flagged, area: .apps,
                                 filter: window.appFilter.findings)
            }
        } list: {
            list
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
        // Sprung aus einem anderen Bereich wählt die App; ins Bild rollt sie die Liste.
        .onChange(of: window.focusedRecordID, initial: true) { _, recordID in
            if let recordID { selection = recordID }
        }
        .onAppear { appDetails.refreshUsage() }
        .onChange(of: window.appFilter.sort, initial: true) { _, sort in appDetails.setLoadsAll(sort != .name) }
        .onDisappear { appDetails.setLoadsAll(false) }
    }

    // MARK: - Liste

    private var coverage: AreaCoverage? { appModel.presentation?.coverage[.apps] }

    @ViewBuilder
    private var list: some View {
        let rows = rows
        if let presentation = appModel.presentation, !rows.isEmpty {
            let apps = Dictionary(rows.map { ($0.id, $0.app) }, uniquingKeysWith: { first, _ in first })
            let accepted = appModel.monitoring.acceptedAppIDs
            InstrumentList(String(localized: "Apps"), count: "\(rows.count)",
                           sections: AppsBoardMapping.sections(rows, sort: window.appFilter.sort) { row in
                               AppsBoardMapping.item(row, badges: presentation.badges.badges(for: row.id),
                                                     isLoading: appDetails.details[row.id] == nil,
                                                     isRiskAccepted: accepted.contains(row.id))
                           },
                           selection: $selection) { item in
                if let app = apps[item.id] { AppListIcon(app: app, appDetails: appDetails) }
            } contextMenu: { id in
                if let app = apps[id] { AppContextMenu(app: app, window: window) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AppsBoardMapping.listIdentifier)
            .focusedValue(\.removeSelectedApp, removeAction)
        } else {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .instrumentPanel()
        }
    }

    private var rows: [InstalledAppRow] {
        guard let presentation = appModel.presentation else { return [] }
        return AppInventoryPresenter.rows(
            presentation.installedApps, details: appDetails.details, severity: presentation.highestSeverity(for:),
            query: window.query(for: .apps), filter: window.appFilter, now: .now
        )
    }

    /// Leerzustand im Panel (Spec §11.1 e): noch kein Scan, keine Treffer, nichts Auffälliges, keine Apps – ohne
    /// Entwarnung bei Lücken.
    @ViewBuilder
    private var emptyState: some View {
        if appModel.presentation == nil {
            ContentUnavailableView("Noch keine Daten", systemImage: "magnifyingglass",
                                   description: Text("Der erste Scan ist noch nicht abgeschlossen."))
        } else if !window.query(for: .apps).isEmpty {
            ContentUnavailableView.search(text: window.query(for: .apps))
        } else if window.appFilter.findings.isActive,
                  window.appFilter == AppListFilter(findings: window.appFilter.findings, sort: window.appFilter.sort) {
            CoverageAwareUnavailableView(title: "Nichts Auffälliges", systemImage: "checkmark.shield",
                                         description: window.appFilter.findings.emptyDescription, coverage: coverage)
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
                    links: presentation.links(for: app),
                    extensions: presentation.extensions.owned(byAppAt: app.path), now: .now
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
            InstrumentEmptyState(symbol: "hand.raised", title: String(localized: "Nichts gewählt"),
                                 message: String(localized: "Wähle links eine App, um Details und Aktionen zu sehen."))
                .instrumentPanel()
        }
    }
}

/// Symbol einer Zeile der App-Liste. Lädt Größe und Nutzung der App, solange die Zeile gezeichnet ist: Die Liste ist
/// lazy, das Symbol erscheint und verschwindet mit seiner Zeile (wie zuvor die Zeile der nativen Liste).
private struct AppListIcon: View {
    let app: InstalledApp
    let appDetails: AppDetailsModel

    var body: some View {
        AppIconView(app: app.identity, size: InstrumentSize.rowIconTall)
            .onAppear { appDetails.request(app.id) }
            .onDisappear { appDetails.withdraw(app.id) }
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
