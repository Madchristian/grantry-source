import GrantryCharts
import ManagerKit
import SwiftUI

/// Tabelle des Tabs „Details“ (Spec §2, §4) als Panel (`TaskManagerTable`): alle Prozesse flach oder als Baum (`lines`),
/// Spalten nach `ProcessDetailColumns`, Köpfe mit Gesamtwert und LED-Leiste, Heatmap für CPU und Speicher, je Zeile eine Sparkline
/// der letzten 60 s CPU. Eigene Zeilen statt `Table` wie im Tab „Prozesse“: nur so passen Heatmap und Sparkline
/// zusammen. Zeigt nur die `ProcessDetailPresentation`; Messung, Suche und Beenden liegen beim `DetailsTab`.
struct ProcessDetailTableView: View {
    let presentation: ProcessDetailPresentation
    let columns: ProcessDetailColumns
    let sort: ProcessDetailSort
    let history: ChartHistory
    @Binding var selection: String?
    let onSort: (ProcessDetailColumn) -> Void
    let onToggleColumn: (ProcessDetailColumn) -> Void
    let menu: (ProcessDetailRow) -> ProcessDetailContextMenu
    /// Baumansicht (`ProcessTree.lines`); `nil` = flache Tabelle.
    var lines: [ProcessTreeLine]? = nil
    var onToggleBranch: (String) -> Void = { _ in }

    var body: some View {
        // Passen die Spalten nicht nebeneinander (900 pt mit Seitenleiste), rollt die Tabelle waagrecht mit sichtbarem
        // Rollbalken, statt rechts abgeschnitten zu wirken (#486).
        FittingScrollView(axes: .horizontal) {
            TaskManagerTable {
                ProcessDetailHeader(presentation: presentation, columns: columns, sort: sort, onSort: onSort,
                                    indentsForTree: lines != nil)
                    .contextMenu { ProcessDetailColumnToggles(columns: columns, toggle: onToggleColumn) }
            } rows: {
                ProcessDetailRows(presentation: presentation, columns: columns, history: history,
                                  selection: $selection, menu: menu, lines: lines, onToggleBranch: onToggleBranch)
            }
        }
        .renderProbe("ProcessDetailTableView")
    }
}

/// Maße, gemeinsam für Kopf und Zeilen. `nil` = teilt sich den restlichen Platz (Name, Pfad).
enum ProcessDetailLayout {
    static let spacing = InstrumentSpacing.inline
    static let iconSize = InstrumentSize.rowIcon
    static let sparklineHeight: CGFloat = 20
    static let flexibleMinimum: CGFloat = 150
    /// Baumansicht: Pfeil zum Auf- und Zuklappen, Einrückung je Ebene.
    static let disclosureWidth = InstrumentSize.disclosure
    static let treeIndent: CGFloat = 16

    static func width(_ column: ProcessDetailColumn) -> CGFloat? {
        switch column {
        case .name, .path: nil
        case .pid: 70
        case .threads: 96
        case .parentPID: 86
        case .user: 116
        case .cpu: 88
        case .cpuHistory: 128
        case .cpuTime: 96
        case .memory: 104
        case .startTime: 168
        }
    }

    static func alignment(_ column: ProcessDetailColumn) -> HorizontalAlignment {
        column.isNumeric ? .trailing : .leading
    }
}

private extension View {
    func detailColumnFrame(_ column: ProcessDetailColumn) -> some View {
        let alignment = Alignment(horizontal: ProcessDetailLayout.alignment(column), vertical: .center)
        return Group {
            if let width = ProcessDetailLayout.width(column) {
                frame(width: width, alignment: alignment)
            } else {
                frame(minWidth: ProcessDetailLayout.flexibleMinimum, maxWidth: .infinity, alignment: alignment)
            }
        }
    }
}

struct ProcessDetailHeader: View {
    let presentation: ProcessDetailPresentation
    let columns: ProcessDetailColumns
    let sort: ProcessDetailSort
    let onSort: (ProcessDetailColumn) -> Void
    /// In der Baumansicht steht vor jedem Namen der Pfeil.
    var indentsForTree = false

    var body: some View {
        HStack(alignment: .bottom, spacing: ProcessDetailLayout.spacing) {
            ForEach(columns.visible) { column in
                header(column)
                    .padding(.leading, column == .name ? nameIndent : 0)
                    .detailColumnFrame(column)
            }
        }
        .padding(.horizontal, InstrumentSpacing.bar)
        .padding(.vertical, InstrumentSpacing.cell)
    }

    private var nameIndent: CGFloat {
        ProcessDetailLayout.iconSize + InstrumentSpacing.group
            + (indentsForTree ? ProcessDetailLayout.disclosureWidth + InstrumentSpacing.group : 0)
    }

    private func header(_ column: ProcessDetailColumn) -> some View {
        Button { onSort(column) } label: {
            // Der Verlauf hat keinen eigenen Lastbalken; er stünde doppelt neben dem der CPU.
            HeatColumnHeader(title: column.title, value: presentation.headerValue(column),
                             heat: column == .cpuHistory ? nil : presentation.heat(column, presentation.totals),
                             sortAscending: sort.column == column ? sort.ascending : nil,
                             alignment: ProcessDetailLayout.alignment(column), hue: column.hue)
                .padding(.horizontal, InstrumentSpacing.group)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(column.isSortable ? "Nach \(column.title) sortieren" : "CPU der letzten 60 Sekunden")
        .accessibilityIdentifier("detailSort.\(column.rawValue)")
        .accessibilityAddTraits(sort.column == column ? .isSelected : [])
    }
}

/// Die Zeilen ohne Scrollbereich (auch für Snapshots: `ImageRenderer` zeichnet keinen `ScrollView`-Inhalt).
struct ProcessDetailRows: View {
    let presentation: ProcessDetailPresentation
    let columns: ProcessDetailColumns
    let history: ChartHistory
    @Binding var selection: String?
    let menu: (ProcessDetailRow) -> ProcessDetailContextMenu
    /// Baumansicht; `nil` = flache Tabelle.
    var lines: [ProcessTreeLine]? = nil
    var onToggleBranch: (String) -> Void = { _ in }

    /// Umsortiert wird ohne Animation, wie im Tab „Prozesse“ (`ProcessTableRows`).
    var body: some View {
        let shown = lines ?? ProcessTree.flat(presentation.rows)
        LazyVStack(spacing: InstrumentSpacing.stack) {
            ForEach(shown) { line in
                ProcessDetailRowView(row: line.row, physicalMemory: presentation.physicalMemory, columns: columns,
                                     cpuHistory: columns.contains(.cpuHistory)
                                         ? history.series(.processCPU(line.row.process.key), in: .oneMinute) : nil,
                                     isSelected: selection == line.id, line: lines == nil ? nil : line,
                                     onToggleBranch: { onToggleBranch(line.id) })
                    .selectableRow { selection = line.id }
                    .contextMenu { menu(line.row) }
            }
        }
        .padding(.horizontal, InstrumentSpacing.group)
        .padding(.vertical, InstrumentSpacing.item)
    }
}

/// Bekommt nur ihre Zeile, den Bezug der Speicher-Heatmap und ihren eigenen CPU-Verlauf – nicht die ganze Darstellung
/// und den ganzen Verlauf aller Prozesse: SwiftUI vergleicht die Eingaben jeder sichtbaren Zeile je Takt (#478).
struct ProcessDetailRowView: View {
    let row: ProcessDetailRow
    let physicalMemory: UInt64
    let columns: ProcessDetailColumns
    /// CPU der letzten 60 s; `nil`, solange die Spalte ausgeblendet ist.
    let cpuHistory: ChartSeries?
    let isSelected: Bool
    /// Zeile der Baumansicht; `nil` in der flachen Tabelle.
    var line: ProcessTreeLine? = nil
    var onToggleBranch: () -> Void = {}
    @Environment(\.self) private var environment

    var body: some View {
        HStack(spacing: ProcessDetailLayout.spacing) {
            ForEach(columns.visible) { column in
                cell(column).detailColumnFrame(column)
            }
        }
        .padding(.horizontal, InstrumentSpacing.group)
        .instrumentRowBackground(isSelected: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("processDetailRow")
        .disclosureAction(isExpandable: line?.hasChildren ?? false, isExpanded: line?.isExpanded ?? false,
                          toggle: onToggleBranch)
    }

    @ViewBuilder
    private func cell(_ column: ProcessDetailColumn) -> some View {
        switch column {
        case .name: name
        case .cpu, .memory:
            HeatCell(column.text(row), heat: ProcessDetailPresentation.heat(column, row.figures,
                                                                             physicalMemory: physicalMemory),
                     hue: column.hue)
        case .cpuHistory: sparkline
        default:
            Text(verbatim: column.text(row))
                .font(InstrumentFont.numeric)
                .foregroundStyle(column == .path || !row.isOwn ? .instrumentSecondary : .primary)
                .lineLimit(1)
                .truncationMode(column == .path ? .head : .tail)
                .padding(.horizontal, InstrumentSpacing.group)
                .help(column == .path ? row.path ?? "" : "")
        }
    }

    private var name: some View {
        HStack(spacing: InstrumentSpacing.group) {
            if let line { disclosure(line) }
            Image(systemName: row.isOwn ? "gearshape.fill" : "lock.shield.fill")
                .font(InstrumentFont.rowIcon)
                .foregroundStyle(.instrumentSecondary)
                .frame(width: ProcessDetailLayout.iconSize, height: ProcessDetailLayout.iconSize)
                .background(Circle().fill(.quaternary))
                .accessibilityHidden(true)
            Text(verbatim: row.title).lineLimit(1).truncationMode(.middle)
        }
        .padding(.leading, InstrumentSpacing.group + CGFloat(line?.depth ?? 0) * ProcessDetailLayout.treeIndent)
    }

    @ViewBuilder
    private func disclosure(_ line: ProcessTreeLine) -> some View {
        if line.hasChildren {
            Button(action: onToggleBranch) {
                Image(systemName: "chevron.right")
                    .font(InstrumentFont.label.weight(.semibold))
                    .rotationEffect(.degrees(line.isExpanded ? 90 : 0))
                    .frame(width: ProcessDetailLayout.disclosureWidth, height: ProcessDetailLayout.disclosureWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.instrumentSecondary)
            .accessibilityLabel(line.isExpanded ? "Zuklappen" : "Aufklappen")
        } else {
            Color.clear.frame(width: ProcessDetailLayout.disclosureWidth, height: ProcessDetailLayout.disclosureWidth)
        }
    }

    @ViewBuilder
    private var sparkline: some View {
        if let series = cpuHistory, series.values.contains(where: { $0 != nil }) {
            Sparkline(series: series, window: HistoryWindow.oneMinute.duration.seconds,
                      color: environment.instrumentColor(.cpu))
                .frame(height: ProcessDetailLayout.sparklineHeight)
                .padding(.horizontal, InstrumentSpacing.item)
        } else {
            Text(verbatim: "–")
                .foregroundStyle(.instrumentSecondary)
                .frame(maxWidth: .infinity)
                .help(row.isOwn ? "Noch keine Messung" : "Ohne Verlauf: Werte anderer Benutzer stammen aus ps")
        }
    }
}

#if DEBUG
#Preview("Details") {
    ProcessDetailTableView(presentation: ProcessDetailPreviewData.presentation(), columns: .default, sort: .default,
                           history: ChartHistory(history: ProcessDetailPreviewData.history,
                                                 measuredAt: ProcessDetailPreviewData.measuredAt),
                           selection: .constant(nil), onSort: { _ in }, onToggleColumn: { _ in },
                           menu: { ProcessDetailContextMenu(row: $0, canTerminate: true, prepare: { _, _ in }) })
        .padding(14)
        .frame(width: 1180, height: 640)
        .instrumentBackground()
}
#endif
