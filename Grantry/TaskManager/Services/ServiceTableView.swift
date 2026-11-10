import GrantryCharts
import ManagerKit
import SwiftUI

/// Inhalt des Tabs „Dienste“ (Spec 2026-11-06 §6, §4): oben je Zustand eine Zählkachel mit Spur,
/// darunter die Dienste des gewählten Bereichs mit Zustand, PID, letztem Exit-Code, Domäne und Verknüpfung zum
/// Autostart-Eintrag. Zeigt nur die `ServiceListPresentation`; Lesen und Steuern liegen beim `ServicesTab`.
struct ServiceListView: View {
    let presentation: ServiceListPresentation
    @Binding var selection: String?
    /// Suche nach Label oder PID; `nil` ohne Suchfeld (Vorschau, Bilder).
    var query: Binding<String>?
    let onShowAutostart: (AutostartItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            ServiceSummary(presentation: presentation)
            if let query {
                InstrumentSearchField(text: query, prompt: String(localized: "Label oder PID"))
            }
            ForEach(presentation.failures, id: \.self) { failure in
                ServiceFailureNote(text: failure)
            }
            TaskManagerTable {
                ServiceTableHeader(presentation: presentation)
            } rows: {
                ServiceTableRows(presentation: presentation, selection: $selection, onShowAutostart: onShowAutostart)
            }
        }
        .padding(InstrumentSpacing.page)
    }
}

/// Befund beim Lesen der Dienste: Symbol im Ton „auffällig“, Text sekundär.
private struct ServiceFailureNote: View {
    let text: String
    @Environment(\.self) private var environment

    var body: some View {
        Label {
            Text(verbatim: text).foregroundStyle(.instrumentSecondary)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(environment.statusColor(.finding))
        }
        .font(InstrumentFont.body)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Spalten Zustand, Dienst, PID, Letzter Exit, Domäne, Autostart. Bei 900 pt mit breiter Seitenleiste schrumpfen die
/// Nebenspalten, der Dienst bleibt lesbar (Bewertung 2026.11.9/1492, Mangel 6).
enum ServiceTableLayout {
    static let columns = InstrumentColumns([
        .fixed(116, minimum: 96), .name(minimum: 150), .fixed(84, minimum: 64), .fixed(104, minimum: 80),
        .fixed(96, minimum: 76), .fixed(120, minimum: 100),
    ], spacing: InstrumentSpacing.inline)
}

/// Zustandston je Zustand (§2.5): läuft in Ordnung, bereit blau, beendet neutral, Fehler kritisch.
extension ServiceState {
    var tone: StatusTone {
        switch self {
        case .running: .positive
        case .idle: .info
        case .ended: .neutral
        case .failed: .critical
        }
    }
}

struct ServiceSummary: View {
    let presentation: ServiceListPresentation

    var body: some View {
        let counts = presentation.stateCounts
        HStack(spacing: InstrumentSpacing.panel) {
            ForEach(ServiceState.allCases, id: \.self) { state in
                let count = counts[state] ?? 0
                let total = presentation.rows.count
                CountTile(title: state.title, value: count, tone: state.tone,
                          fraction: total > 0 ? Double(count) / Double(total) : 0)
            }
        }
    }
}

struct ServiceTableHeader: View {
    let presentation: ServiceListPresentation

    var body: some View {
        let count = presentation.rows.count
        InstrumentColumnsLayout(ServiceTableLayout.columns, alignment: .bottom) {
            header(String(localized: "Zustand"), value: "\(presentation.runningCount) aktiv", alignment: .leading)
            header(String(localized: "Dienst"), value: count == 1 ? "1 Dienst" : "\(count) Dienste", alignment: .leading)
                .padding(.leading, InstrumentSize.rowIcon + InstrumentSpacing.group)
            header(String(localized: "PID"), value: "", alignment: .trailing)
            header(String(localized: "Letzter Exit"), value: "", alignment: .trailing)
            header(String(localized: "Domäne"), value: "", alignment: .leading)
            header(String(localized: "Autostart"), value: "", alignment: .leading)
        }
        .padding(.horizontal, InstrumentSpacing.bar)
        .padding(.vertical, InstrumentSpacing.cell)
    }

    private func header(_ title: String, value: String, alignment: HorizontalAlignment) -> some View {
        HeatColumnHeader(title: title, value: value, heat: nil, sortAscending: nil, alignment: alignment)
            .padding(.horizontal, InstrumentSpacing.group)
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .bottom))
    }
}

/// Die Zeilen ohne Scrollbereich (auch für Snapshots: `ImageRenderer` zeichnet keinen `ScrollView`-Inhalt).
struct ServiceTableRows: View {
    let presentation: ServiceListPresentation
    @Binding var selection: String?
    let onShowAutostart: (AutostartItem) -> Void

    var body: some View {
        LazyVStack(spacing: InstrumentSpacing.stack) {
            ForEach(presentation.rows) { row in
                ServiceRowView(row: row, isSelected: selection == row.id, onShowAutostart: onShowAutostart)
                    .selectableRow { selection = row.id }
            }
        }
        .padding(.horizontal, InstrumentSpacing.group)
        .padding(.vertical, InstrumentSpacing.item)
    }
}

struct ServiceRowView: View {
    let row: ServiceRow
    let isSelected: Bool
    let onShowAutostart: (AutostartItem) -> Void
    @Environment(\.self) private var environment

    var body: some View {
        InstrumentColumnsLayout(ServiceTableLayout.columns) {
            StatusChip(row.state.title, tone: row.state.tone)
                .padding(.leading, InstrumentSpacing.group)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: InstrumentSpacing.group) {
                Image(systemName: icon)
                    .font(InstrumentFont.rowIcon)
                    .foregroundStyle(.instrumentSecondary)
                    .frame(width: InstrumentSize.rowIcon, height: InstrumentSize.rowIcon)
                    .background(Circle().fill(.quaternary))
                    .accessibilityHidden(true)
                Text(verbatim: row.label).lineLimit(1).truncationMode(.middle)
            }
            .padding(.leading, InstrumentSpacing.group)
            .frame(maxWidth: .infinity, alignment: .leading)
            cell(row.pidText, alignment: .trailing)
            Text(verbatim: row.exitText)
                .font(InstrumentFont.numeric)
                .foregroundStyle(row.state == .failed ? AnyShapeStyle(environment.statusTextColor(.critical))
                    : AnyShapeStyle(.instrumentSecondary))
                .lineLimit(1)
                .padding(.horizontal, InstrumentSpacing.group)
                .frame(maxWidth: .infinity, alignment: .trailing)
            cell(row.domain.name, alignment: .leading)
            link.padding(.horizontal, InstrumentSpacing.group).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, InstrumentSpacing.group)
        .padding(.vertical, InstrumentSpacing.inline)
        .instrumentRowBackground(isSelected: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("serviceRow")
        .accessibilityActions {
            if let item = row.autostartItem {
                Button(String(localized: "Im Autostart zeigen")) { onShowAutostart(item) }
            }
        }
    }

    private var icon: String {
        if row.isControllable { return "person.fill" }
        return row.domain.isSystem ? "lock.shield.fill" : "gearshape.2.fill"
    }

    private func cell(_ text: String, alignment: Alignment) -> some View {
        Text(verbatim: text)
            .font(InstrumentFont.numeric)
            .foregroundStyle(.instrumentSecondary)
            .lineLimit(1)
            .padding(.horizontal, InstrumentSpacing.group)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    @ViewBuilder
    private var link: some View {
        if let item = row.autostartItem {
            Button { onShowAutostart(item) } label: {
                Label("Autostart", systemImage: "arrow.up.forward.app").font(InstrumentFont.body)
            }
            .buttonStyle(.plain)
            .foregroundStyle(environment.statusTextColor(.info))
            .help(row.plistText ?? "")
        } else {
            Text(verbatim: "–").foregroundStyle(.instrumentSecondary)
        }
    }
}

/// Leiste unter der Tabelle: warum ein Dienst nicht steuerbar ist, „Im Autostart zeigen“, „Stoppen“, „Starten“.
struct ServiceActionBar: View {
    let row: ServiceRow?
    let canStart: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onShowAutostart: () -> Void

    var body: some View {
        HStack(spacing: InstrumentSpacing.cell) {
            if let note = row?.controlNote {
                Label(note, systemImage: "info.circle")
                    .foregroundStyle(.instrumentSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: InstrumentSpacing.group)
            Button("Im Autostart zeigen", action: onShowAutostart)
                .disabled(row?.autostartItem == nil)
            Button("Stoppen", action: onStop)
                .help("Mit SIGTERM beenden (launchctl kill)")
                .disabled(!canStart || row?.allows(.stop) != true)
            startButton
        }
        .controlSize(.regular)
        .instrumentBar()
    }

    /// Hervorgehoben nur, solange er wirkt (Bewertung 2026.11.7, Mangel 13).
    @ViewBuilder
    private var startButton: some View {
        let button = Button("Starten", action: onStart).help("Jetzt starten (launchctl kickstart)")
        if canStart && row?.allows(.start) == true {
            button.buttonStyle(.borderedProminent)
        } else {
            button.disabled(true)
        }
    }
}

#if DEBUG
#Preview("Dienste") {
    VStack(spacing: 0) {
        ServiceListView(presentation: ServiceListPreviewData.presentation(), selection: .constant(nil),
                        onShowAutostart: { _ in })
        ServiceActionBar(row: ServiceListPreviewData.rows.first, canStart: true, onStart: {}, onStop: {},
                         onShowAutostart: {})
    }
    .frame(width: 1180, height: 720)
    .instrumentBackground()
}
#endif
