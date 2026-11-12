import SwiftUI

/// Eine Prüfung für Prüfzeile und Prüfpanel: Symbol, Name, Grund in einem Satz und Zustand als Chip; aufgeklappt
/// Erklärung und Details. Die Texte kommen fertig aus der Darstellung, die Aktionen liefert die Ansicht.
public struct CheckItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let symbol: String
    public let title: String
    public let reason: String
    public let status: StatusItem
    public let explanation: String?
    public let details: [String]

    public init(id: String, symbol: String, title: String, reason: String, status: StatusItem,
                explanation: String? = nil, details: [String] = []) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.reason = reason
        self.status = status
        self.explanation = explanation
        self.details = details
    }

    /// VoiceOver: „Name: Zustand. Grund“.
    var accessibilityLabel: String { "\(title): \(status.text). \(reason)" }
}

/// Prüfzeile: zweizeilig wie eine Tabellenzeile (§3.7) – Symbol im Kreis, Name und Grund, rechts Zustandschip und
/// Aufklapp-Pfeil. Gewählt mit Fläche und Fokusleiste und aufgeklappt: Erklärung, Details und die Aktionen der Ansicht.
/// Auf- und Zuklappen ohne Übergang (§5).
public struct CheckRow<Actions: View>: View {
    let item: CheckItem
    let isSelected: Bool
    let onSelect: () -> Void
    let actions: Actions

    public init(item: CheckItem, isSelected: Bool, onSelect: @escaping () -> Void,
                @ViewBuilder actions: () -> Actions) {
        self.item = item
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.actions = actions()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
            Button(action: onSelect) {
                InstrumentRowHead(symbol: item.symbol, title: item.title, reason: item.reason, status: item.status,
                                  accessory: .disclosure(isExpanded: isSelected))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: item.accessibilityLabel))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityHint(isSelected ? Text("Klappt die Prüfung zu.") : Text("Zeigt Erklärung und Aktionen."))
            .accessibilityIdentifier(item.id)
            if isSelected {
                VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
                    if let explanation = item.explanation {
                        Text(verbatim: explanation).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(item.details, id: \.self) { line in
                        Text(verbatim: line).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                    }
                    actions.font(InstrumentFont.body)
                }
                .padding(.leading, InstrumentSize.rowIconTall + InstrumentSpacing.cell)
            }
        }
        .padding(.horizontal, InstrumentSpacing.group)
        .padding(.vertical, InstrumentSpacing.item)
        .instrumentRowBackground(isSelected: isSelected)
        .accessibilityElement(children: .contain)
    }
}

extension CheckRow where Actions == EmptyView {
    public init(item: CheckItem, isSelected: Bool, onSelect: @escaping () -> Void) {
        self.init(item: item, isSelected: isSelected, onSelect: onSelect) { EmptyView() }
    }
}

/// Kopf einer zweizeiligen Zeile (§3.10a): Symbol im 26-pt-Kreis, Name und Grund, rechts Zustandschip und Pfeil – in der
/// Prüfzeile der Aufklapp-Pfeil, in der Sprungzeile der Pfeil in einen anderen Bereich.
struct InstrumentRowHead: View {
    enum Accessory {
        case disclosure(isExpanded: Bool)
        case jump
    }

    let symbol: String
    let title: String
    let reason: String
    let status: StatusItem?
    let accessory: Accessory

    var body: some View {
        HStack(spacing: InstrumentSpacing.cell) {
            InstrumentRowIcon(symbol: symbol)
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                Text(verbatim: title).font(InstrumentFont.body.weight(.semibold)).lineLimit(1)
                // Zwei Zeilen auch neben einem breiten Chip, sonst kürzt das Layout den Grund auf eine (#553).
                Text(verbatim: reason).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: InstrumentSpacing.group)
            if let status { StatusChip(status) }
            Image(systemName: accessorySymbol)
                .font(InstrumentFont.label.weight(.semibold))
                .foregroundStyle(.instrumentSecondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: InstrumentSize.disclosure, height: InstrumentSize.disclosure)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    private var accessorySymbol: String {
        switch accessory {
        case .disclosure: "chevron.right"
        case .jump: "arrow.right"
        }
    }

    private var isExpanded: Bool {
        if case .disclosure(isExpanded: true) = accessory { true } else { false }
    }
}

/// Prüfpanel: Peilkopf ohne Ring (keine Messgröße, §3.3), auf Wunsch ein Hinweis mit `info.circle` (§3.11, etwa ohne
/// Helper), darunter die Prüfzeilen. Höchstens eine Zeile ist gewählt und aufgeklappt; ein Klick auf die gewählte
/// klappt sie zu.
public struct CheckPanel<Actions: View>: View {
    let title: String
    let detail: String
    let value: String
    let finding: Bool
    let note: String?
    let items: [CheckItem]
    @Binding var selection: CheckItem.ID?
    let actions: (CheckItem) -> Actions

    public init(_ title: String, detail: String, value: String = "", finding: Bool = false, note: String? = nil,
                items: [CheckItem], selection: Binding<CheckItem.ID?>,
                @ViewBuilder actions: @escaping (CheckItem) -> Actions) {
        self.title = title
        self.detail = detail
        self.value = value
        self.finding = finding
        self.note = note
        self.items = items
        _selection = selection
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
            PeilHead(title, detail: detail, value: value, finding: finding)
            if let note {
                Label { Text(verbatim: note) } icon: { Image(systemName: "info.circle") }
                    .font(InstrumentFont.label)
                    .foregroundStyle(.instrumentSecondary)
            }
            CheckRows(items: items, selection: $selection, actions: actions)
        }
        .instrumentPanel()
    }
}

/// Prüfzeilen untereinander (§3.10a), etwa im Prüfpanel oder in der Einrichtung der Einstellungen und des Onboardings:
/// höchstens eine Zeile ist gewählt und aufgeklappt; ein Klick auf die gewählte klappt sie zu. Jede Zeile trägt ihre
/// Kennung als `id` (Sprung und Rollen).
public struct CheckRows<Actions: View>: View {
    let items: [CheckItem]
    @Binding var selection: CheckItem.ID?
    let actions: (CheckItem) -> Actions

    public init(items: [CheckItem], selection: Binding<CheckItem.ID?>,
                @ViewBuilder actions: @escaping (CheckItem) -> Actions) {
        self.items = items
        _selection = selection
        self.actions = actions
    }

    public var body: some View {
        VStack(spacing: InstrumentSpacing.stack) {
            ForEach(items) { item in
                CheckRow(item: item, isSelected: selection == item.id,
                         onSelect: { selection = selection == item.id ? nil : item.id }) {
                    actions(item)
                }
                .id(item.id)
            }
        }
    }
}
