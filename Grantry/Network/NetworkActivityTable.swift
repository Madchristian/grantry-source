import AppKit
import ManagerKit
import SwiftUI

/// Tabelle der Netzwerkaktivität: Prozesse mit aufklappbaren Verbindungen, Spalten sortierbar (außer Signatur).
/// Kontextmenü nur lesend: „Im Finder zeigen“, „Ziel kopieren“, „Zum Netzwerkdienst“.
struct NetworkActivityTable: View {
    let rows: [NetworkActivityRow]
    @Binding var sortOrder: [KeyPathComparator<NetworkActivityRow>]
    /// Lauscher des aktuellen Snapshots („Zum Netzwerkdienst“).
    let listeners: [NetworkListener]
    let showListener: (NetworkListener) -> Void
    @State private var selection: Set<NetworkActivityRow.ID> = []

    var body: some View {
        Table(rows, children: \.children, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.title, comparator: .localizedStandard) { row in
                NetworkActivityNameCell(row: row)
            }
            .width(min: 140, ideal: 170)
            TableColumn(Text(verbatim: "↓/s").accessibilityLabel("Empfangen pro Sekunde"), value: \.downloadRate) { row in
                RateText(value: row.downloadRate)
            }
            .width(min: 56, ideal: 70)
            TableColumn(Text(verbatim: "↑/s").accessibilityLabel("Gesendet pro Sekunde"), value: \.uploadRate) { row in
                RateText(value: row.uploadRate)
            }
            .width(min: 56, ideal: 70)
            TableColumn("Gesamt", value: \.totalBytes) { row in
                Text(verbatim: TrafficFormat.bytes(row.totalBytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 56, ideal: 64)
            TableColumn("Verbindungen", value: \.connectionCount) { row in
                Text(verbatim: row.compactDetail)
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .help(Text(verbatim: row.detail))
            }
            .width(min: 64, ideal: 80)
            TableColumn("Signatur") { row in
                if let signing = row.signing {
                    SigningLabel(signing: signing, style: .compact).lineLimit(1)
                }
            }
            .width(min: 96, ideal: 140)
        }
        .contextMenu(forSelectionType: NetworkActivityRow.ID.self) { ids in
            if ids.count == 1, let id = ids.first, let row = NetworkActivityPresenter.row(withID: id, in: rows) {
                NetworkActivityContextMenu(
                    row: row, listener: NetworkActivityPresenter.listener(for: row, in: listeners), showListener: showListener
                )
            }
        }
    }
}

/// Name einer Zeile: App-Symbol bzw. Verbindungssymbol, Titel, „neu“-Marke; ausgegraut, wenn beendet bzw. geschlossen.
struct NetworkActivityNameCell: View {
    let row: NetworkActivityRow

    var body: some View {
        HStack(spacing: 6) {
            switch row.kind {
            case .process(_, let program):
                ProgramIcon(program: program, title: row.title, size: 16)
            case .connection:
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(verbatim: row.title)
                .lineLimit(1)
                .truncationMode(.middle)
            if row.isNew {
                Text("neu")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 4)
                    .background(PresentationTone.positive.color.opacity(0.2), in: Capsule())
            }
        }
        .opacity(row.isGone ? 0.45 : 1)
        .help(row.executablePath ?? row.target ?? row.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: row.accessibilityLabel))
    }
}

/// Rate in skalierter Einheit; ruhende Zeilen in Sekundärfarbe.
private struct RateText: View {
    let value: Double

    var body: some View {
        Text(verbatim: TrafficFormat.rate(value))
            .monospacedDigit()
            .foregroundStyle(value > 0 ? .primary : .secondary)
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
