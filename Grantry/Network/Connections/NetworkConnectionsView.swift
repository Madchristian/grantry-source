import GrantryCharts
import ManagerKit
import SwiftUI

/// Ansicht „Verbindungen“ im Bereich Netzwerk, Gestaltung „Lagebild“ (docs/design/instrumententafel.md §3.13): alle
/// offenen Sockets aus derselben nettop-Messung wie „Aktivität“ – lauschend, gebunden und verbunden –, oben die
/// Zustandszeile, darunter Erreichbarkeitsradar, Detail und die Sockets nach Erreichbarkeit (`NetworkConnectionsBoard`). Misst nur, solange sie sichtbar ist, und schlägt keine Hostnamen nach
/// (`NetworkActivityModel.Consumer.connectionsView`). Ein lauschender oder gebundener Socket eines gescannten Dienstes
/// bietet „Prozess beenden …“ mit denselben Rückfragen und Sperren wie „Dienste“.
struct NetworkConnectionsView: View {
    let appModel: AppModel
    let prerequisites: PrerequisitesModel
    @Environment(MainWindowModel.self) private var window
    @State private var filter = NetworkConnectionFilter.all
    @State private var query = ""
    @State private var selection: NetworkSocketRow.ID?

    private var model: NetworkActivityModel { appModel.networkActivity }
    private var network: NetworkOverview { appModel.presentation?.network ?? .empty }

    var body: some View {
        let presentation = NetworkConnectionsPresentation(frame: model.frame, filter: filter, query: query)
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
                filter: $filter, query: $query, selection: $selection, visibility: String(localized: "alle Benutzer")
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
