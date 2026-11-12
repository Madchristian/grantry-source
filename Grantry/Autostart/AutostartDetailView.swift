import GrantryCharts
import ManagerKit
import SwiftUI

/// Ein Autostart-Eintrag im Detail-Panel des Lagebilds (LB-2.3, #540; Entwurf LB-2.1): Kopf mit Zuständen, Knopfzeile
/// „Deaktivieren“/„Aktivieren“ und „Entfernen …“ direkt darunter, Hinweise, Programm (mit maskiertem, kopierbarem Befehl)
/// und Ort. Schreibgeschützte Einträge nennen den Grund, BTM-Einträge verweisen auf die Anmeldeobjekte in den
/// Systemeinstellungen. Bestätigungen, Texte und Ablauf wie zuvor (`ActionConfirmation.setEnabled`, `.remove`); die
/// Meldung zur Aktion zeigt `AutostartView` oberhalb (`ActionContext.autostart`).
struct AutostartDetailView: View {
    let item: AutostartItem
    let presentation: PresentationSnapshot
    let actions: ActionRunner
    @Environment(\.openURL) private var openURL
    @State private var pendingAction: AutostartAction?
    /// Zuletzt bestätigte Aktion; ihr Text steht neben den Knöpfen, solange sie an diesem Eintrag läuft.
    @State private var startedAction: AutostartAction?

    private static let policy = ActionPolicy()

    var body: some View {
        let availability = Self.policy.availability(for: item)
        RecordDetailPanel(content: AutostartBoardMapping.detail(item, presentation: presentation, now: .now)) {
            AutostartItemIcon(item: item, size: InstrumentSize.shield)
        } actions: {
            // Grund des Schreibschutzes vor der Knopfzeile (Entwurf LB-2.1).
            if let reason = availability.readOnlyReason { InstrumentNote(reason, kind: .locked) }
            actionRow(availability)
        } accessory: { group in
            if group.id == AutostartBoardMapping.programGroupID, let commandLine = item.displayedCommandLine {
                CommandFooter(command: commandLine, note: item.commandNote)
            }
        }
        .actionConfirmation(for: $pendingAction, confirmation: \.confirmation) { action in
            startedAction = action
            Task { await action.perform(with: actions, context: .autostart) }
        }
    }

    @ViewBuilder
    private func actionRow(_ availability: ActionAvailability) -> some View {
        let runningText = actions.runningRecordID == item.id
            ? startedAction?.runningText ?? String(localized: "Aktion läuft …") : nil
        switch availability {
        case .available:
            DetailActions(runningText: runningText) {
                Button(item.isEnabled ? "Deaktivieren" : "Aktivieren") {
                    pendingAction = .setEnabled(item, !item.isEnabled)
                }
                Button("Entfernen …", role: .destructive) { pendingAction = .remove(item) }
            }
            .disabled(!actions.canStart)
        case .readOnly(let reason):
            if let url = reason.settingsURL {
                DetailActions(runningText: runningText) {
                    Button("In Anmeldeobjekten öffnen") { openURL(url) }
                }
            } else if let runningText {
                RunningActionLabel(runningText)
            }
        }
    }
}

/// Hinweis zum angezeigten Befehl (verborgenes Skript, maskierte Werte) und „Befehl kopieren“, eingerückt unter den Wert.
private struct CommandFooter: View {
    let command: String
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
            if let note {
                Text(verbatim: note).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CopyCommandButton(command: command).controlSize(.small)
        }
        .padding(.leading, InstrumentSize.laneLabel + InstrumentSpacing.cell)
    }
}

/// Eine bestätigungspflichtige Aktion an einem Autostart-Eintrag.
private enum AutostartAction {
    case setEnabled(AutostartItem, Bool)
    case remove(AutostartItem)

    var confirmation: ActionConfirmation {
        switch self {
        case .setEnabled(let item, let enabled): .setEnabled(item, enabled)
        case .remove(let item): .remove(item)
        }
    }

    /// Text neben den Knöpfen, solange die Aktion läuft.
    var runningText: String {
        switch self {
        case .setEnabled(_, true): String(localized: "Wird aktiviert …")
        case .setEnabled(_, false): String(localized: "Wird deaktiviert …")
        case .remove: String(localized: "Wird entfernt …")
        }
    }

    func perform(with actions: ActionRunner, context: ActionContext) async {
        switch self {
        case .setEnabled(let item, let enabled): await actions.setEnabled(item, enabled, context: context)
        case .remove(let item): await actions.remove(item, context: context)
        }
    }
}
