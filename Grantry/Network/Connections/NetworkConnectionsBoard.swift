import GrantryCharts
import ManagerKit
import SwiftUI

/// Anordnung der Ansicht „Verbindungen“ (§3.13): links die Grafik-Karte mit dem Datenverkehr und darunter das Detail
/// des gewählten Sockets, rechts die Sockets nach Erreichbarkeit oder die Verbindungen nach Land (#630) mit Filter. Die
/// Karte folgt der Gruppierung: nach Erreichbarkeit das Radar, nach Land der Bogenfächer „Ziele“ von diesem Mac zu den
/// Ländern. Beide Karten nehmen Klicks gleich an: ein Klick auf ein Ziel (#633) bzw. auf ein Echo des Radars (#640)
/// filtert die Tabelle darauf, der Filter steht als Chip bei den übrigen und lässt sich dort oder mit einem zweiten
/// Klick aufheben; beide Filter gelten zusammen. Beide Karten lassen sich auf die ganze Seite vergrößern
/// (`instrumentExpansion`). Zeigt nur fertige Stände
/// (`NetworkConnectionsPresentation`); Messung, Suche und Aktionen liegen bei `NetworkConnectionsView`.
struct NetworkConnectionsBoard<Detail: View, Empty: View>: View {
    let presentation: NetworkConnectionsPresentation
    let total: TrafficRate
    let history: [TrafficRate]
    @Binding var filter: NetworkConnectionFilter
    @Binding var grouping: NetworkConnectionGrouping
    @Binding var query: String
    /// Klickfilter aus Bogenfächer und Radar; gelten bis zum Verlassen der Ansicht.
    @Binding var picks: NetworkPickFilters
    @Binding var selection: NetworkSocketRow.ID?
    /// Wessen Sockets sichtbar sind, etwa „alle Benutzer“.
    let visibility: String
    /// Stand der Länderdaten; `nil`, wenn die Tabelle im App-Paket fehlt.
    let countryDataDate: DateComponents?
    let detail: Detail
    /// Steht über der Tabelle, solange sie keine Zeile zeigt.
    let empty: Empty
    /// Ob die Grafik-Karte (Radar bzw. Ziele) die ganze Seite füllt; gilt bis zum Verlassen der Ansicht.
    @State private var isRadarExpanded: Bool

    /// - Parameter isRadarExpanded: Anfangszustand der Grafik-Karte (vergrößert, für Bilder).
    init(presentation: NetworkConnectionsPresentation, total: TrafficRate, history: [TrafficRate],
         filter: Binding<NetworkConnectionFilter>, grouping: Binding<NetworkConnectionGrouping>,
         query: Binding<String>, picks: Binding<NetworkPickFilters>,
         selection: Binding<NetworkSocketRow.ID?>,
         visibility: String, countryDataDate: DateComponents?, isRadarExpanded: Bool = false,
         @ViewBuilder detail: () -> Detail, @ViewBuilder empty: () -> Empty = { EmptyView() }) {
        _isRadarExpanded = State(initialValue: isRadarExpanded)
        self.presentation = presentation
        self.total = total
        self.history = history
        _filter = filter
        _grouping = grouping
        _query = query
        _picks = picks
        _selection = selection
        self.visibility = visibility
        self.countryDataDate = countryDataDate
        self.detail = detail()
        self.empty = empty()
    }

    var body: some View {
        // Bei 900 pt mit Seitenleiste steht das Radar über der Tabelle, statt dass die Ansicht waagrecht rollt (#486).
        InstrumentSideColumnLayout(side: .leading, width: InstrumentSize.columnRadar,
                                   mainMinimum: NetworkConnectionTableLayout.minimumWidth) {
            VStack(spacing: InstrumentSpacing.panel) {
                graphPanel
                detail.frame(maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
                // Im schmalen Fenster ohne Zusatz statt abgeschnitten (Bewertung Mangel 11), noch schmaler umbrochen.
                ViewThatFits(in: .horizontal) {
                    controls(count: String(localized: "\(presentation.shownCount) von \(presentation.counts.sockets) Sockets, \(visibility)"))
                    controls(count: String(localized: "\(presentation.shownCount) von \(presentation.counts.sockets)"))
                }
                let sections = presentation.sections(by: grouping)
                TaskManagerTable {
                    NetworkConnectionTableHeader(grouping: grouping)
                } rows: {
                    NetworkConnectionTableRows(sections: sections, grouping: grouping, selection: $selection)
                }
                .frame(maxHeight: .infinity)
                .overlay {
                    if presentation.rows.isEmpty {
                        empty
                    } else if sections.isEmpty {
                        NetworkConnectionNoRemotes()
                    }
                }
                if grouping == .country { CountryDataNote(dataDate: countryDataDate) }
            }
        }
        .instrumentExpansion(isExpanded: isRadarExpanded) { graphPanel }
        .padding(InstrumentSpacing.page)
    }

    @ViewBuilder
    private var graphPanel: some View {
        switch grouping {
        case .reach:
            ReachPanel(echoes: presentation.reachEchoes(), filter: $picks.echo, total: total, history: history,
                       expansion: $isRadarExpanded)
        case .country:
            DestinationsPanel(destinations: presentation.destinations(),
                              selected: presentation.row(withID: selection)?.region, filter: $picks.destination,
                              total: total, history: history, expansion: $isRadarExpanded)
        }
    }
}

extension NetworkConnectionsBoard {
    private func controls(count: String) -> some View {
        InstrumentControlRow {
            InstrumentSearchField(text: $query, prompt: String(localized: "Programm oder Port"))
            InstrumentSegments(String(localized: "Filter"), selection: $filter,
                               options: NetworkConnectionFilter.displayOrder.map { ($0, $0.title) })
            InstrumentSegments(String(localized: "Gruppierung"), selection: $grouping,
                               options: NetworkConnectionGrouping.allCases.map { ($0, $0.title) })
            ForEach(picks.active, id: \.kind) { pick in
                InstrumentFilterChip(pick.filter.label, value: pick.filter.title(locale: .current),
                                     removeHint: pick.kind.removeHint) { picks.clear(pick.kind) }
            }
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

/// Erreichbarkeitsradar mit Peilkopf, darunter der Datenverkehr des Systems als Spiegel. Vergrößert (`expansion`) füllt
/// das Radar die Höhe der Seite und zeigt jedes Programm einzeln. Ein Klick auf ein Echo filtert die Tabelle auf das
/// Programm an diesem Port, derselbe Klick hebt den Filter auf; das Sammel-Echo filtert auf alle, die es vertritt
/// (#640). Zeichnet nur, wenn sich die Echos oder der Filter ändern – Raten gehen nicht ein (`ReachRadar` vergleicht
/// ohne den Rückruf).
private struct ReachPanel: View {
    let echoes: [NetworkReachEcho]
    @Binding var filter: NetworkEchoFilter?
    let total: TrafficRate
    let history: [TrafficRate]
    @Binding var expansion: Bool

    var body: some View {
        let network = echoes.count { $0.reach == .network }
        GraphPanel(total: total, history: history, isExpanded: expansion) {
            PeilHead(String(localized: "Erreichbarkeit"), detail: String(localized: "Wer diesen Mac erreichen kann"),
                     value: "\(network)", finding: network > 0, expansion: $expansion)
        } graph: {
            // Gleiche Echos geben das gleiche Radar: Ein älterer Rückruf sieht dieselben Echos.
            let echoes = echoes
            let filter = $filter
            ReachRadar(echoes: echoes.map(Self.echo), picked: filter.wrappedValue?.echoIDs(in: echoes) ?? [],
                       isExpanded: expansion,
                       pickHint: String(localized: "Filtert die Tabelle auf dieses Programm; ein zweiter Klick hebt den Filter auf")
            ) { ids in
                filter.wrappedValue = NetworkEchoFilter.picking(ids, in: echoes, current: filter.wrappedValue)
            }
            .equatable()
        }
    }

    /// Ein Echo auf dem Ring seiner Erreichbarkeit.
    static func echo(_ echo: NetworkReachEcho) -> ReachRadar.Echo {
        let ring: ReachRadar.Ring = switch echo.reach {
        case .network: .network
        case .localNetwork: .localNetwork
        case .thisMac, .connected: .thisMac
        }
        return ReachRadar.Echo(id: echo.id, label: echo.label, ring: ring)
    }
}

/// Bogenfächer „Ziele“ (#630): von diesem Mac zu den Ländern seiner offenen Verbindungen, dazu Gegenstellen ohne Land
/// (unbekannt, lokales Netz, dieser Mac). Die Linienstärke folgt der Zahl der Verbindungen, gestrichelt heißt nur
/// eingehend. Vergrößert zeigt jedes Ziel seine Programme. Ein Klick auf ein Ziel filtert die Tabelle darauf, derselbe
/// Klick hebt den Filter auf; der Sammel-Ast filtert auf alle Ziele, die er vertritt (#633). Zeichnet nur, wenn sich
/// die Zusammensetzung oder der Filter ändert – Raten gehen nicht ein (`ArcFan` vergleicht ohne den Rückruf).
private struct DestinationsPanel: View {
    let destinations: [NetworkDestination]
    /// Region der gewählten Verbindung; ihr Ziel ist im Fächer hervorgehoben.
    let selected: RemoteRegion?
    @Binding var filter: NetworkDestinationFilter?
    let total: TrafficRate
    let history: [TrafficRate]
    @Binding var expansion: Bool

    var body: some View {
        let title = String(localized: "Ziele")
        GraphPanel(total: total, history: history, isExpanded: expansion) {
            PeilHead(title, detail: String(localized: "Wohin dieser Mac verbindet, Länder"),
                     value: "\(destinations.count(where: \.isCountry))", expansion: $expansion)
        } graph: {
            // Gleiche Äste geben den gleichen Fächer: Ein älterer Rückruf sieht dieselben Ziele.
            let destinations = destinations
            let filter = $filter
            ArcFan(branches: destinations.map(Self.branch), originSymbol: "laptopcomputer", title: title,
                   selection: destinations.first { $0.region == selected }?.id,
                   picked: filter.wrappedValue?.destinationIDs(in: destinations) ?? [], isExpanded: expansion,
                   pickHint: String(localized: "Filtert die Tabelle auf dieses Ziel; ein zweiter Klick hebt den Filter auf")
            ) { ids in
                filter.wrappedValue = NetworkDestinationFilter.picking(ids, in: destinations, current: filter.wrappedValue)
            }
            .equatable()
            .overlay {
                if destinations.isEmpty {
                    Text("Keine offenen Verbindungen.").font(InstrumentFont.body).foregroundStyle(.instrumentSecondary)
                }
            }
        }
    }

    /// Länder blau, ohne Eintrag neutral, lokales Netz und dieser Mac grün; nur eingehend gestrichelt.
    static func branch(_ destination: NetworkDestination) -> ArcFan.Branch {
        let tone: StatusTone = switch destination.region {
        case .country: .info
        case .unknown: .neutral
        case .localNetwork, .thisMac: .positive
        }
        return ArcFan.Branch(
            id: destination.id, label: destination.title, weight: destination.connectionCount, tone: tone,
            isDashed: destination.isInboundOnly,
            leaves: destination.programs.map {
                ArcFan.Leaf(id: "\(destination.id)|\($0.title)", label: $0.title, weight: $0.connectionCount)
            },
            accessibilityValue: destination.accessibilityValue
        )
    }
}

/// Grafik-Karte der linken Spalte: Peilkopf, Grafik in fester Höhe bzw. vergrößert über die Höhe der Seite, darunter der
/// Datenverkehr des Systems als Spiegel.
private struct GraphPanel<Head: View, Graph: View>: View {
    let total: TrafficRate
    let history: [TrafficRate]
    let isExpanded: Bool
    @ViewBuilder let head: Head
    @ViewBuilder let graph: Graph

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
            head
            if isExpanded {
                graph.frame(maxHeight: .infinity)
            } else {
                graph.frame(height: InstrumentSize.radar)
            }
            TrafficMirror(rate: total, history: history)
        }
        .instrumentPanel()
    }
}

/// Unter der Tabelle „nach Land“: Stand der Länderdaten und was eine Länderangabe aussagt.
private struct CountryDataNote: View {
    let dataDate: DateComponents?

    var body: some View {
        if let stand = NetworkConnectionTexts.dataDate(dataDate) {
            InstrumentNote("\(stand). \(NetworkConnectionTexts.countryLimits)", kind: .info)
        } else {
            InstrumentNote(String(localized: "Die Länderdaten fehlen im App-Paket. Gegenstellen im Internet stehen deshalb unter „Land unbekannt“."),
                           kind: .finding)
        }
    }
}

/// Über der Tabelle „nach Land“, wenn Filter und Suche nur Sockets ohne Gegenstelle übrig lassen.
struct NetworkConnectionNoRemotes: View {
    var body: some View {
        ContentUnavailableView("Keine Verbindungen", systemImage: "globe",
                               description: Text("Lauschende und gebundene Sockets haben keine Gegenstelle und damit kein Land."))
    }
}

/// Über der Tabelle, wenn mit einem Klickfilter keine Zeile bleibt: Das Gefilterte ist verschwunden, oder Suche und
/// andere Filter lassen nichts davon übrig. Der Filter bleibt stehen, bis er aufgehoben wird (#633, #640).
struct NetworkPickFilterEmpty: View {
    let notice: NetworkPickNotice
    let reset: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(notice.title, systemImage: notice.symbol)
        } description: {
            Text(verbatim: notice.message).foregroundStyle(.instrumentSecondary)
        } actions: {
            Button(notice.resetTitle, action: reset)
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
    @Previewable @State var grouping = NetworkConnectionGrouping.country
    @Previewable @State var query = ""
    @Previewable @State var picks = NetworkPickFilters()
    @Previewable @State var selection: NetworkSocketRow.ID?
    let frame = NetworkConnectionsPreviewData.frame
    let presentation = NetworkConnectionsPresentation(frame: frame, filter: filter, query: "",
                                                      destination: picks.destination, echo: picks.echo,
                                                      userName: NetworkConnectionsPreviewData.userName,
                                                      regions: NetworkConnectionsPreviewData.regions)
    NetworkConnectionsBoard(
        presentation: presentation, total: frame.report.total, history: frame.report.history, filter: $filter,
        grouping: $grouping, query: $query, picks: $picks, selection: $selection,
        visibility: "alle Benutzer",
        countryDataDate: NetworkConnectionsPreviewData.regions.dataDate
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
