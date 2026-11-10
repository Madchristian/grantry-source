import GrantryCharts
import ManagerKit
import SwiftUI

/// Ansicht „Dienste“ im Bereich Netzwerk (#128), Gestaltung „Lagebild“ (#366): oben die Zustandszeile, darunter
/// Zählkacheln, Firewall-Hinweis, Tabelle der lauschenden Dienste und rechts das Detail (`NetworkServicesBoard`).
/// Scan-Abdeckung (#142) und Hinweis auf Auffälliges stehen darüber, Filter in der Symbolleiste. Liest aus
/// `PresentationSnapshot.network`. „Prozess beenden …“ im Detail und Kontextmenü (Teil 2), Ergebnis über
/// `ActionResultContainer` (Kontext `.network`). Solange ein Dienst ausgewählt ist, misst `NetworkActivityModel` für die
/// Aktivität seines Programms im Detail.
struct NetworkView: View {
    let appModel: AppModel
    let prerequisites: PrerequisitesModel
    @Environment(MainWindowModel.self) private var window
    @State private var selection: NetworkListener.ID?
    /// Lauscher aus `window.focusedRecordID`, der noch nicht in der Liste steht (Sprung aus einer Benachrichtigung vor
    /// dem ersten Scan); wird ausgewählt, sobald er auftaucht (`applyPendingFocus(_:)`).
    @State private var pendingFocus: NetworkListener.ID?

    var body: some View {
        @Bindable var window = window
        let presentation = presentation
        let verdict = presentation.verdict(firewallHint: network.firewallHint)
        VStack(spacing: 0) {
            SectionCoverageHeader(coverage: coverage)
            FlaggedNoticeBar(breakdown: appModel.presentation?.metrics.flagged, area: .network,
                             filter: window.networkFindings)
            StatusLine(verdict: verdict.title, finding: verdict.hasFinding, items: verdict.statusItems,
                       facts: verdict.facts)
                .padding([.horizontal, .top], InstrumentSpacing.page)
            ScrollViewReader { proxy in
                NetworkServicesBoard(
                    presentation: presentation, firewallHint: network.firewallHint,
                    badges: { appModel.presentation?.badges.badges(for: $0.id) ?? [] },
                    filter: $window.networkFilter,
                    query: Binding(get: { window.query(for: .network) }, set: { window.searchText[.network] = $0 }),
                    selection: $selection, showSecurity: { window.show(.security) }
                ) {
                    ActionResultContainer(actions: appModel.actions, context: .network) {
                        detail
                    }
                } empty: {
                    emptyState
                } contextMenu: { row in
                    NetworkContextMenu(listener: row.listener, launchedBy: network.launchedBy(row.listener),
                                       window: window, termination: controls(for: row.listener),
                                       select: { selection = row.id })
                }
                .onChange(of: window.focusedRecordID, initial: true) { _, recordID in
                    pendingFocus = recordID
                    applyPendingFocus(proxy)
                }
                .onChange(of: network.listeners) { applyPendingFocus(proxy) }
            }
        }
        .instrumentBackground()
        .toolbar {
            ToolbarItem { NetworkFilterMenu(filter: $window.networkFilter) }
        }
        // Verschwindet der ausgewählte Lauscher (beendet), gilt „keine Auswahl“ – auch, falls er später wiederkommt.
        .onChange(of: selectedListener == nil) { _, isGone in if isGone { selection = nil } }
        .modifier(ListenerTerminationSupport(appModel: appModel))
    }

    private var network: NetworkOverview { appModel.presentation?.network ?? .empty }
    private var coverage: AreaCoverage? { appModel.presentation?.coverage[.network] }

    private var presentation: NetworkServicesPresentation {
        guard let snapshot = appModel.presentation else { return .empty }
        return NetworkServicesPresentation(listeners: snapshot.network.listeners, severity: snapshot.highestSeverity(for:),
                                           query: window.query(for: .network), filter: window.networkFilter)
    }

    /// Wählt den vorgemerkten Lauscher aus, sobald er in der Liste steht. Fehlt er in einem vorhandenen Snapshot, ist
    /// er inzwischen beendet: Die Vormerkung verfällt ohne Auswahl – eine ungültige Auswahl käme sonst still zurück,
    /// sobald der Lauscher wieder auftaucht. Ohne Snapshot (vor dem ersten Scan) bleibt sie bestehen.
    private func applyPendingFocus(_ proxy: ScrollViewProxy) {
        guard let recordID = pendingFocus else { return }
        if network.listeners.contains(where: { $0.id == recordID }) {
            pendingFocus = nil
            selection = recordID
            proxy.scrollTo(recordID, anchor: .center)
        } else if appModel.presentation != nil {
            pendingFocus = nil
            selection = nil
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if appModel.presentation == nil {
            ContentUnavailableView("Noch keine Daten", systemImage: "magnifyingglass",
                                   description: Text("Der erste Scan ist noch nicht abgeschlossen."))
        } else if !window.query(for: .network).isEmpty {
            ContentUnavailableView.search(text: window.query(for: .network))
        } else if window.networkFilter.isActive {
            NoFilterMatchesView(description: "Kein Dienst passt zu den gewählten Filtern.") {
                window.networkFilter = NetworkListenerFilter()
            }
        } else {
            CoverageAwareUnavailableView(
                title: "Keine Netzwerkdienste", systemImage: MainSection.network.systemImage,
                description: "Kein Programm nimmt Verbindungen an (Systemdienste ausgeblendet).", coverage: coverage
            )
        }
    }

    // MARK: - Detail

    /// Ausgewählter Lauscher – unabhängig vom Filter, solange er im aktuellen Snapshot existiert.
    private var selectedListener: NetworkListener? {
        network.listeners.first { $0.id == selection }
    }

    @ViewBuilder
    private var detail: some View {
        if let presentation = appModel.presentation, let listener = selectedListener {
            // Gemessen wird außerhalb von `.id(listener.id)`: Ein Wechsel zwischen Diensten setzt Messung und Summen
            // nicht zurück.
            VStack(spacing: 0) {
                NetworkListenerDetailView(
                    row: NetworkListenerRow(listener, severity: presentation.highestSeverity(for: listener.id)),
                    badges: presentation.badges.badges(for: listener.id),
                    findings: presentation.findings(for: listener.id),
                    launchedBy: network.launchedBy(listener),
                    termination: controls(for: listener),
                    activity: appModel.networkActivity
                )
                .id(listener.id)
            }
            .measuresWhileVisible(start: { appModel.networkActivity.start(for: .listenerDetail) },
                                  stop: { appModel.networkActivity.stop(for: .listenerDetail) })
        } else {
            NetworkListenerNoSelection()
        }
    }

    /// „Prozess beenden …“ für `listener`; gesperrt laut `ListenerTerminationPolicy`.
    private func controls(for listener: NetworkListener) -> ListenerTerminationControls {
        ListenerTerminationControls(for: listener, appModel: appModel, helperState: prerequisites.helperState)
    }
}

/// Kontextmenü eines Lauschers in der Liste.
private struct NetworkContextMenu: View {
    let listener: NetworkListener
    let launchedBy: AutostartItem?
    let window: MainWindowModel
    let termination: ListenerTerminationControls
    /// Wählt die Zeile aus, damit Hinweis, Ladeanzeige und SIGKILL-Angebot im Detail sichtbar sind.
    let select: () -> Void

    var body: some View {
        Button("Im Finder zeigen") { listener.revealInFinder() }
        if let launchedBy {
            Button("Zum Autostart-Eintrag") { window.show(launchedBy) }
        }
        Divider()
        Button("Prozess beenden …", role: .destructive) {
            select()
            termination.prepare(listener)
        }
        .disabled(!termination.canStart)
    }
}
