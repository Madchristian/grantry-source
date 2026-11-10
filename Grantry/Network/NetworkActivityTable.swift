import AppKit
import GrantryCharts
import ManagerKit
import SwiftUI

enum NetworkActivityTableLayout {
    static let spacing = InstrumentSpacing.inline
    static let rateWidth: CGFloat = 96
    static let totalWidth: CGFloat = 84
    static let connectionsWidth: CGFloat = 100
    static let signingWidth: CGFloat = 132
    /// Einzug der Verbindungen unter ihrem Prozess.
    static let childIndent = InstrumentSize.disclosure + InstrumentSpacing.group
}

/// Tabelle der Netzwerkaktivität als Panel (§3.7, #366): Prozesse mit aufklappbaren Verbindungen, Raten mit Hitze in den
/// Farben von Empfangen und Gesendet, Spalten per Klick auf den Kopf sortierbar (außer Signatur). Kontextmenü nur lesend:
/// „Im Finder zeigen“, „Ziel kopieren“, „Zum Netzwerkdienst“. Eigene Zeilen statt `Table`: Nur so lassen sich Zellen
/// einfärben.
struct NetworkActivityTable: View {
    let rows: [NetworkActivityRow]
    @Binding var sortOrder: [KeyPathComparator<NetworkActivityRow>]
    /// Lauscher des aktuellen Snapshots („Zum Netzwerkdienst“).
    let listeners: [NetworkListener]
    let showListener: (NetworkListener) -> Void
    @State private var selection: NetworkActivityRow.ID?
    @State private var expanded: Set<NetworkActivityRow.ID> = []

    var body: some View {
        let summary = NetworkActivityColumnSummary(rows: rows)
        TaskManagerTable {
            NetworkActivityTableHeader(count: rows.count, summary: summary, sortOrder: $sortOrder)
        } rows: {
            NetworkActivityTableRows(rows: rows, summary: summary, expanded: $expanded, selection: $selection,
                                     listeners: listeners, showListener: showListener)
        }
    }
}

struct NetworkActivityTableHeader: View {
    let count: Int
    let summary: NetworkActivityColumnSummary
    @Binding var sortOrder: [KeyPathComparator<NetworkActivityRow>]

    var body: some View {
        HStack(alignment: .bottom, spacing: NetworkActivityTableLayout.spacing) {
            header(.name, value: count == 1 ? String(localized: "1 Programm") : String(localized: "\(count) Programme"),
                   alignment: .leading)
                .padding(.leading, NetworkActivityTableLayout.childIndent)
                .frame(maxWidth: .infinity)
            header(.download, value: TrafficFormat.rate(summary.rate.download), hue: .received)
                .frame(width: NetworkActivityTableLayout.rateWidth)
            header(.upload, value: TrafficFormat.rate(summary.rate.upload), hue: .sent)
                .frame(width: NetworkActivityTableLayout.rateWidth)
            header(.total, value: TrafficFormat.bytes(summary.bytes)).frame(width: NetworkActivityTableLayout.totalWidth)
            header(.connections, value: "\(summary.connections)")
                .frame(width: NetworkActivityTableLayout.connectionsWidth)
            HeatColumnHeader(title: String(localized: "Signatur"), value: "", heat: nil, sortAscending: nil,
                             alignment: .leading)
                .padding(.horizontal, InstrumentSpacing.group)
                .frame(width: NetworkActivityTableLayout.signingWidth)
        }
        .padding(.horizontal, InstrumentSpacing.bar)
        .padding(.vertical, InstrumentSpacing.cell)
    }

    private func header(_ column: NetworkActivityColumn, value: String, alignment: HorizontalAlignment = .trailing,
                        hue: InstrumentHue = .received) -> some View {
        let isSorted = NetworkActivityColumn(sortedBy: sortOrder) == column
        let ascending = isSorted ? sortOrder.first?.order == .forward : nil
        return Button {
            sortOrder = NetworkActivityColumn.sortOrder(selecting: column, current: sortOrder)
        } label: {
            HeatColumnHeader(title: column.title, value: value, heat: nil, sortAscending: ascending,
                             alignment: alignment, hue: hue)
                .padding(.horizontal, InstrumentSpacing.group)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Nach \(column.title) sortieren")
        // ax-value: Knopf, behält seine Rolle und damit den Wert
        .accessibilityValue(Text(verbatim: ascending.map {
            "\(value), \($0 ? String(localized: "aufsteigend sortiert") : String(localized: "absteigend sortiert"))"
        } ?? value))
    }
}

extension NetworkActivityColumn {
    var title: String {
        switch self {
        case .name: String(localized: "Name")
        case .download: String(localized: "Empfangen")
        case .upload: String(localized: "Gesendet")
        case .total: String(localized: "Gesamt")
        case .connections: String(localized: "Verbindungen")
        }
    }
}

/// Die Zeilen ohne Scrollbereich (auch für Bilder: `ImageRenderer` zeichnet keinen `ScrollView`-Inhalt). Umsortiert wird
/// ohne Animation (Leistungsregeln aus #369).
struct NetworkActivityTableRows: View {
    let rows: [NetworkActivityRow]
    let summary: NetworkActivityColumnSummary
    @Binding var expanded: Set<NetworkActivityRow.ID>
    @Binding var selection: NetworkActivityRow.ID?
    let listeners: [NetworkListener]
    let showListener: (NetworkListener) -> Void

    var body: some View {
        LazyVStack(spacing: InstrumentSpacing.stack) {
            ForEach(visibleRows) { row in
                NetworkActivityRowView(row: row, summary: summary, isSelected: selection == row.id,
                                       isExpanded: expanded.contains(row.id)) {
                    toggle(row)
                }
                .selectableRow { selection = row.id }
                .contextMenu {
                    NetworkActivityContextMenu(row: row,
                                               listener: NetworkActivityPresenter.listener(for: row, in: listeners),
                                               showListener: showListener)
                }
            }
        }
        .padding(.horizontal, InstrumentSpacing.group)
        .padding(.vertical, InstrumentSpacing.item)
    }

    /// Prozesse, unter aufgeklappten ihre Verbindungen.
    private var visibleRows: [NetworkActivityRow] {
        rows.flatMap { row in [row] + (expanded.contains(row.id) ? row.children ?? [] : []) }
    }

    private func toggle(_ row: NetworkActivityRow) {
        if expanded.remove(row.id) == nil { expanded.insert(row.id) }
    }
}

struct NetworkActivityRowView: View {
    let row: NetworkActivityRow
    let summary: NetworkActivityColumnSummary
    let isSelected: Bool
    let isExpanded: Bool
    let onToggle: () -> Void

    private var isConnection: Bool {
        if case .connection = row.kind { true } else { false }
    }

    var body: some View {
        HStack(spacing: NetworkActivityTableLayout.spacing) {
            NetworkActivityNameCell(row: row, isExpanded: isExpanded, onToggle: onToggle)
                .padding(.leading, isConnection ? NetworkActivityTableLayout.childIndent : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
            HeatCell(TrafficFormat.rate(row.downloadRate), heat: summary.heat(row.downloadRate, of: \.download),
                     hue: .received)
                .frame(width: NetworkActivityTableLayout.rateWidth)
            HeatCell(TrafficFormat.rate(row.uploadRate), heat: summary.heat(row.uploadRate, of: \.upload), hue: .sent)
                .frame(width: NetworkActivityTableLayout.rateWidth)
            value(TrafficFormat.bytes(row.totalBytes), width: NetworkActivityTableLayout.totalWidth)
            value(row.compactDetail, width: NetworkActivityTableLayout.connectionsWidth)
                .help(Text(verbatim: row.detail))
            ZStack(alignment: .leading) {
                if let signing = row.signing {
                    SigningLabel(signing: signing, style: .compact).font(InstrumentFont.body).lineLimit(1)
                }
            }
            .padding(.horizontal, InstrumentSpacing.group)
            .frame(width: NetworkActivityTableLayout.signingWidth, alignment: .leading)
        }
        .padding(.horizontal, InstrumentSpacing.group)
        .instrumentRowBackground(isSelected: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: row.accessibilityLabel))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .disclosureAction(isExpandable: row.children != nil, isExpanded: isExpanded, toggle: onToggle)
    }

    private func value(_ text: String, width: CGFloat) -> some View {
        Text(verbatim: text)
            .font(InstrumentFont.numeric)
            .foregroundStyle(.instrumentSecondary)
            .lineLimit(1)
            .padding(.horizontal, InstrumentSpacing.group)
            .frame(width: width, alignment: .trailing)
    }
}

/// Name einer Zeile: Pfeil zum Aufklappen, App-Symbol bzw. Verbindungssymbol, Titel, „neu“ bzw. „beendet“; beendete
/// Prozesse und geschlossene Verbindungen mit abgeblendetem Symbol und Text in Sekundärfarbe.
struct NetworkActivityNameCell: View {
    let row: NetworkActivityRow
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: InstrumentSpacing.group) {
            disclosure
            Group {
                switch row.kind {
                case .process(_, let program):
                    ProgramIcon(program: program, title: row.title, size: InstrumentSize.rowIcon)
                case .connection:
                    Image(systemName: "arrow.left.arrow.right")
                        .font(InstrumentFont.rowIcon)
                        .foregroundStyle(.instrumentSecondary)
                        .frame(width: InstrumentSize.rowIcon, height: InstrumentSize.rowIcon)
                        .accessibilityHidden(true)
                }
            }
            .opacity(row.isGone ? InstrumentOpacity.gone : 1)
            Text(verbatim: row.title)
                .font(InstrumentFont.body)
                .foregroundStyle(row.isGone ? .instrumentSecondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if row.isNew {
                StatusChip(String(localized: "neu"), tone: .info, isSmall: true)
            }
            if row.isGone {
                StatusChip(row.kind.isProcess ? String(localized: "beendet") : String(localized: "geschlossen"),
                           tone: .neutral, isSmall: true)
            }
        }
        .padding(.vertical, InstrumentSpacing.inline)
        .help(row.executablePath ?? row.target ?? row.title)
    }

    @ViewBuilder
    private var disclosure: some View {
        if row.children != nil {
            Button(action: onToggle) {
                Image(systemName: "chevron.right")
                    .font(InstrumentFont.label.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: InstrumentSize.disclosure, height: InstrumentSize.disclosure)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.instrumentSecondary)
            .accessibilityLabel(isExpanded ? "Zuklappen" : "Aufklappen")
        } else if row.kind.isProcess {
            Color.clear.frame(width: InstrumentSize.disclosure, height: InstrumentSize.disclosure)
        }
    }
}

/// Nur lesende Aktionen zu einer Zeile.
struct NetworkActivityContextMenu: View {
    let row: NetworkActivityRow
    let listener: NetworkListener?
    let showListener: (NetworkListener) -> Void

    var body: some View {
        if let program = row.program {
            Button("Im Finder zeigen") { program.revealInFinder() }
        }
        if let target = row.target {
            Button("Ziel kopieren") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(target, forType: .string)
            }
        }
        if let listener {
            Button("Zum Netzwerkdienst") { showListener(listener) }
        }
    }
}

private extension NetworkActivityRow.Kind {
    var isProcess: Bool {
        if case .process = self { true } else { false }
    }
}
