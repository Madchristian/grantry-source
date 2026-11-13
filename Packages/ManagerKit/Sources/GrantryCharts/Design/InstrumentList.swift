import SwiftUI

// Auswahlliste im Panel (LB-1.2, #536; Spec 2026-11-10 §4.2, Entscheidung 1): ersetzt die native `List(selection:)`,
// deren Auswahl die Systemakzentfarbe trägt. Gruppenköpfe wie in gruppierten Tabellen, gewählte Zeile mit Fläche und
// Fokusleiste im Grantry-Verlauf, Befund-Punkt am Symbol; Pfeiltasten, Return, Kontextmenü und VoiceOver mit
// `isSelected`. Lazy für lange Listen (Apps), ohne Timer, ohne Übergang beim Wählen oder Sortieren (Spec §8).

/// Eintrag der Auswahlliste: stabile Kennung und Zeileninhalt; auf Wunsch die Kennung der UI- und Performance-Tests.
public struct InstrumentListItem<ID: Hashable & Sendable>: Identifiable, Hashable, Sendable {
    public let id: ID
    public let content: InstrumentRowContent
    public let accessibilityIdentifier: String?

    public init(id: ID, content: InstrumentRowContent, accessibilityIdentifier: String? = nil) {
        self.id = id
        self.content = content
        self.accessibilityIdentifier = accessibilityIdentifier
    }
}

/// Gruppe der Auswahlliste mit Kopf (`InstrumentSectionHeader`): Leiste im Ton oder Befund-Punkt, Titel und Anzahl.
public struct InstrumentListSection<ID: Hashable & Sendable>: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let tone: StatusTone
    public let finding: Bool
    public let items: [InstrumentListItem<ID>]

    public init(id: String, title: String, tone: StatusTone = .neutral, finding: Bool = false,
                items: [InstrumentListItem<ID>]) {
        self.id = id
        self.title = title
        self.tone = tone
        self.finding = finding
        self.items = items
    }

    /// Kennungen in Anzeigereihenfolge über alle Gruppen – die Reihenfolge der Pfeiltasten.
    public static func orderedIDs(_ sections: [Self]) -> [ID] {
        sections.flatMap { $0.items.map(\.id) }
    }
}

/// Kopf oder Zeile der Auswahlliste in Anzeigereihenfolge – eine flache Folge mit eindeutigen Kennungen, damit eine Zeile
/// beim Wechsel der Gruppe ihre Identität behält und neu gezeichnet wird (#617).
enum InstrumentListEntry<ID: Hashable & Sendable>: Identifiable {
    enum Key: Hashable {
        case header(String)
        case row(ID)
    }

    case header(InstrumentListSection<ID>)
    case row(InstrumentListItem<ID>)

    var id: Key {
        switch self {
        case .header(let section): .header(section.id)
        case .row(let item): .row(item.id)
        }
    }

    static func entries(_ sections: [InstrumentListSection<ID>]) -> [Self] {
        sections.flatMap { [.header($0)] + $0.items.map(Self.row) }
    }
}

/// Pfeiltasten der Auswahlliste: nächste bzw. vorige Zeile, an den Enden stehen bleiben. Ohne (sichtbare) Auswahl
/// beginnt Pfeil runter vorn und Pfeil hoch hinten.
public enum InstrumentListNavigation {
    public enum Direction: Sendable {
        case up, down
    }

    public static func target<ID: Hashable>(from selection: ID?, in ids: [ID], direction: Direction) -> ID? {
        guard let selection, let index = ids.firstIndex(of: selection) else {
            return direction == .down ? ids.first : ids.last
        }
        let next = direction == .down ? min(index + 1, ids.count - 1) : max(index - 1, 0)
        return ids[next]
    }
}

/// Zeile der Auswahlliste: gewählt mit Fläche und Fokusleiste im Grantry-Verlauf. Für VoiceOver ein Element mit dem Namen
/// als Beschriftung, „Zustand. Detail“ als Wert, Knopf und `isSelected`.
public struct InstrumentListRow<Icon: View>: View {
    let content: InstrumentRowContent
    let isSelected: Bool
    let icon: Icon

    public init(_ content: InstrumentRowContent, isSelected: Bool, @ViewBuilder icon: () -> Icon) {
        self.content = content
        self.isSelected = isSelected
        self.icon = icon()
    }

    public var body: some View {
        InstrumentRowLabel(content) { icon }
            .padding(.horizontal, InstrumentSpacing.group)
            .padding(.vertical, InstrumentSpacing.item)
            .instrumentRowBackground(isSelected: isSelected)
            .renderProbe("InstrumentListRow")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: content.title))
            // ax-value: Zeile mit Merkmal Knopf, behält ihre Rolle und damit den Wert.
            .accessibilityValue(Text(verbatim: content.spokenValue))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

extension InstrumentListRow where Icon == InstrumentRowIcon {
    public init(_ content: InstrumentRowContent, isSelected: Bool) {
        self.init(content, isSelected: isSelected) { InstrumentRowIcon(symbol: content.symbol) }
    }
}

/// Auswahlliste im Panel: Kopf mit Titel und Anzahl, Gruppen, Zeilen. Ein Klick wählt, Pfeiltasten wählen die nächste
/// bzw. vorige Zeile und rollen sie ins Bild, Return ruft `onOpen` mit der Auswahl, ein Rechtsklick das Kontextmenü der
/// Zeile. Die Auswahl liegt beim Bereich (`selection`); die Liste ändert nichts außer ihr.
public struct InstrumentList<ID: Hashable & Sendable, Icon: View, Menu: View>: View {
    let title: String
    let count: String
    let sections: [InstrumentListSection<ID>]
    @Binding var selection: ID?
    let onOpen: ((ID) -> Void)?
    let icon: (InstrumentListItem<ID>) -> Icon
    let menu: (ID) -> Menu

    public init(_ title: String, count: String, sections: [InstrumentListSection<ID>], selection: Binding<ID?>,
                onOpen: ((ID) -> Void)? = nil, @ViewBuilder icon: @escaping (InstrumentListItem<ID>) -> Icon,
                @ViewBuilder contextMenu: @escaping (ID) -> Menu) {
        self.title = title
        self.count = count
        self.sections = sections
        _selection = selection
        self.onOpen = onOpen
        self.icon = icon
        self.menu = contextMenu
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: InstrumentSpacing.item) {
                Text(verbatim: title).font(InstrumentFont.title)
                Spacer(minLength: InstrumentSpacing.group)
                Text(verbatim: count).font(InstrumentFont.label.monospacedDigit()).foregroundStyle(.instrumentSecondary)
            }
            .padding(.horizontal, InstrumentSpacing.panel)
            .padding(.vertical, InstrumentSpacing.cell)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Divider()
            ScrollViewReader { proxy in
                ChartScrollView(showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                        // Ein `ForEach` über Köpfe und Zeilen: Wechselt eine Zeile die Gruppe (etwa nach „Risiko
                        // akzeptieren“ von „Mit Befund“ nach „Übrige“), bleibt sie dasselbe Element und zeigt ihren neuen
                        // Inhalt. Verschachtelt behielt die verschobene Zeile ihren alten Inhalt (#617).
                        ForEach(InstrumentListEntry.entries(sections)) { entry in
                            switch entry {
                            case .header(let section):
                                InstrumentSectionHeader(title: section.title, count: section.items.count,
                                                        tone: section.tone, finding: section.finding)
                            case .row(let item):
                                row(item)
                            }
                        }
                    }
                    .padding(InstrumentSpacing.item)
                }
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { move(.down) }
                .onKeyPress(.upArrow) { move(.up) }
                // Jede neue Auswahl ins Bild rollen, ohne Übergang: Pfeiltasten und Sprünge aus anderen Bereichen, die
                // die Auswahl von außen setzen (LB-2.2, #539). Eine sichtbare Zeile bleibt, wo sie ist.
                .onChange(of: selection) { _, target in
                    if let target { proxy.scrollTo(target) }
                }
                .onKeyPress(.return) {
                    guard let selection, let onOpen else { return .ignored }
                    onOpen(selection)
                    return .handled
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: InstrumentRadius.panel, style: .continuous))
        .instrumentPanel(padding: 0)
    }

    private func row(_ item: InstrumentListItem<ID>) -> some View {
        InstrumentListRow(item.content, isSelected: item.id == selection) { icon(item) }
            .id(item.id)
            .selectableRow { selection = item.id }
            .contextMenu { menu(item.id) }
            .accessibilityIdentifier(item.accessibilityIdentifier ?? "")
    }

    /// Wählt die nächste bzw. vorige Zeile; ins Bild rollt sie `onChange(of: selection)`.
    private func move(_ direction: InstrumentListNavigation.Direction) -> KeyPress.Result {
        let ids = InstrumentListSection.orderedIDs(sections)
        guard let target = InstrumentListNavigation.target(from: selection, in: ids, direction: direction) else {
            return .ignored
        }
        selection = target
        return .handled
    }
}

extension InstrumentList where Icon == InstrumentRowIcon, Menu == EmptyView {
    public init(_ title: String, count: String, sections: [InstrumentListSection<ID>], selection: Binding<ID?>,
                onOpen: ((ID) -> Void)? = nil) {
        self.init(title, count: count, sections: sections, selection: selection, onOpen: onOpen,
                  icon: { InstrumentRowIcon(symbol: $0.content.symbol) }, contextMenu: { _ in EmptyView() })
    }
}

extension InstrumentList where Icon == InstrumentRowIcon {
    public init(_ title: String, count: String, sections: [InstrumentListSection<ID>], selection: Binding<ID?>,
                onOpen: ((ID) -> Void)? = nil, @ViewBuilder contextMenu: @escaping (ID) -> Menu) {
        self.init(title, count: count, sections: sections, selection: selection, onOpen: onOpen,
                  icon: { InstrumentRowIcon(symbol: $0.content.symbol) }, contextMenu: contextMenu)
    }
}

extension InstrumentList where Menu == EmptyView {
    public init(_ title: String, count: String, sections: [InstrumentListSection<ID>], selection: Binding<ID?>,
                onOpen: ((ID) -> Void)? = nil, @ViewBuilder icon: @escaping (InstrumentListItem<ID>) -> Icon) {
        self.init(title, count: count, sections: sections, selection: selection, onOpen: onOpen, icon: icon,
                  contextMenu: { _ in EmptyView() })
    }
}
