import GrantryCharts
import ManagerKit
import SwiftUI

/// Tabelle des Tabs „Prozesse“ wie Windows 11 (Spec §2, §4) als Panel (`TaskManagerTable`): Spaltenköpfe mit Gesamtwert
/// und LED-Leiste, Gruppen und
/// Apps aufklappbar, Heatmap je Zelle (`HeatCell`). Zeigt nur die `ProcessListPresentation`; Messung, Suche und
/// Beenden liegen beim `ProcessesTab`. Eigene Zeilen statt `Table`: Nur so lassen sich Zellen einfärben.
struct ProcessTableView: View {
    let presentation: ProcessListPresentation
    let sort: ProcessSort
    /// Wertspalten neben dem Namen.
    var columns = ProcessTableLayout.valueColumns
    @Binding var selection: String?
    let onSort: (ProcessColumn) -> Void
    let onToggle: (ProcessListRow) -> Void

    var body: some View {
        TaskManagerTable {
            ProcessTableHeader(presentation: presentation, sort: sort, columns: columns, onSort: onSort)
        } rows: {
            ProcessTableRows(presentation: presentation, columns: columns, selection: $selection, onToggle: onToggle)
        }
        .renderProbe("ProcessTableView")
    }
}

struct ProcessTableHeader: View {
    let presentation: ProcessListPresentation
    let sort: ProcessSort
    var columns = ProcessTableLayout.valueColumns
    let onSort: (ProcessColumn) -> Void

    var body: some View {
        InstrumentColumnsLayout(ProcessTableLayout.columns(values: columns.count), alignment: .bottom) {
            header(.name, alignment: .leading)
                .padding(.leading, ProcessTableLayout.nameIndent)
            ForEach(columns) { column in
                header(column, alignment: .trailing)
            }
        }
        .padding(.horizontal, InstrumentSpacing.bar)
        .padding(.vertical, InstrumentSpacing.cell)
    }

    private func header(_ column: ProcessColumn, alignment: HorizontalAlignment) -> some View {
        Button { onSort(column) } label: {
            HeatColumnHeader(title: column.title, value: presentation.headerValue(column),
                             heat: presentation.heat(column, presentation.totals),
                             sortAscending: sort.column == column ? sort.ascending : nil, alignment: alignment,
                             hue: column.hue)
                .padding(.horizontal, InstrumentSpacing.group)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Nach \(column.title) sortieren")
        .accessibilityIdentifier("processSort.\(column.rawValue)")
        // ax-value: Knopf, behält seine Rolle und damit den Wert
        .accessibilityValue(Text(verbatim: sortValue(column)))
    }

    /// Summe der Spalte und, falls danach sortiert wird, die Richtung (der Pfeil ist für VoiceOver ausgeblendet).
    private func sortValue(_ column: ProcessColumn) -> String {
        let value = presentation.headerValue(column)
        guard sort.column == column else { return value }
        let direction = sort.ascending ? String(localized: "aufsteigend sortiert") : String(localized: "absteigend sortiert")
        return "\(value), \(direction)"
    }
}

/// Die Zeilen ohne Scrollbereich (auch für Snapshots: `ImageRenderer` zeichnet keinen `ScrollView`-Inhalt).
struct ProcessTableRows: View {
    let presentation: ProcessListPresentation
    var columns = ProcessTableLayout.valueColumns
    @Binding var selection: String?
    let onToggle: (ProcessListRow) -> Void

    /// Umsortiert wird ohne Animation: Nach CPU sortiert ändert sich die Reihenfolge fast jeden Takt, eine Animation
    /// liefe also dauernd mit der Bildwiederholrate und ließe Zeilen übereinanderliegen.
    var body: some View {
        LazyVStack(spacing: InstrumentSpacing.stack) {
            ForEach(presentation.rows) { row in
                ProcessRowView(row: row, physicalMemory: presentation.physicalMemory, isSelected: selection == row.id,
                               columns: columns) {
                    onToggle(row)
                }
                .selectableRow {
                    if case .group = row.kind { onToggle(row) } else { selection = row.id }
                }
            }
        }
        .padding(.horizontal, InstrumentSpacing.group)
        .padding(.vertical, InstrumentSpacing.item)
    }
}

/// Bekommt nur ihre Zeile und den Bezug der Speicher-Heatmap, nicht die ganze Darstellung: SwiftUI vergleicht die
/// Eingaben jeder sichtbaren Zeile je Takt, bei der ganzen Darstellung also alle Zeilen je Zeile (#478).
struct ProcessRowView: View {
    let row: ProcessListRow
    let physicalMemory: UInt64
    let isSelected: Bool
    var columns = ProcessTableLayout.valueColumns
    let onToggle: () -> Void

    private var isGroup: Bool {
        if case .group = row.kind { true } else { false }
    }

    var body: some View {
        InstrumentColumnsLayout(ProcessTableLayout.columns(values: columns.count)) {
            name
            ForEach(columns) { column in
                value(column)
            }
        }
        .padding(.horizontal, InstrumentSpacing.group)
        .padding(.top, isGroup ? InstrumentSpacing.cell : 0)
        .padding(.bottom, isGroup ? InstrumentSpacing.inline : 0)
        .instrumentRowBackground(isSelected: isSelected)
        .help(row.group == .system && isGroup ? row.group.note ?? "" : "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(isGroup ? "processGroupRow" : "processRow")
        .disclosureAction(isExpandable: row.isExpandable && !isGroup, isExpanded: row.isExpanded, toggle: onToggle)
    }

    private var name: some View {
        HStack(spacing: InstrumentSpacing.group) {
            disclosure
            if !isGroup { icon }
            if isGroup {
                // Einzeilig wie die Zeilen: In schmaler Namensspalte (Energie neben den Karten, kleinstes Fenster)
                // brach „Hintergrundprozesse“ sonst in drei Zeilen um; die Anzahl weicht vor dem Titel.
                Text(verbatim: row.title).font(InstrumentFont.title).lineLimit(1).layoutPriority(1)
                Text(verbatim: row.detail).font(InstrumentFont.body).foregroundStyle(.instrumentSecondary).lineLimit(1)
            } else {
                Text(verbatim: row.title).lineLimit(1).truncationMode(.middle)
                Text(verbatim: row.detail).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary).lineLimit(1)
            }
        }
        .padding(.leading, row.kind.isChild ? ProcessTableLayout.childIndent : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var disclosure: some View {
        if row.isExpandable {
            Button(action: onToggle) {
                Image(systemName: "chevron.right")
                    .font(InstrumentFont.label.weight(.semibold))
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                    .frame(width: InstrumentSize.disclosure, height: InstrumentSize.disclosure)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.instrumentSecondary)
            .accessibilityLabel(row.isExpanded ? "Zuklappen" : "Aufklappen")
        } else {
            Color.clear.frame(width: InstrumentSize.disclosure, height: InstrumentSize.disclosure)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if case .entry(let entry, _) = row.kind, let app = entry.app {
            AppIconView(app: AppIdentity(bundleID: app.bundleID, path: app.bundlePath, displayName: app.name,
                                         signing: .unknown, presence: .present),
                        size: ProcessTableLayout.iconSize)
        } else {
            Image(systemName: row.group == .system ? "lock.shield.fill" : "gearshape.fill")
                .font(InstrumentFont.rowIcon)
                .foregroundStyle(.instrumentSecondary)
                .frame(width: ProcessTableLayout.iconSize, height: ProcessTableLayout.iconSize)
                .background(Circle().fill(.quaternary))
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func value(_ column: ProcessColumn) -> some View {
        if isGroup {
            Text(verbatim: column.text(row.figures))
                .font(InstrumentFont.numeric)
                .foregroundStyle(.instrumentSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, InstrumentSpacing.group)
        } else {
            HeatCell(column.text(row.figures), heat: column.heat(row.figures, physicalMemory: physicalMemory),
                     hue: column.hue)
        }
    }
}

private extension ProcessListRow.Kind {
    var isChild: Bool {
        if case .child = self { true } else { false }
    }
}

#if DEBUG
#Preview("Prozesse") {
    ProcessTableView(presentation: ProcessListPreviewData.presentation, sort: .default, selection: .constant("app:720"),
                     onSort: { _ in }, onToggle: { _ in })
        .padding(14)
        .frame(width: 900, height: 640)
        .instrumentBackground()
}
#endif
