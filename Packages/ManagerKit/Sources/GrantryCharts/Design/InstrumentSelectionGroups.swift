import SwiftUI

// Gruppen der Fundlisten im Bereich Aufräumen und im Blatt „App entfernen“ (LB-4.2, #548; Entwurf LB-4.1, #547,
// Spec 2026-11-10 § 11.4 c, d, g): Gruppenkopf mit Summe, aufklappbarer Kopf und Ausgang einer Aktion je Eintrag.
// Auf- und Zuklappen ohne Übergang (§ 5).

/// Gruppenkopf einer Fundliste (Kennung einer gelöschten App, Art der Reste, Abschnitt) mit Anzahl und rechts der Summe.
/// Für VoiceOver eine Überschrift mit dem Titel als Beschriftung, Anzahl und Summe als Wert.
public struct SelectionGroupHeader: View {
    let title: String
    let count: Int
    let size: String?
    let finding: Bool

    /// - Parameter finding: Befund-Punkt statt der Leiste (etwa „Erweiterungen ohne App“).
    public init(title: String, count: Int, size: String? = nil, finding: Bool = false) {
        self.title = title
        self.count = count
        self.size = size
        self.finding = finding
    }

    public var body: some View {
        HStack(spacing: 0) {
            InstrumentSectionHeader(title: title, count: count, finding: finding)
            if let size {
                Text(verbatim: size).font(InstrumentFont.label.monospacedDigit()).foregroundStyle(.instrumentSecondary)
                    .padding(.trailing, InstrumentSpacing.group)
                    .padding(.top, InstrumentSpacing.group)
            }
        }
        .accessibilityReading(Text(verbatim: title), value: Text(verbatim: Self.spokenValue(count: count, size: size)))
        .accessibilityAddTraits(.isHeader)
    }

    /// „3 Einträge, Summe 1,5 GB“.
    nonisolated static func spokenValue(count: Int, size: String?) -> String {
        let entries = count == 1 ? String(localized: "1 Eintrag") : String(localized: "\(count) Einträge")
        return [entries, size.map { String(localized: "Summe \($0)") }].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Aufklappbarer Kopf (Spec § 11.4 c und g): Pfeil, daneben der Kopf der Ansicht (Speicher-Kategorie, Agenten-Baum),
/// aufgeklappt darunter der Inhalt eingerückt bündig mit dem Kopf. Mit `togglesOnHead` ist der ganze Kopf ein Knopf
/// (Kopf ohne eigene Bedienelemente); sonst nur der Pfeil, damit eine Häkchenzeile im Kopf ihr Häkchen behält.
/// VoiceOver: Knopf mit dem Titel als Beschriftung, `value` und „aufgeklappt“ bzw. „zugeklappt“ als Wert.
public struct DisclosureSection<Head: View, Content: View>: View {
    let title: String
    let value: String
    @Binding var isExpanded: Bool
    let togglesOnHead: Bool
    let head: Head
    let content: Content

    public init(_ title: String, value: String = "", isExpanded: Binding<Bool>, togglesOnHead: Bool = false,
                @ViewBuilder head: () -> Head, @ViewBuilder content: () -> Content) {
        self.title = title
        self.value = value
        _isExpanded = isExpanded
        self.togglesOnHead = togglesOnHead
        self.head = head()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
            if togglesOnHead {
                Button(action: toggle) {
                    HStack(spacing: InstrumentSpacing.cell) {
                        chevron
                        head
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .modifier(DisclosureAccessibility(title: title, value: spokenValue))
            } else {
                HStack(spacing: InstrumentSpacing.cell) {
                    Button(action: toggle) { chevron.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .modifier(DisclosureAccessibility(title: title, value: spokenValue))
                    head
                }
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: InstrumentSpacing.stack) { content }
                    .padding(.leading, InstrumentSize.disclosure + InstrumentSpacing.cell)
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(InstrumentFont.label.weight(.semibold))
            .foregroundStyle(.instrumentSecondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: InstrumentSize.disclosure, height: InstrumentSize.disclosure)
    }

    private var spokenValue: String { Self.spokenValue(value, isExpanded: isExpanded) }

    private func toggle() {
        isExpanded.toggle()
    }

    /// „12 GB, aufgeklappt“; ohne Wert nur der Zustand.
    nonisolated static func spokenValue(_ value: String, isExpanded: Bool) -> String {
        let state = isExpanded ? String(localized: "aufgeklappt") : String(localized: "zugeklappt")
        return value.isEmpty ? state : "\(value), \(state)"
    }
}

/// Beschriftung, Wert und Hinweis des Aufklapp-Knopfs.
private struct DisclosureAccessibility: ViewModifier {
    let title: String
    let value: String

    func body(content: Content) -> some View {
        content
            .accessibilityLabel(Text(verbatim: title))
            // ax-value: Aufklapp-Knopf, behält seine Rolle und damit den Wert.
            .accessibilityValue(Text(verbatim: value))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text("Klappt den Inhalt auf oder zu."))
    }
}

/// Ausgang einer Aktion je Eintrag (aufgeräumt, übersprungen, fehlgeschlagen) als Zeile mit Zustandschip (§ 11.4 d);
/// ersetzt Ausgangsmarken in Systemfarben. VoiceOver: Eintrag als Beschriftung, Ausgang und Grund als Wert.
public struct OutcomeRow: View {
    let outcome: StatusItem
    let target: String
    let reason: String?

    public init(_ outcome: StatusItem, target: String, reason: String? = nil) {
        self.outcome = outcome
        self.target = target
        self.reason = reason
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: InstrumentSpacing.group) {
            StatusChip(outcome, isSmall: true)
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                Text(verbatim: target).font(InstrumentFont.label).lineLimit(1).truncationMode(.middle)
                if let reason {
                    Text(verbatim: reason).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, InstrumentSpacing.group)
        .accessibilityReading(Text(verbatim: target), value: Text(verbatim: Self.spokenValue(outcome, reason: reason)))
    }

    /// „übersprungen, wird benutzt“.
    nonisolated static func spokenValue(_ outcome: StatusItem, reason: String?) -> String {
        [outcome.text, reason].compactMap { $0 }.joined(separator: ", ")
    }
}
