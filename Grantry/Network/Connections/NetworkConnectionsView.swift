import GrantryCharts
import ManagerKit
import SwiftUI

/// Ansicht „Verbindungen“ im Bereich Netzwerk, Gestaltung „Lagebild“ (docs/design/instrumententafel.md §3.13): alle
/// offenen Sockets aus derselben nettop-Messung wie „Aktivität“ – lauschend, gebunden und verbunden –, oben die
/// Zustandszeile, darunter Erreichbarkeitsradar, Detail und die Sockets nach Erreichbarkeit oder Land
/// (`NetworkConnectionsBoard`). Misst nur, solange sie sichtbar ist, und schlägt keine Hostnamen nach
/// (`NetworkActivityModel.Consumer.connectionsView`). Das Land einer Gegenstelle kommt aus der Tabelle im App-Paket
/// (`RemoteRegionResolver`, #630) – ohne Netzverkehr. Ein lauschender oder gebundener Socket eines gescannten Dienstes
/// bietet „Prozess beenden …“ mit denselben Rückfragen und Sperren wie „Dienste“.
struct NetworkConnectionsView: View {
    /// Einmal je Start geöffnet (Speicherabbild): Die Länderdaten ändern sich erst mit einem neuen App-Paket.
    static let regions = RemoteRegionResolver(bundle: .main)

    let appModel: AppModel
    let prerequisites: PrerequisitesModel
    @Environment(MainWindowModel.self) private var window
    @State private var filter = NetworkConnectionFilter.all
    @State private var grouping = NetworkConnectionGrouping.reach
    @State private var query = ""
    /// Klickfilter aus Bogenfächer (#633) und Radar (#640); nicht gespeichert, gelten bis zum Verlassen der Ansicht.
    @State private var picks = NetworkPickFilters()
    @State private var selection: NetworkSocketRow.ID?

    private var model: NetworkActivityModel { appModel.networkActivity }
    private var network: NetworkOverview { appModel.presentation?.network ?? .empty }

    var body: some View {
        let presentation = NetworkConnectionsPresentation(frame: model.frame, filter: filter, query: query,
                                                          destination: picks.destination, echo: picks.echo,
                                                          regions: Self.regions)
        let verdict = presentation.verdict(firewallOn: firewallOn)
        VStack(spacing: 0) {
            if let notice = model.notice {
                NetworkActivityNoticeBar(notice: notice, retry: model.retry)
                Divider()
            }
            StatusLine(verdict: verdict.title, finding: verdict.level != .calm, items: verdict.statusItems,
                       facts: verdict.facts)
                .padding([.horizontal, .top], InstrumentSpacing.page)
            NetworkConnectionsBoard(
                presentation: presentation, total: model.frame.report.total, history: model.frame.report.history,
                filter: $filter, grouping: $grouping, query: $query, picks: $picks,
                selection: $selection,
                visibility: String(localized: "alle Benutzer"), countryDataDate: Self.regions.dataDate
            ) {
                ActionResultContainer(actions: appModel.actions, context: .network) {
                    detail(presentation.row(withID: selection))
                }
            } empty: {
                emptyState(presentation)
            }
        }
        .instrumentBackground()
        .measuresWhileVisible(start: { model.start(for: .connectionsView) }, stop: { model.stop(for: .connectionsView) })
        .modifier(ListenerTerminationSupport(appModel: appModel))
    }

    @ViewBuilder
    private func detail(_ row: NetworkSocketRow?) -> some View {
        if let row {
            let listener = row.listener(in: network.listeners)
            NetworkConnectionDetail(
                row: row, listener: listener,
                termination: listener.map {
                    ListenerTerminationControls(for: $0, appModel: appModel, helperState: prerequisites.helperState)
                },
                showListener: { window.show($0) }
            )
            .id(row.id)
        } else {
            NetworkConnectionNoSelection()
        }
    }

    @ViewBuilder
    private func emptyState(_ presentation: NetworkConnectionsPresentation) -> some View {
        if model.status.failure != nil {
            ContentUnavailableView("Keine Messwerte", systemImage: "network.slash",
                                   description: Text("Ohne nettop zeigt Grantry keine Verbindungen."))
        } else if presentation.all.isEmpty {
            ProgressView("Messe Sockets …")
        } else if let notice = presentation.pickNotice() {
            NetworkPickFilterEmpty(notice: notice) { picks.clear(notice.kind) }
        } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            NoFilterMatchesView(description: "Kein Socket passt zum gewählten Filter.") { filter = .all }
        }
    }

    /// Firewall laut letztem Scan; `nil`, solange kein Hinweis vorliegt.
    private var firewallOn: Bool? {
        switch network.firewallHint {
        case .firewallOn: true
        case .firewallOff: false
        case nil: nil
        }
    }
}
