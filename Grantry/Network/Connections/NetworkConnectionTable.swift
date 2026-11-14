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

/// Spalten hinter „Programm“ und „Art“: nach Erreichbarkeit beide Endpunkte, nach Land die Gegenstelle und ihr Verkehr.
extension NetworkConnectionGrouping {
    var endpointColumns: [String] {
        switch self {
        case .reach: [String(localized: "Lokal"), String(localized: "Gegenstelle")]
        case .country: [String(localized: "Gegenstelle"), String(localized: "Verkehr")]
        }
    }
}

struct NetworkConnectionTableHeader: View {
    var grouping = NetworkConnectionGrouping.reach

    var body: some View {
        HStack(alignment: .bottom, spacing: NetworkConnectionTableLayout.spacing) {
            header(String(localized: "Programm"))
                .padding(.leading, InstrumentSize.rowIconTall + InstrumentSpacing.group)
            header(String(localized: "Art")).frame(width: NetworkConnectionTableLayout.kindWidth)
            ForEach(grouping.endpointColumns, id: \.self) { title in
                header(title).frame(minWidth: NetworkConnectionTableLayout.endpointMinWidth, maxWidth: .infinity)
            }
        }
        .padding(.horizontal, InstrumentSpacing.bar)
        .padding(.vertical, InstrumentSpacing.cell)
    }

    private func header(_ title: String) -> some View {
        HeatColumnHeader(title: title, value: "", heat: nil, sortAscending: nil, alignment: .leading)
            .padding(.horizontal, InstrumentSpacing.inline)
    }
}

/// Die Zeilen in Abschnitten nach Erreichbarkeit oder Land, ohne Scrollbereich (auch für Bilder: `ImageRenderer`
/// zeichnet keinen `ScrollView`-Inhalt).
struct NetworkConnectionTableRows: View {
    let sections: [NetworkConnectionSection]
    var grouping = NetworkConnectionGrouping.reach
    @Binding var selection: NetworkSocketRow.ID?

    var body: some View {
        LazyVStack(spacing: InstrumentSpacing.stack) {
            ForEach(sections) { section in
                InstrumentSectionHeader(title: section.title, count: section.openCount,
                                        tone: section.tone.statusTone, finding: section.isFinding,
                                        detail: grouping == .country ? section.rateText : nil)
                    .accessibilityLabel(Text(verbatim: section.accessibilityLabel(for: grouping)))
                ForEach(section.rows) { row in
                    NetworkConnectionRowView(row: row, isSelected: selection == row.id, grouping: grouping)
                        .selectableRow { selection = row.id }
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
    var grouping = NetworkConnectionGrouping.reach

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
                Text(verbatim: "\(row.protocolText) \(kindTitle)").font(InstrumentFont.body)
                Text(verbatim: row.isGone ? String(localized: "geschlossen") : row.stateText)
                    .font(InstrumentFont.label.monospaced())
                    .foregroundStyle(tone == .neutral ? AnyShapeStyle(.instrumentSecondary) : AnyShapeStyle(environment.statusTextColor(tone)))
            }
            .lineLimit(1)
            .padding(.horizontal, InstrumentSpacing.inline)
            .frame(width: NetworkConnectionTableLayout.kindWidth, alignment: .leading)
            switch grouping {
            case .reach:
                endpoint(row.localText, isMuted: row.isGone)
                endpoint(row.remoteText, note: row.region?.title(),
                         isMuted: row.isGone || row.socket.remote.address == nil)
            case .country:
                endpoint(row.remoteText, isMuted: row.isGone)
                endpoint(NetworkConnectionTexts.traffic(row.rate), note: TrafficFormat.bytes(row.transferred.total),
                         isMuted: row.isGone || row.rate.total == 0)
            }
        }
        .padding(.horizontal, InstrumentSpacing.group)
        .padding(.vertical, InstrumentSpacing.inline)
        .instrumentRowBackground(isSelected: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
        .accessibilityIdentifier("connectionRow")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Nach Land die Richtung der Verbindung, soweit ablesbar („TCP ausgehend“), sonst die Art des Sockets.
    private var kindTitle: String {
        guard grouping == .country, let direction = row.direction else { return SocketStateStyle.title(for: row.kind) }
        return direction.displayName.lowercased()
    }

    /// Nach Erreichbarkeit mit der Gruppe, nach Land mit dem Verkehr; Land und Richtung nennt die Zeile selbst.
    private var accessibilityLabel: String {
        switch grouping {
        case .reach: "\(row.accessibilityLabel), \(row.reach.title)"
        case .country:
            "\(row.accessibilityLabel), empfängt \(TrafficFormat.rate(row.rate.download)), sendet \(TrafficFormat.rate(row.rate.upload))"
        }
    }

    /// - Parameter note: zweite Zeile darunter, etwa das Land der Gegenstelle.
    private func endpoint(_ text: String, note: String? = nil, isMuted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: text)
                .font(InstrumentFont.code)
                .foregroundStyle(isMuted ? .instrumentSecondary : .primary)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if let note {
                Text(verbatim: note).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, InstrumentSpacing.inline)
        .frame(minWidth: NetworkConnectionTableLayout.endpointMinWidth, maxWidth: .infinity, alignment: .leading)
    }
}
