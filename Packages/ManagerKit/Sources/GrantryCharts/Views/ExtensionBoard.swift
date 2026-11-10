import SwiftUI

/// Anordnung des Bereichs „Erweiterungen“ (Spec 2026-11-08 § 5.2, Standard §3.13 wie Verbindungen): links (400) die
/// Rechte-Schichten als Radar um den Kern mit der Liste der Schichten, rechts Suche, Filter und die Tabelle nach Schicht,
/// darunter das Detail der gewählten Erweiterung. Ohne fremde Erweiterungen steht rechts ein ruhiges Urteil. Zeigt nur
/// fertige Inhalte (`ExtensionBoardContent`); Suche, Filter, Auswahl und Aktionen liegen bei der Ansicht der App.
public struct ExtensionBoard<Filter: Hashable, Detail: View, Empty: View>: View {
    let content: ExtensionBoardContent
    @Binding var query: String
    @Binding var filter: Filter
    let filters: [(value: Filter, label: String)]
    @Binding var selection: ExtensionRowContent.ID?
    let detail: Detail
    /// Steht über der Tabelle, solange Suche oder Filter nichts zeigen.
    let empty: Empty

    public init(content: ExtensionBoardContent, query: Binding<String>, filter: Binding<Filter>,
                filters: [(value: Filter, label: String)], selection: Binding<ExtensionRowContent.ID?>,
                @ViewBuilder detail: () -> Detail, @ViewBuilder empty: () -> Empty) {
        self.content = content
        _query = query
        _filter = filter
        self.filters = filters
        _selection = selection
        self.detail = detail()
        self.empty = empty()
    }

    public var body: some View {
        // Reicht die Breite nicht für Radar und lesbare Tabelle (900 pt mit Seitenleiste), steht nur die Tabelle da; ihre
        // Abschnitte nennen die Schichten ebenfalls. Vorher lief der Inhalt rechts aus dem Fenster (Mangel 4, #480).
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                ExtensionLayerPanel(layers: content.layers, value: content.radarValue, finding: content.hasFinding,
                                    notice: content.notice, selection: selection)
                    .equatable()
                    .frame(width: InstrumentSize.columnRadar)
                main
            }
            .frame(idealWidth: InstrumentSize.columnRadar + InstrumentSpacing.panel + ExtensionTableLayout.minimumWidth)
            main
        }
        .padding(InstrumentSpacing.page)
    }

    @ViewBuilder
    private var main: some View {
        if let calm = content.calm {
            ExtensionCalmPanel(calm: calm)
        } else {
            VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
                HStack(spacing: InstrumentSpacing.panel) {
                    InstrumentSearchField(text: $query, prompt: String(localized: "Erweiterung oder Hersteller"))
                    InstrumentSegments(String(localized: "Filter"), selection: $filter, options: filters)
                    Text(verbatim: content.shownText)
                        .font(InstrumentFont.body)
                        .foregroundStyle(.instrumentSecondary)
                        .monospacedDigit()
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                InstrumentTable {
                    ExtensionTableHeader()
                } rows: {
                    ExtensionTableRows(sections: content.sections, selection: $selection)
                }
                .frame(maxHeight: .infinity)
                .overlay {
                    if content.sections.isEmpty { empty }
                }
                detail.fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Rechte-Schichten

/// Panel „Rechte-Schichten“: Peilkopf, Radar mit einem Ring je Schicht um den Kern und die Schichten als Liste.
/// `Equatable`, damit ein Scan-Fortschritt ohne neue Erweiterungen das Radar nicht neu zeichnet.
struct ExtensionLayerPanel: View, Equatable {
    let layers: [ExtensionLayerContent]
    let value: String
    let finding: Bool
    let notice: String?
    let selection: ExtensionRowContent.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
            PeilHead(String(localized: "Rechte-Schichten"), detail: String(localized: "Wie nah fremder Code am Kern läuft"),
                     value: value, finding: finding)
            if let notice {
                Label { Text(verbatim: notice) } icon: { Image(systemName: "info.circle") }
                    .font(InstrumentFont.label)
                    .foregroundStyle(.instrumentSecondary)
            }
            // Wächst mit der Höhe bis zum Quadrat der Spalte; darüber würde das Radar nicht größer.
            RingRadar(rings: Self.rings(layers), echoes: Self.echoes(layers), centerSymbol: "cpu",
                      title: String(localized: "Rechte-Schichten"), selection: selection)
                .frame(minHeight: InstrumentSize.radar, maxHeight: InstrumentSize.columnRadar)
            VStack(alignment: .leading, spacing: InstrumentSpacing.group) {
                ForEach(layers) { ExtensionLayerRow(layer: $0) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Schichten"))
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .instrumentPanel()
    }

    /// Ein Ring je Schicht von innen nach außen; innen fassen kürzere Ringe früher zusammen (außen ab 12 Echos).
    static func rings(_ layers: [ExtensionLayerContent]) -> [RingRadar.Ring] {
        layers.indices.map { index in
            RingRadar.Ring(title: layers[index].ringTitle,
                           capacity: RingRadar.proportionalCapacity(ring: index, of: layers.count, outermost: 12))
        }
    }

    /// Erweiterungen als Echos auf dem Ring ihrer Schicht; auffällige in Bernstein, Hinweise in `info`.
    static func echoes(_ layers: [ExtensionLayerContent]) -> [RingRadar.Echo] {
        layers.enumerated().flatMap { index, layer in
            layer.rows.map { row in
                RingRadar.Echo(id: row.id, label: row.radarLabel, ring: index,
                               tone: row.rating.flatMap { $0.tone == .neutral ? nil : $0.tone },
                               accessibilityLabel: ([row.title, layer.ringTitle] + [row.rating?.text].compactMap(\.self))
                                   .joined(separator: ", "))
            }
        }
    }
}

/// Eine Schicht in der Liste unter dem Radar: Leiste bzw. Befund-Punkt, Name, ein Satz, rechts die Anzahl.
struct ExtensionLayerRow: View {
    let layer: ExtensionLayerContent

    @Environment(\.self) private var environment

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: InstrumentSpacing.item) {
            Group {
                if layer.findingCount > 0 {
                    FindingDot(size: InstrumentSize.findingDotSmall)
                } else {
                    Capsule().fill(environment.statusColor(.neutral))
                        .frame(width: InstrumentStroke.focusBar, height: InstrumentSize.disclosure)
                }
            }
            .frame(width: InstrumentSize.findingDot)
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                Text(verbatim: layer.title).font(InstrumentFont.body.weight(.semibold)).lineLimit(1)
                Text(verbatim: layer.explanation).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = layer.note {
                    Text(verbatim: note).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                }
            }
            Spacer(minLength: InstrumentSpacing.group)
            Text(verbatim: "\(layer.rows.count)").font(InstrumentFont.tileValue)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: Self.accessibilityText(layer)))
    }

    /// „Im Kern: 1 Erweiterung, 1 auffällig. Satz.“
    static func accessibilityText(_ layer: ExtensionLayerContent) -> String {
        let count = layer.rows.count == 1 ? String(localized: "1 Erweiterung")
            : String(localized: "\(layer.rows.count) Erweiterungen")
        let findings = layer.findingCount > 0 ? String(localized: ", \(layer.findingCount) auffällig") : ""
        return "\(layer.title): \(count)\(findings). \(layer.explanation)" + (layer.note.map { " \($0)" } ?? "")
    }
}

// MARK: - Tabelle

/// Spalten Erweiterung, Hersteller, Zustand, Bewertung, Version. Feste Breiten ließen dem Namen bei 1358 pt nur „c…er“
/// (Mangel 4, #480); jetzt schrumpfen zuerst die Nebenspalten.
enum ExtensionTableLayout {
    static let columns = InstrumentColumns([
        .name(minimum: 180), .fixed(190, minimum: 110), .fixed(160, minimum: 110), .fixed(110, minimum: 90),
        .fixed(80, minimum: 64),
    ], spacing: InstrumentSpacing.inline)
    /// Kleinste Breite der Tabelle samt Innenabständen von Zeilen und Abschnitten.
    static let minimumWidth = columns.minimumWidth + 4 * InstrumentSpacing.group
    /// Breite des ruhigen Urteils ohne fremde Erweiterungen.
    static let calmWidth: CGFloat = 520
}

private struct ExtensionTableHeader: View {
    var body: some View {
        InstrumentColumnsLayout(ExtensionTableLayout.columns, alignment: .bottom) {
            header(String(localized: "Erweiterung"))
                .padding(.leading, InstrumentSize.rowIconTall + InstrumentSpacing.group)
            header(String(localized: "Hersteller"))
            header(String(localized: "Zustand"))
            header(String(localized: "Bewertung"))
            HeatColumnHeader(title: String(localized: "Version"), value: "", heat: nil, sortAscending: nil,
                             alignment: .trailing)
                .padding(.horizontal, InstrumentSpacing.inline)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, InstrumentSpacing.bar)
        .padding(.vertical, InstrumentSpacing.cell)
    }

    private func header(_ title: String) -> some View {
        HeatColumnHeader(title: title, value: "", heat: nil, sortAscending: nil, alignment: .leading)
            .padding(.horizontal, InstrumentSpacing.inline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Die Zeilen in Abschnitten nach Schicht, ohne eigenen Bildlauf (auch für Bilder).
private struct ExtensionTableRows: View {
    let sections: [ExtensionLayerContent]
    @Binding var selection: ExtensionRowContent.ID?

    var body: some View {
        LazyVStack(spacing: InstrumentSpacing.stack) {
            ForEach(sections) { section in
                InstrumentSectionHeader(title: section.title, count: section.rows.count,
                                        finding: section.findingCount > 0)
                ForEach(section.rows) { row in
                    ExtensionRowView(row: row, isSelected: selection == row.id)
                        .equatable()
                        .selectableRow { selection = row.id }
                }
            }
        }
        .padding(.horizontal, InstrumentSpacing.group)
        .padding(.vertical, InstrumentSpacing.item)
        // Im Bild ohne Bildlauf (`ChartScrollView`) schneidet das Panel überzählige Zeilen unten ab, statt mit ihnen
        // über Suche und Detail zu wachsen; im Bildlauf bleibt es bei der natürlichen Höhe.
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .layoutPriority(1)
    }
}

private struct ExtensionRowView: View, Equatable {
    let row: ExtensionRowContent
    let isSelected: Bool

    var body: some View {
        InstrumentColumnsLayout(ExtensionTableLayout.columns) {
            HStack(spacing: InstrumentSpacing.group) {
                ExtensionSymbol(symbol: row.symbol, size: InstrumentSize.rowIconTall)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: InstrumentSpacing.inline) {
                        if row.isFinding { FindingDot(size: InstrumentSize.findingDotSmall) }
                        Text(verbatim: row.title).font(InstrumentFont.body).lineLimit(1).truncationMode(.middle)
                    }
                    Text(verbatim: row.kind).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary).lineLimit(1)
                }
            }
            .padding(.horizontal, InstrumentSpacing.inline)
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: row.vendor).font(InstrumentFont.body).lineLimit(1).truncationMode(.tail)
                Text(verbatim: row.vendorDetail).font(InstrumentFont.label.monospaced())
                    .foregroundStyle(.instrumentSecondary).lineLimit(1)
            }
            .padding(.horizontal, InstrumentSpacing.inline)
            .frame(maxWidth: .infinity, alignment: .leading)
            StatusChip(row.state)
                .padding(.horizontal, InstrumentSpacing.inline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if let rating = row.rating {
                    StatusChip(rating)
                } else {
                    Text(verbatim: "–").font(InstrumentFont.body).foregroundStyle(.instrumentSecondary)
                }
            }
            .padding(.horizontal, InstrumentSpacing.inline)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: row.version).font(InstrumentFont.numeric).lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, InstrumentSpacing.inline)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, InstrumentSpacing.group)
        .padding(.vertical, InstrumentSpacing.inline)
        .instrumentRowBackground(isSelected: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: row.accessibilityLabel))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("extensionRow")
    }
}

/// Symbol der Art im Kreis (dekorativ; die Art steht als Text daneben).
struct ExtensionSymbol: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(size > InstrumentSize.rowIconTall ? InstrumentFont.title : InstrumentFont.rowIcon)
            .foregroundStyle(.instrumentSecondary)
            .frame(width: size, height: size)
            .background(Circle().fill(.primary.opacity(InstrumentOpacity.well)))
            .accessibilityHidden(true)
    }
}

// MARK: - Ruhiges Urteil

/// Ohne fremde Erweiterungen: Schild, Urteil und was Grantry geprüft hat, mittig im Panel – ein ruhiges Urteil statt
/// einer leeren Tabelle.
private struct ExtensionCalmPanel: View {
    let calm: ExtensionCalmContent

    @Environment(\.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            HStack(spacing: InstrumentSpacing.page) {
                ShieldBadge(finding: false)
                VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                    Text(verbatim: calm.title).font(InstrumentFont.verdict).accessibilityAddTraits(.isHeader)
                    Text(verbatim: calm.reason).font(InstrumentFont.body).foregroundStyle(.instrumentSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            Text("Geprüft").font(InstrumentFont.title).accessibilityAddTraits(.isHeader)
            ForEach(calm.checks, id: \.self) { check in
                Label {
                    Text(verbatim: check).font(InstrumentFont.body)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(environment.statusColor(.positive))
                }
            }
            if let note = calm.note {
                Label { Text(verbatim: note) } icon: { Image(systemName: "info.circle") }
                    .font(InstrumentFont.label)
                    .foregroundStyle(.instrumentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: ExtensionTableLayout.calmWidth)
        .padding(InstrumentSpacing.empty)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .instrumentPanel()
    }
}
