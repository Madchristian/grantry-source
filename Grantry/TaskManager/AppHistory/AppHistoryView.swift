import GrantryCharts
import ManagerKit
import SwiftUI

/// Tab „App-Verlauf“ (Spec 2026-11-06 §6 Stufe 2): Säulen je Stunde (Heute) bzw. Tag (7 oder 30 Tage) für die gewählte
/// Kennzahl, darunter Apps und eigene Programme mit CPU-Zeit, Energie, Netz und Datenträger als Heatmap. Sagt
/// ausdrücklich, dass nur gemessene Zeiten zählen; Abschnitte ohne Messung erscheinen gestrichelt statt als 0, nicht
/// gemessene Werte (Netz ohne nettop, Energie ohne Quelle) als „–“ bzw. „nicht gemessen“.
struct AppHistoryView: View {
    let summary: AppUsageSummary
    @Binding var range: AppUsageRange
    @Binding var metric: AppUsageMetric
    let error: String?
    let canClear: Bool
    let onClear: () -> Void
    @Environment(\.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            controls
            chart
            table
        }
        .padding(InstrumentSpacing.page)
        .renderProbe("AppHistoryView")
    }

    private var controls: some View {
        // Bei 900 pt mit Seitenleiste rücken Hinweis und Löschen in die nächste Zeile, statt „Gemessen …“ senkrecht zu
        // stauchen (#486).
        InstrumentControlRow {
            InstrumentSegments(String(localized: "Zeitraum"), selection: $range,
                               options: AppUsageRange.allCases.map { ($0, $0.title) })
            InstrumentSegments(String(localized: "Kennzahl"), selection: $metric,
                               options: AppUsageMetric.allCases.map { ($0, $0.title) })
        } trailing: {
            if let error {
                Label("Nicht gespeichert: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(InstrumentFont.body)
                    .foregroundStyle(environment.statusTextColor(.finding))
                    .lineLimit(1)
            }
            Label(AppUsagePresentation.coverageText(summary, metric: metric), systemImage: "clock")
                .font(InstrumentFont.body)
                .foregroundStyle(.instrumentSecondary)
            Button("Verlauf löschen …", systemImage: "trash", role: .destructive, action: onClear)
                .disabled(!canClear)
                .help("Alle gespeicherten Stunden des App-Verlaufs entfernen")
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
            PeilHead(AppUsagePresentation.chartTitle(metric: metric, range: range),
                     value: metric.text(summary.totals[metric]), hue: metric.hue)
            UsageBarChart(bars: summary.bars.map {
                UsageBarChart.Bar(id: $0.index, value: $0.value ?? 0, isMeasured: $0.isMeasured, label: $0.label,
                                  detail: $0.detail)
            }, hue: metric.hue)
                .frame(height: InstrumentSize.mainGraph)
            Label(AppUsagePresentation.scopeNote, systemImage: "info.circle")
                .font(InstrumentFont.label)
                .foregroundStyle(.instrumentSecondary)
        }
        .instrumentPanel()
    }

    static let columns = ProcessTableLayout.columns(values: AppUsageMetric.allCases.count)

    private var table: some View {
        let maxima = Dictionary(uniqueKeysWithValues: AppUsageMetric.allCases.map { metric in
            (metric, summary.rows.compactMap { $0.totals[metric] }.max() ?? 0)
        })
        return TaskManagerTable {
            InstrumentColumnsLayout(Self.columns, alignment: .bottom) {
                HeatColumnHeader(title: String(localized: "Name"), value: "", heat: nil, sortAscending: nil,
                                 alignment: .leading)
                    .padding(.leading, ProcessTableLayout.iconSize + InstrumentSpacing.bar)
                ForEach(AppUsageMetric.allCases) { column in
                    Button { metric = column } label: {
                        HeatColumnHeader(title: column.title, value: column.shortText(summary.totals[column]),
                                         heat: nil, sortAscending: column == metric ? false : nil, hue: column.hue)
                            .padding(.horizontal, InstrumentSpacing.group)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Nach \(column.title) sortieren")
                    .accessibilityIdentifier("appHistorySort.\(column.rawValue)")
                    // ax-value: Knopf, behält seine Rolle und damit den Wert
                    .accessibilityValue(Text(verbatim: column.shortText(summary.totals[column])))
                    .accessibilityAddTraits(column == metric ? .isSelected : [])
                }
            }
            .padding(.horizontal, InstrumentSpacing.bar)
            .padding(.vertical, InstrumentSpacing.cell)
        } rows: {
            if summary.isEmpty {
                ContentUnavailableView("Noch kein Verlauf", systemImage: "clock.arrow.circlepath",
                                       description: Text("Der Verlauf füllt sich, solange der Task-Manager misst."))
                    .frame(maxWidth: .infinity, minHeight: InstrumentSize.mainGraph)
            } else {
                LazyVStack(spacing: InstrumentSpacing.stack) {
                    ForEach(summary.rows) { row in
                        AppHistoryRow(row: row, maxima: maxima)
                    }
                }
                .padding(.horizontal, InstrumentSpacing.group)
                .padding(.vertical, InstrumentSpacing.item)
            }
        }
    }
}

private struct AppHistoryRow: View {
    let row: AppUsageRow
    let maxima: [AppUsageMetric: Double]

    var body: some View {
        InstrumentColumnsLayout(AppHistoryView.columns) {
            HStack(spacing: InstrumentSpacing.group) {
                icon
                Text(verbatim: row.subject.name).lineLimit(1).truncationMode(.middle)
                Text(row.subject.kind == .app ? "App" : "Programm").font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(AppUsageMetric.allCases) { metric in
                HeatCell(metric.shortText(row.totals[metric]),
                         heat: row.totals[metric].flatMap {
                             AppUsagePresentation.heat($0, maximum: maxima[metric] ?? 0)
                         },
                         hue: metric.hue)
            }
        }
        .padding(.horizontal, InstrumentSpacing.group)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("appHistoryRow")
    }

    @ViewBuilder
    private var icon: some View {
        if row.subject.kind == .app {
            AppIconView(app: AppIdentity(bundleID: row.subject.bundleID, path: row.subject.bundlePath,
                                         displayName: row.subject.name, signing: .unknown, presence: .present),
                        size: ProcessTableLayout.iconSize)
        } else {
            Image(systemName: "terminal.fill")
                .font(InstrumentFont.rowIcon)
                .foregroundStyle(.instrumentSecondary)
                .frame(width: ProcessTableLayout.iconSize, height: ProcessTableLayout.iconSize)
                .background(Circle().fill(.quaternary))
                .accessibilityHidden(true)
        }
    }
}

// `AppUsagePreviewData` gibt es nur im Debug-Build.
#if DEBUG
#Preview("App-Verlauf") {
    AppHistoryView(summary: AppUsagePresentation.summary(of: AppUsagePreviewData.history, range: .sevenDays,
                                                         metric: .cpu, now: AppUsagePreviewData.now,
                                                         calendar: AppUsagePreviewData.calendar),
                   range: .constant(.sevenDays), metric: .constant(.cpu), error: nil, canClear: true, onClear: {})
        .frame(width: 1180, height: 760)
        .instrumentBackground()
}
#endif
