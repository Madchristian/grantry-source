import SwiftUI

/// Panel „Zu diesem Zeitpunkt“ rechts im Wachbuch (Spec 2026-11-08 § 5.1, Standard § 3.13): Werte, größte Verbraucher,
/// laufende Befunde und Änderungen ±5 min an der Zeitmarke, je mit dem Sprung zum zuständigen Bereich. Ohne Zeitmarke
/// der Leerzustand „nichts gewählt“ (§ 3.11). Zeichnet nur, wenn sich die Zeitmarke bewegt oder neue Werte kommen.
struct WatchbookMomentPanel: View {
    let content: WatchbookMomentContent?
    let jump: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            PeilHead(String(localized: "Zu diesem Zeitpunkt"),
                     detail: content == nil ? String(localized: "Keine Zeitmarke")
                         : String(localized: "Zeitmarke · Änderungen ±5 min"),
                     value: content?.time ?? "", finding: content?.findings.isEmpty == false,
                     identifier: "watchbookMomentTitle")
            if let content {
                ChartScrollView {
                    WatchbookMomentSections(content: content, jump: jump)
                }
            } else {
                WatchbookMomentPlaceholder()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .instrumentPanel()
    }
}

private struct WatchbookMomentPlaceholder: View {
    var body: some View {
        VStack(spacing: InstrumentSpacing.cell) {
            Image(systemName: "scope")
                .font(InstrumentFont.valueLarge)
                .foregroundStyle(.instrumentSecondary)
                .accessibilityHidden(true)
            Text("""
                Eine Zeitmarke im Verlauf oder ein Befund in der Tabelle zeigt hier Werte, größte Verbraucher und \
                Änderungen zu diesem Zeitpunkt.
                """)
                .font(InstrumentFont.body)
                .foregroundStyle(.instrumentSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(InstrumentSpacing.empty)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct WatchbookMomentSections: View {
    let content: WatchbookMomentContent
    let jump: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            if !content.values.isEmpty {
                MeasureFieldRow(fields: content.values.map { ($0.title, $0.value) })
            }
            MomentSection(title: String(localized: "Größte Verbraucher")) {
                if let note = content.consumersNote {
                    MomentNote(text: note)
                } else {
                    ConsumerGroup(title: String(localized: "CPU"), consumers: content.cpuConsumers, hue: .cpu)
                    ConsumerGroup(title: String(localized: "Arbeitsspeicher"), consumers: content.memoryConsumers,
                                  hue: .memory)
                }
            }
            MomentSection(title: String(localized: "Laufende Befunde")) {
                if content.findings.isEmpty {
                    MomentNote(text: String(localized: "Kein Befund lief zu diesem Zeitpunkt."), symbol: nil)
                }
                ForEach(content.findings) { MomentEntryRow(entry: $0, jump: jump) }
            }
            MomentSection(title: String(localized: "Änderungen ±5 min")) {
                if content.changes.isEmpty {
                    MomentNote(text: String(localized: "Keine Änderungen und Systemereignisse."), symbol: nil)
                }
                ForEach(content.changes) { MomentEntryRow(entry: $0, jump: jump) }
            }
        }
    }
}

/// Abschnitt mit Überschrift (Trennlinie, Titel `font.label` semibold sekundär) wie „Größte Verbraucher“ in der
/// Übersicht.
private struct MomentSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.group) {
            Divider()
            Text(verbatim: title).font(InstrumentFont.label.weight(.semibold)).foregroundStyle(.instrumentSecondary)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

/// Hinweis (§ 3.12): `info.circle` und `font.label` sekundär; ohne Symbol ein ruhiger Satz.
private struct MomentNote: View {
    let text: String
    var symbol: String? = "info.circle"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: InstrumentSpacing.inline) {
            if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        }
        .font(InstrumentFont.label)
        .foregroundStyle(.instrumentSecondary)
    }
}

private struct ConsumerGroup: View {
    let title: String
    let consumers: [WatchbookConsumerContent]
    let hue: InstrumentHue

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.inline) {
            Text(verbatim: title).font(InstrumentFont.label.weight(.medium))
            if consumers.isEmpty {
                Text(verbatim: "–").font(InstrumentFont.body).foregroundStyle(.instrumentSecondary)
            }
            ForEach(consumers) { ConsumerLine(consumer: $0, hue: hue) }
        }
    }
}

private struct ConsumerLine: View {
    private enum Layout {
        static let spur: CGFloat = 64
        static let value: CGFloat = 72
    }

    let consumer: WatchbookConsumerContent
    let hue: InstrumentHue

    @Environment(\.self) private var environment

    var body: some View {
        HStack(spacing: InstrumentSpacing.group) {
            HStack(spacing: InstrumentSpacing.inline) {
                Text(verbatim: consumer.name).font(InstrumentFont.body).lineLimit(1).truncationMode(.middle)
                if !consumer.badge.isEmpty { StatusChip(consumer.badge, tone: .neutral, isSmall: true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spur(fraction: consumer.fraction, color: environment.instrumentColor(hue))
                .frame(width: Layout.spur, height: InstrumentSize.spurList)
                .accessibilityHidden(true)
            Text(verbatim: consumer.value).font(InstrumentFont.numeric)
                .foregroundStyle(environment.instrumentTextColor(hue))
                .frame(width: Layout.value, alignment: .trailing)
        }
        .frame(height: InstrumentSize.rowIcon)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [consumer.name, consumer.badge, consumer.value].filter { !$0.isEmpty }
            .joined(separator: ", ")))
    }
}

/// Laufender Befund oder Änderung: Befund-Punkt bzw. Symbol der Quelle, Titel und Zeit, Satz, darunter der Sprung oder
/// der Hinweis, warum es keinen gibt.
private struct MomentEntryRow: View {
    let entry: WatchbookMomentEntry
    let jump: (String) -> Void

    @Environment(\.self) private var environment

    var body: some View {
        HStack(alignment: .top, spacing: InstrumentSpacing.cell) {
            marker
                .frame(width: InstrumentSize.rowIcon, height: InstrumentSize.rowIcon)
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: entry.title).font(InstrumentFont.body.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: InstrumentSpacing.group)
                    Text(verbatim: entry.time).font(InstrumentFont.label.monospacedDigit())
                        .foregroundStyle(.instrumentSecondary).lineLimit(1)
                }
                Text(verbatim: entry.detail).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if let target = entry.jump {
                    if let note = target.note {
                        MomentNote(text: note)
                    } else {
                        Button { jump(target.id) } label: {
                            HStack(spacing: InstrumentSpacing.stack) {
                                Text(verbatim: target.title)
                                Image(systemName: "chevron.right").font(InstrumentFont.micro.weight(.semibold))
                            }
                            .font(InstrumentFont.label.weight(.medium))
                            .foregroundStyle(environment.statusTextColor(.info))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: "\(target.title): \(entry.title)"))
                        .accessibilityIdentifier("watchbookJump")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var marker: some View {
        switch entry.style {
        case .finding:
            FindingDot()
        case .critical:
            Circle().fill(environment.statusColor(.critical))
                .frame(width: InstrumentSize.findingDot, height: InstrumentSize.findingDot)
        case .change, .system:
            ExtensionSymbol(symbol: entry.symbol ?? "circle", size: InstrumentSize.rowIcon)
        }
    }
}

// MARK: - Tabelle „Befunde“

private enum FindingTableLayout {
    static let spacing = InstrumentSpacing.inline
    static let startWidth: CGFloat = 84
    static let durationWidth: CGFloat = 112
    static let kindWidth: CGFloat = 140
    static let causeWidth: CGFloat = 150
}

/// Tabelle „Befunde“ unter dem Verlauf (§ 3.7): Beginn, Dauer, Art, Grund, Hauptverursacher, neueste zuerst. Die Wahl
/// einer Zeile setzt die Zeitmarke (die App ordnet die Zeile ihrem Zeitpunkt zu).
struct WatchbookFindingTable: View {
    let rows: [WatchbookFindingRowContent]
    let emptyText: String
    @Binding var selection: String?

    var body: some View {
        InstrumentTable {
            FindingTableHeader()
        } rows: {
            if rows.isEmpty {
                Text(verbatim: emptyText).font(InstrumentFont.body).foregroundStyle(.instrumentSecondary)
                    .padding(InstrumentSpacing.bar)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            LazyVStack(spacing: InstrumentSpacing.stack) {
                ForEach(rows) { row in
                    FindingTableRow(row: row, isSelected: selection == row.id)
                        .equatable()
                        .selectableRow { selection = row.id }
                }
            }
            .padding(.horizontal, InstrumentSpacing.group)
            .padding(.vertical, InstrumentSpacing.item)
            // Im Bild ohne Bildlauf schneidet das Panel überzählige Zeilen ab, statt den Verlauf zusammenzudrücken.
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            .layoutPriority(1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Befunde"))
        .accessibilityIdentifier("watchbookFindings")
    }
}

private struct FindingTableHeader: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: FindingTableLayout.spacing) {
            header(String(localized: "Beginn")).frame(width: FindingTableLayout.startWidth, alignment: .leading)
            header(String(localized: "Dauer")).frame(width: FindingTableLayout.durationWidth, alignment: .leading)
            header(String(localized: "Art")).frame(width: FindingTableLayout.kindWidth, alignment: .leading)
            header(String(localized: "Grund")).frame(maxWidth: .infinity, alignment: .leading)
            header(String(localized: "Hauptverursacher")).frame(width: FindingTableLayout.causeWidth, alignment: .leading)
        }
        .padding(.horizontal, InstrumentSpacing.bar)
        .padding(.vertical, InstrumentSpacing.cell)
    }

    private func header(_ title: String) -> some View {
        HeatColumnHeader(title: title, value: "", heat: nil, sortAscending: nil, alignment: .leading)
            .padding(.horizontal, InstrumentSpacing.inline)
    }
}

private struct FindingTableRow: View, Equatable {
    let row: WatchbookFindingRowContent
    let isSelected: Bool

    @Environment(\.self) private var environment

    var body: some View {
        HStack(spacing: FindingTableLayout.spacing) {
            cell(row.start, font: InstrumentFont.numeric).frame(width: FindingTableLayout.startWidth, alignment: .leading)
            cell(row.duration, font: InstrumentFont.numeric)
                .frame(width: FindingTableLayout.durationWidth, alignment: .leading)
            HStack(spacing: InstrumentSpacing.inline) {
                if row.isCritical {
                    Circle().fill(environment.statusColor(.critical))
                        .frame(width: InstrumentSize.findingDotSmall, height: InstrumentSize.findingDotSmall)
                } else {
                    FindingDot(size: InstrumentSize.findingDotSmall)
                }
                Text(verbatim: row.kind).font(InstrumentFont.body.weight(.medium)).lineLimit(1)
            }
            .padding(.horizontal, InstrumentSpacing.inline)
            .frame(width: FindingTableLayout.kindWidth, alignment: .leading)
            cell(row.reason, font: InstrumentFont.body, secondary: true).frame(maxWidth: .infinity, alignment: .leading)
            cell(row.cause, font: InstrumentFont.body, secondary: row.cause == "–")
                .frame(width: FindingTableLayout.causeWidth, alignment: .leading)
        }
        .frame(height: InstrumentSize.row)
        .padding(.horizontal, InstrumentSpacing.group)
        .instrumentRowBackground(isSelected: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: row.accessibilityLabel))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("watchbookFindingRow")
    }

    private func cell(_ text: String, font: Font, secondary: Bool = false) -> some View {
        Text(verbatim: text).font(font).lineLimit(1).truncationMode(.tail)
            .foregroundStyle(secondary ? AnyShapeStyle(.instrumentSecondary) : AnyShapeStyle(.primary))
            .padding(.horizontal, InstrumentSpacing.inline)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.isSelected == rhs.isSelected
    }
}
