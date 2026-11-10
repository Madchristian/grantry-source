import GrantryCharts
import ManagerKit
import SwiftUI

enum NetworkConnectionTableLayout {
    static let spacing = InstrumentSpacing.inline
    static let kindWidth: CGFloat = 130
    static let endpointMinWidth: CGFloat = 150
    /// Schmalste Tabelle samt Innenrand: Programm lesbar, Art und beide Endpunkte in Mindestbreite.
    static let minimumWidth: CGFloat = 120 + kindWidth + 2 * endpointMinWidth + 3 * spacing + 2 * InstrumentSpacing.bar
}

/// Ton je Socket (§2.5): lauschende und gebundene nach Erreichbarkeit, Verbindungsauf- und -abbau auffällig,
/// bestehende Verbindungen neutral.
enum SocketStateStyle {
    static func tone(for row: NetworkSocketRow) -> StatusTone {
        guard !row.isGone else { return .neutral }
        return switch row.kind {
        case .listening, .bound: row.reach.tone.statusTone
        case .connected:
            row.socket.transport == .tcp && row.socket.state != "Established" ? .finding : .neutral
        }
    }

    /// Art des Sockets in einem Wort.
    static func title(for kind: SocketKind) -> String {
        switch kind {
        case .listening: String(localized: "lauscht")
        case .bound: String(localized: "gebunden")
        case .connected: String(localized: "verbunden")
        }
    }
}

struct NetworkConnectionTableHeader: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: NetworkConnectionTableLayout.spacing) {
            header(String(localized: "Programm"))
                .padding(.leading, InstrumentSize.rowIconTall + InstrumentSpacing.group)
            header(String(localized: "Art")).frame(width: NetworkConnectionTableLayout.kindWidth)
            header(String(localized: "Lokal"))
                .frame(minWidth: NetworkConnectionTableLayout.endpointMinWidth, maxWidth: .infinity)
            header(String(localized: "Gegenstelle"))
                .frame(minWidth: NetworkConnectionTableLayout.endpointMinWidth, maxWidth: .infinity)
        }
        .padding(.horizontal, InstrumentSpacing.bar)
        .padding(.vertical, InstrumentSpacing.cell)
    }

    private func header(_ title: String) -> some View {
        HeatColumnHeader(title: title, value: "", heat: nil, sortAscending: nil, alignment: .leading)
            .padding(.horizontal, InstrumentSpacing.inline)
    }
}

/// Die Zeilen in Abschnitten nach Erreichbarkeit, ohne Scrollbereich (auch für Bilder: `ImageRenderer` zeichnet keinen
/// `ScrollView`-Inhalt).
struct NetworkConnectionTableRows: View {
    let rows: [NetworkSocketRow]
    @Binding var selection: NetworkSocketRow.ID?

    var body: some View {
        LazyVStack(spacing: InstrumentSpacing.stack) {
            ForEach(SocketReach.allCases, id: \.self) { reach in
                let members = rows.filter { $0.reach == reach }
                if !members.isEmpty {
                    InstrumentSectionHeader(title: reach.title, count: members.count { !$0.isGone },
                                            tone: reach.tone.statusTone, finding: reach == .network)
                    ForEach(members) { row in
                        NetworkConnectionRowView(row: row, isSelected: selection == row.id)
                            .selectableRow { selection = row.id }
                    }
                }
            }
        }
        .padding(.horizontal, InstrumentSpacing.group)
        .padding(.vertical, InstrumentSpacing.item)
    }
}

struct NetworkConnectionRowView: View {
    let row: NetworkSocketRow
    let isSelected: Bool

    @Environment(\.self) private var environment

    var body: some View {
        let tone = SocketStateStyle.tone(for: row)
        HStack(spacing: NetworkConnectionTableLayout.spacing) {
            HStack(spacing: InstrumentSpacing.group) {
                // Geschlossen: Symbol abgeblendet, Texte in der Sekundärfarbe – nicht die ganze Zeile, sonst fiele die
                // Schrift unter 4,5 : 1.
                ProgramIcon(program: row.program, title: row.title, size: InstrumentSize.rowIconTall)
                    .opacity(row.isGone ? InstrumentOpacity.gone : 1)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: row.title).font(InstrumentFont.body).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(row.isGone ? .instrumentSecondary : .primary)
                    Text(verbatim: NetworkConnectionTexts.owner(of: row))
                        .font(InstrumentFont.label.monospacedDigit())
                        .foregroundStyle(.instrumentSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, InstrumentSpacing.inline)
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "\(row.protocolText) \(SocketStateStyle.title(for: row.kind))").font(InstrumentFont.body)
                Text(verbatim: row.isGone ? String(localized: "geschlossen") : row.stateText)
                    .font(InstrumentFont.label.monospaced())
                    .foregroundStyle(tone == .neutral ? AnyShapeStyle(.instrumentSecondary) : AnyShapeStyle(environment.statusTextColor(tone)))
            }
            .lineLimit(1)
            .padding(.horizontal, InstrumentSpacing.inline)
            .frame(width: NetworkConnectionTableLayout.kindWidth, alignment: .leading)
            endpoint(row.localText, isMuted: row.isGone)
            endpoint(row.remoteText, isMuted: row.isGone || row.socket.remote.address == nil)
        }
        .padding(.horizontal, InstrumentSpacing.group)
        .padding(.vertical, InstrumentSpacing.inline)
        .instrumentRowBackground(isSelected: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(row.accessibilityLabel), \(row.reach.title)"))
        .accessibilityIdentifier("connectionRow")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func endpoint(_ text: String, isMuted: Bool) -> some View {
        Text(verbatim: text)
            .font(InstrumentFont.code)
            .foregroundStyle(isMuted ? .instrumentSecondary : .primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .padding(.horizontal, InstrumentSpacing.inline)
            .frame(minWidth: NetworkConnectionTableLayout.endpointMinWidth, maxWidth: .infinity, alignment: .leading)
    }
}

/// Texte der Ansicht „Verbindungen“, die Tabelle und Detail teilen.
enum NetworkConnectionTexts {
    /// „PID 4820 · christian“; ohne bekannten Benutzer nur die PID.
    static func owner(of row: NetworkSocketRow) -> String {
        (["PID \(row.pid)"] + [row.user].compactMap(\.self)).joined(separator: " · ")
    }
}
