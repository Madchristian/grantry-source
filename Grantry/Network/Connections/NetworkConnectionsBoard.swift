import GrantryCharts
import ManagerKit
import SwiftUI

/// Anordnung der Ansicht „Verbindungen“ (§3.13): links das Erreichbarkeitsradar mit dem Datenverkehr und darunter das
/// Detail des gewählten Sockets, rechts die Sockets nach Erreichbarkeit mit Filter. Zeigt nur fertige Stände
/// (`NetworkConnectionsPresentation`); Messung, Suche und Aktionen liegen bei `NetworkConnectionsView`.
struct NetworkConnectionsBoard<Detail: View, Empty: View>: View {
    let presentation: NetworkConnectionsPresentation
    let total: TrafficRate
    let history: [TrafficRate]
    @Binding var filter: NetworkConnectionFilter
    @Binding var query: String
    @Binding var selection: NetworkSocketRow.ID?
    /// Wessen Sockets sichtbar sind, etwa „alle Benutzer“.
    let visibility: String
    let detail: Detail
    /// Steht über der Tabelle, solange sie keine Zeile zeigt.
    let empty: Empty

    init(presentation: NetworkConnectionsPresentation, total: TrafficRate, history: [TrafficRate],
         filter: Binding<NetworkConnectionFilter>, query: Binding<String>, selection: Binding<NetworkSocketRow.ID?>,
         visibility: String,
         @ViewBuilder detail: () -> Detail, @ViewBuilder empty: () -> Empty = { EmptyView() }) {
        self.presentation = presentation
        self.total = total
        self.history = history
        _filter = filter
        _query = query
        _selection = selection
        self.visibility = visibility
        self.detail = detail()
        self.empty = empty()
    }

    var body: some View {
        // Bei 900 pt mit Seitenleiste steht das Radar über der Tabelle, statt dass die Ansicht waagrecht rollt (#486).
        InstrumentSideColumnLayout(side: .leading, width: InstrumentSize.columnRadar,
                                   mainMinimum: NetworkConnectionTableLayout.minimumWidth) {
            VStack(spacing: InstrumentSpacing.panel) {
                ReachPanel(presentation: presentation, total: total, history: history)
                detail.frame(maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
                // Im schmalen Fenster ohne Zusatz statt abgeschnitten (Bewertung Mangel 11), noch schmaler umbrochen.
                ViewThatFits(in: .horizontal) {
                    controls(count: String(localized: "\(presentation.shownCount) von \(presentation.counts.sockets) Sockets, \(visibility)"))
                    controls(count: String(localized: "\(presentation.shownCount) von \(presentation.counts.sockets)"))
                }
                TaskManagerTable {
                    NetworkConnectionTableHeader()
                } rows: {
                    NetworkConnectionTableRows(rows: presentation.rows, selection: $selection)
                }
                .frame(maxHeight: .infinity)
                .overlay {
                    if presentation.rows.isEmpty { empty }
                }
            }
        }
        .padding(InstrumentSpacing.page)
    }
}

extension NetworkConnectionsBoard {
    private func controls(count: String) -> some View {
        InstrumentControlRow {
            InstrumentSearchField(text: $query, prompt: String(localized: "Programm oder Port"))
            InstrumentSegments(String(localized: "Filter"), selection: $filter,
                               options: NetworkConnectionFilter.displayOrder.map { ($0, $0.title) })
        } trailing: {
            Text(verbatim: count)
                .font(InstrumentFont.body)
                .foregroundStyle(.instrumentSecondary)
                .monospacedDigit()
                .lineLimit(1)
                .help("nettop zeigt die Sockets aller Benutzer. Prozesse anderer Benutzer beendet Grantry nur über den Helper.")
        }
    }
}

private extension NetworkConnectionFilter {
    /// Reihenfolge im Umschalter: erst was erreichbar ist, dann die übrigen Sichten.
    static let displayOrder: [NetworkConnectionFilter] = [.all, .exposed, .listening, .connected, .udp, .loopback]
}

/// Erreichbarkeitsradar mit Peilkopf, darunter der Datenverkehr des Systems als Spiegel.
private struct ReachPanel: View {
    let presentation: NetworkConnectionsPresentation
    let total: TrafficRate
    let history: [TrafficRate]

    var body: some View {
        let echoes = Self.echoes(presentation.all)
        let network = echoes.count { $0.ring == .network }
        VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
            PeilHead(String(localized: "Erreichbarkeit"), detail: String(localized: "Wer diesen Mac erreichen kann"),
                     value: "\(network)", finding: network > 0)
            ReachRadar(echoes: echoes).frame(height: InstrumentSize.radar)
            TrafficMirror(rate: total, history: history)
        }
        .instrumentPanel()
    }

    /// Lauschende und gebundene Programme je Port auf dem Ring ihrer Erreichbarkeit.
    static func echoes(_ rows: [NetworkSocketRow]) -> [ReachRadar.Echo] {
        var seen = Set<String>()
        return rows.filter { !$0.isGone && $0.kind != .connected }.compactMap { row in
            let port = row.socket.local.port.map { ":\($0)" } ?? ""
            let ring: ReachRadar.Ring = switch row.reach {
            case .network: .network
            case .localNetwork: .localNetwork
            case .thisMac, .connected: .thisMac
            }
            let id = "\(row.title)\(port)\(ring.rawValue)"
            guard seen.insert(id).inserted else { return nil }
            return ReachRadar.Echo(id: id, label: "\(row.title) \(port)", ring: ring)
        }
    }
}

/// Leeres Detail, solange kein Socket gewählt ist.
struct NetworkConnectionNoSelection: View {
    var body: some View {
        VStack(spacing: InstrumentSpacing.group) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.largeTitle).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("Wähle einen Socket, um Adressen, Verkehr und Programm zu sehen.")
                .font(InstrumentFont.body)
                .foregroundStyle(.instrumentSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(InstrumentSpacing.empty)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .instrumentPanel(padding: 0)
    }
}

#if DEBUG
#Preview("Verbindungen") {
    @Previewable @State var filter = NetworkConnectionFilter.all
    @Previewable @State var query = ""
    @Previewable @State var selection: NetworkSocketRow.ID?
    let frame = NetworkConnectionsPreviewData.frame
    let presentation = NetworkConnectionsPresentation(frame: frame, filter: filter, query: "",
                                                      userName: NetworkConnectionsPreviewData.userName)
    NetworkConnectionsBoard(
        presentation: presentation, total: frame.report.total, history: frame.report.history, filter: $filter,
        query: $query, selection: $selection, visibility: "alle Benutzer"
    ) {
        if let row = presentation.row(withID: selection ?? presentation.rows.first?.id) {
            NetworkConnectionDetail(row: row, listener: nil, termination: nil, showListener: nil)
        } else {
            NetworkConnectionNoSelection()
        }
    }
    .frame(width: 1240, height: 780)
    .instrumentBackground()
}
#endif
