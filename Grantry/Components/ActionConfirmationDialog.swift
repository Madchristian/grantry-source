import GrantryCharts
import ManagerKit
import SwiftUI

extension View {
    /// Bestätigung vor einer verändernden Aktion (Spec §5): Titel, Klartext und Hinweis aus `ActionConfirmation`,
    /// destruktive Aktionen mit Warnsymbol im Ton „auffällig“ und rotem Knopf. `item` wird beim Schließen zurückgesetzt.
    ///
    /// Bewusst ein eigenes Blatt statt `confirmationDialog`: Dort macht macOS die erste Aktion zur Standardtaste,
    /// sodass Return die (destruktive) Aktion auslöst. Hier lösen Return **und** Escape nur „Abbrechen“ aus; die
    /// Aktion selbst hat keine Tastenbelegung und läuft nur nach einem ausdrücklichen Klick bzw. – mit
    /// Tastaturnavigation – nachdem der Fokus bewusst auf sie gesetzt wurde.
    func actionConfirmation<Item>(
        for item: Binding<Item?>,
        confirmation: @escaping (Item) -> ActionConfirmation,
        perform: @escaping (Item) -> Void
    ) -> some View {
        sheet(isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })) {
            RetainingConfirmationSheet(value: item.wrappedValue, confirmation: confirmation, perform: perform)
        }
    }
}

/// Hält den Wert, mit dem das Blatt geöffnet wurde: Beim Schließen wird `item` schon vor dem Ende der Animation
/// `nil`, das Blatt bliebe sonst währenddessen leer.
private struct RetainingConfirmationSheet<Item>: View {
    @State private var value: Item?
    let confirmation: (Item) -> ActionConfirmation
    let perform: (Item) -> Void

    init(value: Item?, confirmation: @escaping (Item) -> ActionConfirmation, perform: @escaping (Item) -> Void) {
        _value = State(initialValue: value)
        self.confirmation = confirmation
        self.perform = perform
    }

    var body: some View {
        if let value {
            ActionConfirmationSheet(confirmation: confirmation(value)) { perform(value) }
        }
    }
}

/// Inhalt des Bestätigungsblatts; Knöpfe und Tastenbelegung aus `ConfirmationButtonRow`. Gestaltung nur über Tokens
/// und Zustandstöne (Spec 2026-11-10 §10, Entscheidung 5): Aufbau, Texte und Standardknopf bleiben.
struct ActionConfirmationSheet: View {
    let confirmation: ActionConfirmation
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.bar) {
            HStack(alignment: .top, spacing: InstrumentSpacing.page) {
                Image(systemName: confirmation.isDestructive ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
                    .font(InstrumentFont.display)
                    .foregroundStyle(environment.statusColor(confirmation.isDestructive ? .finding : .info))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: InstrumentSpacing.group) {
                    Text(verbatim: confirmation.title)
                        .font(InstrumentFont.title)
                    if let message = confirmation.message {
                        Text(verbatim: message)
                    }
                    if let note = confirmation.note {
                        Text(verbatim: note)
                            .fontWeight(.semibold)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            ConfirmationButtonRow(
                confirm: .init(title: confirmation.confirmTitle, isDestructive: confirmation.isDestructive) {
                    dismiss()
                    confirm()
                },
                cancel: { dismiss() }
            )
        }
        .padding(InstrumentSpacing.empty)
        .frame(width: 440)
    }
}

/// Knopfzeile aller Bestätigungsblätter. „Abbrechen“ ist Standard- und Abbruchtaste (Return, Escape) und hat den
/// Anfangsfokus. Die Aktion hat kein Tastenkürzel, bleibt aber für die Tastaturnavigation (Tab, Leertaste)
/// erreichbar. Ohne Aktion (`confirm == nil`) bleibt nur der Abbrechen-Knopf, z. B. „Schließen“.
struct ConfirmationButtonRow: View {
    /// Die bestätigte Aktion.
    struct Confirm {
        let title: String
        let isDestructive: Bool
        var isEnabled = true
        let action: () -> Void
    }

    var cancelTitle: LocalizedStringKey = "Abbrechen"
    let confirm: Confirm?
    let cancel: () -> Void
    @FocusState private var focusedButton: SheetButton?

    private enum SheetButton: Hashable {
        case cancel, confirm
    }

    var body: some View {
        HStack(spacing: InstrumentSpacing.group) {
            Spacer()
            Button(cancelTitle, role: .cancel, action: cancel)
                .keyboardShortcut(.defaultAction)
                .focused($focusedButton, equals: .cancel)
            if let confirm {
                Button(role: confirm.isDestructive ? .destructive : nil, action: confirm.action) {
                    Text(verbatim: confirm.title)
                }
                .disabled(!confirm.isEnabled)
                .focused($focusedButton, equals: .confirm)
            }
        }
        .background { escapeShortcut }
        .defaultFocus($focusedButton, .cancel)
    }

    /// Escape → „Abbrechen“. Ein Knopf trägt nur ein Tastenkürzel (der sichtbare hat Return), und `onExitCommand`
    /// erreicht ein Blatt ohne fokussiertes Element nicht – daher ein unsichtbarer zweiter Abbrechen-Knopf.
    private var escapeShortcut: some View {
        Button(cancelTitle, action: cancel)
            .keyboardShortcut(.cancelAction)
            .hidden()
            .accessibilityHidden(true)
    }
}
