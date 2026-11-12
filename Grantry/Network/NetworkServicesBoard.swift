import GrantryCharts
import ManagerKit
import SwiftUI

/// Anordnung der Ansicht „Dienste“ im Lagebild (#366, docs/design/instrumententafel.md §3.13): Zählkacheln je
/// Erreichbarkeit, der Firewall-Hinweis, darüber Suche und Umschalter, darunter die Tabelle der lauschenden Dienste und
/// rechts das Detail des gewählten Dienstes. Zeigt nur fertige Stände (`NetworkServicesPresentation`); Scan, Auswahl aus
/// Benachrichtigungen und Aktionen liegen bei `NetworkView`.
struct NetworkServicesBoard<Detail: View, Empty: View, Menu: View>: View {
    let presentation: NetworkServicesPresentation
    let firewallHint: NetworkFirewallHint?
    let badges: (NetworkListenerRow) -> [RecordBadge]
    @Binding var filter: NetworkListenerFilter
    @Binding var query: String
    @Binding var selection: NetworkListener.ID?
    /// Sprung zur Sicherheitsprüfung aus dem Firewall-Hinweis; `nil` ohne Knopf (Bilder).
    let showSecurity: (() -> Void)?
    let detail: Detail
    /// Steht über der Tabelle, solange sie keine Zeile zeigt.
    let empty: Empty
    @ViewBuilder let contextMenu: (NetworkListenerRow) -> Menu

    init(presentation: NetworkServicesPresentation, firewallHint: NetworkFirewallHint?,
         badges: @escaping (NetworkListenerRow) -> [RecordBadge], filter: Binding<NetworkListenerFilter>,
         query: Binding<String>, selection: Binding<NetworkListener.ID?>, showSecurity: (() -> Void)?,
         @ViewBuilder detail: () -> Detail, @ViewBuilder empty: () -> Empty = { EmptyView() },
         @ViewBuilder contextMenu: @escaping (NetworkListenerRow) -> Menu) {
        self.presentation = presentation
        self.firewallHint = firewallHint
        self.badges = badges
        _filter = filter
        _query = query
        _selection = selection
        self.showSecurity = showSecurity
        self.detail = detail()
        self.empty = empty()
        self.contextMenu = contextMenu
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            NetworkServiceTiles(counts: presentation.counts)
            if let firewallHint {
                FirewallNote(hint: firewallHint, exposedCount: presentation.ownExposedCount, showSecurity: showSecurity)
            }
            // Bei 900 pt mit Seitenleiste steht das Detail unter der Tabelle, statt den Namen zu stauchen (#486).
            InstrumentSideColumnLayout(side: .trailing, width: InstrumentSize.columnWide,
                                       mainMinimum: NetworkListenerTableLayout.minimumWidth) {
                VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
                    controls
                    TaskManagerTable {
                        NetworkListenerTableHeader(rows: presentation.rows)
                    } rows: {
                        NetworkListenerTableRows(rows: presentation.rows, badges: badges, selection: $selection,
                                                 contextMenu: contextMenu)
                    }
                    .frame(maxHeight: .infinity)
                    .overlay {
                        if presentation.rows.isEmpty { empty }
                    }
                }
                detail
                    .frame(maxHeight: .infinity)
            }
        }
        .padding(InstrumentSpacing.page)
    }

    private var controls: some View {
        HStack(spacing: InstrumentSpacing.panel) {
            InstrumentSearchField(text: $query, prompt: String(localized: "Dienste durchsuchen"))
            InstrumentSegments(String(localized: "Erreichbarkeit"), selection: $filter.onlyExposed,
                               options: [(false, String(localized: "Alle")),
                                         (true, String(localized: "Von außen erreichbar"))])
            Text(verbatim: String(localized: "\(presentation.rows.count) von \(presentation.counts.total)"))
                .font(InstrumentFont.body)
                .foregroundStyle(.instrumentSecondary)
                .monospacedDigit()
                .lineLimit(1)
                .help(presentation.showsSystemServices
                      ? String(localized: "Angezeigt von allen Diensten, Systemdienste eingeschlossen")
                      : String(localized: "Angezeigt von allen Diensten ohne Systemdienste"))
            Spacer(minLength: 0)
        }
    }
}

/// Zählkacheln (§3.6): aus dem Netz erreichbar und mit Hinweis werden erst mit einem Treffer bernsteinfarben.
private struct NetworkServiceTiles: View {
    let counts: NetworkServicesPresentation.Counts

    var body: some View {
        HStack(spacing: InstrumentSpacing.panel) {
            tile(String(localized: "Aus dem Netz erreichbar"), counts.exposed,
                 detail: counts.exposedSystem > 0
                     ? String(localized: "davon \(counts.exposedSystem) Systemdienste von macOS")
                     : String(localized: "Andere Geräte können sich verbinden"),
                 tone: counts.exposed > 0 ? .finding : .neutral)
            tile(String(localized: "Nur auf diesem Mac"), counts.thisMac,
                 detail: String(localized: "Nur über Loopback erreichbar"), tone: .positive)
            tile(String(localized: "Mit Hinweis"), counts.withFindings,
                 detail: String(localized: "Grantry empfiehlt eine Prüfung"),
                 tone: counts.withFindings > 0 ? .finding : .neutral)
        }
    }

    private func tile(_ title: String, _ count: Int, detail: String, tone: StatusTone) -> some View {
        CountTile(title: title, value: count, detail: detail, tone: tone,
                  fraction: counts.total > 0 ? Double(count) / Double(counts.total) : 0)
    }
}

/// Firewall-Hinweis (§3.12): aus mit Befund-Punkt und Sprung zur Sicherheitsprüfung, an als Hinweis. Die Zahl ist
/// dieselbe wie in der Zustandszeile (`NetworkServicesPresentation.ownExposedCount`).
private struct FirewallNote: View {
    let hint: NetworkFirewallHint
    let exposedCount: Int
    let showSecurity: (() -> Void)?

    @Environment(\.self) private var environment

    var body: some View {
        switch hint {
        case .firewallOff:
            HStack(spacing: InstrumentSpacing.group) {
                InstrumentNote(exposedCount == 1
                    ? String(localized: "Firewall ist aus: 1 Dienst nimmt Verbindungen aus dem Netz an.")
                    : String(localized: "Firewall ist aus: \(exposedCount) Dienste nehmen Verbindungen aus dem Netz an."),
                    kind: .finding)
                if let showSecurity {
                    Button("Zur Sicherheitsprüfung", action: showSecurity)
                        .buttonStyle(.plain)
                        .font(InstrumentFont.body)
                        .foregroundStyle(environment.statusTextColor(.info))
                        .fixedSize()
                }
            }
        case .firewallOn:
            InstrumentNote(String(
                localized: "Die Firewall ist an. Signierte Apps können je nach Einstellung trotzdem eingehende Verbindungen annehmen."
            ))
        }
    }
}
