import GrantryCharts
import ManagerKit
import SwiftUI

/// Kachel „Prozesse“ des Übersichts-Baukastens (Spec 2026-11-09-uebersicht-baukasten § 2): die Einträge mit der höchsten
/// CPU-Last, so viele, wie die Größe fasst (`MenuBarOverview.Processes.capacity(of:)`). 4 × 2 wie die Karte aus PR 623:
/// fünf Zeilen mit Lastbalken im Vergleich der gezeigten Einträge, Arbeitsspeicher und CPU-Last. Kleinere Größen mit
/// Name und CPU-Last; 4 × 1 in zwei Spalten, in einer Zeile Höhe mit kleinen Symbolen.
struct OverviewProcessesTile: OverviewTile {
    static let kind = OverviewTileKind.processes

    let value: MenuBarOverview.Processes
    let span: OverviewTileSpan
    let open: () -> Void

    static func value(from source: OverviewTileSource) -> MenuBarOverview.Processes? { source.overview.processes }

    var body: some View {
        let isDetailed = span == .panel
        OverviewCard(title: Self.kind.title, detail: isDetailed ? String(localized: "höchste CPU-Last") : "",
                     value: isDetailed ? "" : String(localized: "CPU"),
                     spokenValue: String(localized: "höchste CPU-Last"), open: open) {
            Group {
                if value.entries.isEmpty {
                    Text("Die erste Messung folgt mit dem nächsten Takt.")
                        .font(InstrumentFont.label)
                        .foregroundStyle(.instrumentSecondary)
                } else if isDetailed {
                    detailed
                } else {
                    columns
                }
            }
            .fillsOverviewTile()
        }
    }

    /// Eine Spalte über die ganze Breite: Lastbalken, Arbeitsspeicher und CPU-Last stehen in allen Zeilen bündig. Die
    /// Zeilen teilen sich die Höhe der Kachel zu gleichen Teilen, damit unten kein Streifen frei bleibt (Bild 01 der
    /// Abnahme 15.11.2026); fehlen Einträge, bleiben ihre Plätze leer, statt die übrigen auseinanderzuziehen.
    private var detailed: some View {
        let entries = value.entries(for: span)
        let widths = OverviewProcessRow.Columns(memory: MenuBarOverview.Processes.widestMemory(of: entries),
                                                value: MenuBarOverview.Processes.widestValue(of: entries))
        let free = MenuBarOverview.Processes.capacity(of: span) - entries.count
        return VStack(spacing: InstrumentSpacing.stack) {
            ForEach(entries) { entry in
                OverviewProcessRow(entry: entry, columns: widths)
                    .frame(maxHeight: .infinity)
            }
            ForEach(0..<max(free, 0), id: \.self) { _ in
                Color.clear.frame(maxHeight: .infinity)
            }
        }
    }

    private var columns: some View {
        let entries = Array(value.entries(for: span))
        let columnCount = span.columns == OverviewGrid.columns ? 2 : 1
        let rowCount = (entries.count + columnCount - 1) / columnCount
        return HStack(alignment: .top, spacing: InstrumentSpacing.bar) {
            ForEach(0..<columnCount, id: \.self) { column in
                VStack(spacing: span.rows == 1 ? InstrumentSpacing.stack : InstrumentSpacing.item) {
                    ForEach(entries.dropFirst(column * rowCount).prefix(rowCount)) { entry in
                        OverviewProcessRow(entry: entry, compact: span.rows == 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }
}

/// Zeile eines Prozesses oder einer App: Symbol, Name, CPU-Last. Kompakt (Kachel in einer Zeile Höhe) mit kleinerem
/// Symbol, damit zwei Zeilen unter den Titel passen. Mit `columns` dazu Lastbalken und Arbeitsspeicher; die Zahlenspalten
/// sind dann in jeder Zeile so breit wie ihr längster Wert, damit die Balken bündig stehen.
struct OverviewProcessRow: View {
    /// Längster Wert je Zahlenspalte der gezeigten Einträge.
    struct Columns: Equatable {
        let memory: String
        let value: String
    }

    let entry: MenuBarOverview.ProcessEntry
    var compact = false
    var columns: Columns?

    @Environment(\.self) private var environment

    private var iconSize: CGFloat { compact ? InstrumentSize.coreRing : InstrumentSize.rowIcon }

    var body: some View {
        if let columns {
            HStack(spacing: InstrumentSpacing.group) {
                icon
                name
                Spur(fraction: entry.loadFraction, color: environment.instrumentColor(.cpu))
                    .frame(width: InstrumentSize.overviewLoadBar, height: InstrumentSize.spurHeader)
                column(entry.memory, widest: columns.memory).foregroundStyle(.instrumentSecondary)
                column(entry.value, widest: columns.value)
            }
            .frame(height: iconSize)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(entry.name), CPU \(entry.value), Arbeitsspeicher \(entry.memory)"))
        } else {
            HStack(spacing: InstrumentSpacing.group) {
                icon
                name
                Text(verbatim: entry.value).font(InstrumentFont.numeric)
            }
            .frame(height: iconSize)
            .accessibilityElement(children: .combine)
        }
    }

    private var name: some View {
        Text(verbatim: entry.name).font(InstrumentFont.body).lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Rechtsbündiger Wert in der Breite des längsten Werts der Spalte.
    private func column(_ value: String, widest: String) -> some View {
        Text(verbatim: widest).font(InstrumentFont.numeric).lineLimit(1).hidden()
            .overlay(alignment: .trailing) {
                Text(verbatim: value).font(InstrumentFont.numeric).lineLimit(1).fixedSize()
            }
    }

    @ViewBuilder
    private var icon: some View {
        if let app = entry.app {
            AppIconView(app: AppIdentity(bundleID: app.bundleID, path: app.bundlePath, displayName: app.name,
                                         signing: .unknown, presence: .present),
                        size: iconSize)
        } else {
            Image(systemName: entry.isSystem ? "lock.shield.fill" : "gearshape.fill")
                .font(InstrumentFont.rowIcon)
                .foregroundStyle(.instrumentSecondary)
                .frame(width: iconSize, height: iconSize)
                .background(Circle().fill(.quaternary))
                .accessibilityHidden(true)
        }
    }
}
