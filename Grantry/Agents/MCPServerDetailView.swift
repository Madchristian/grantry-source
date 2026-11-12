import GrantryCharts
import ManagerKit
import SwiftUI

/// Ein MCP-Server im Detail (Spec Agenten §7; LB-2.4, #541): Start (Befehl bzw. URL, maskiert), Paketquelle, Umgebung
/// und Header nur mit Namen, Konfigurationsdatei mit „Im Finder zeigen“ und „Öffnen“, Rechte des Starters als Sprungzeilen
/// in „Berechtigungen“; Knopfzeile „Deaktivieren“/„Aktivieren“ (wo das Format einen Schalter kennt) und „Server entfernen …“
/// (Stufe 2) mit unveränderten Bestätigungen. Befehle und Argumente bearbeitet Grantry nicht.
struct MCPServerDetailView: View {
    let detail: MCPServerDetail
    let badges: [RecordBadge]
    let actions: ActionRunner
    @Environment(MainWindowModel.self) private var window
    @State private var pendingAction: AgentServerAction?
    /// Zuletzt bestätigte Aktion – benennt die laufende Aktion neben den Knöpfen.
    @State private var confirmedAction: AgentServerAction?

    private var entry: MCPServerEntry { detail.entry }

    var body: some View {
        RecordDetailPanel(content: AgentsBoardMapping.serverDetail(detail, badges: badges)) {
            InstrumentRowIcon(symbol: entry.symbol, size: InstrumentSize.shield)
        } actions: {
            actionRow
        } accessory: { group in
            switch group.id {
            case AgentsBoardMapping.GroupID.configuration: ConfigFileControls(path: entry.configPath)
            case AgentsBoardMapping.GroupID.starter: starterGrants
            default: EmptyView()
            }
        }
        .actionConfirmation(for: $pendingAction, confirmation: \.confirmation) { action in
            confirmedAction = action
            Task { await action.perform(with: actions, context: .agents) }
        }
    }

    // MARK: - Aktionen

    /// Knopfzeile unter dem Kopf (Spec §11.2 d); ohne Schreibrecht nur der Grund.
    @ViewBuilder
    private var actionRow: some View {
        switch detail.editing.availability {
        case .available:
            DetailActions(runningText: runningText) {
                if detail.editing.canSwitch, let isEnabled = entry.isEnabled {
                    Button(isEnabled ? "Deaktivieren" : "Aktivieren") {
                        pendingAction = .setEnabled(entry, !isEnabled, detail.editing)
                    }
                    .disabled(!actions.canStart)
                }
                Button("Server entfernen …", role: .destructive) { pendingAction = .remove(entry, detail.editing) }
                    .disabled(!actions.canStart)
            }
        case .readOnly(let reason):
            InstrumentNote(reason.description, kind: .locked)
        }
    }

    /// Text der laufenden Aktion an diesem Server; `nil`, solange keine läuft.
    private var runningText: String? {
        guard actions.runningRecordID == entry.id else { return nil }
        return confirmedAction?.runningText ?? String(localized: "Aktion läuft")
    }

    // MARK: - Rechte des Starters

    @ViewBuilder
    private var starterGrants: some View {
        ForEach(detail.starter.grants) { grant in
            JumpRow(AgentsBoardMapping.starterGrant(grant), destination: MainSection.permissions.title) {
                window.show(grant)
            } icon: {
                ServiceIconView(service: PermissionCatalog.service(for: grant.service), size: InstrumentSize.rowIconTall)
            }
        }
    }
}

/// Eine bestätigungspflichtige Aktion an einem MCP-Server.
private enum AgentServerAction {
    case setEnabled(MCPServerEntry, Bool, AgentEditCapabilities)
    case remove(MCPServerEntry, AgentEditCapabilities)

    var confirmation: ActionConfirmation {
        switch self {
        case .setEnabled(let entry, let enabled, let capabilities): .setServerEnabled(entry, enabled, capabilities: capabilities)
        case .remove(let entry, let capabilities): .removeServer(entry, capabilities: capabilities)
        }
    }

    /// Text neben den Knöpfen, solange die Aktion läuft.
    var runningText: String {
        switch self {
        case .setEnabled(_, true, _): String(localized: "Wird aktiviert …")
        case .setEnabled(_, false, _): String(localized: "Wird deaktiviert …")
        case .remove: String(localized: "Wird entfernt …")
        }
    }

    func perform(with actions: ActionRunner, context: ActionContext) async {
        switch self {
        case .setEnabled(let entry, let enabled, _): await actions.setServerEnabled(entry, enabled, context: context)
        case .remove(let entry, _): await actions.removeServer(entry, context: context)
        }
    }
}

#if DEBUG
#Preview("Lokal mit Geheimnis") {
    let presentation = AgentPreviewData.presentation
    MCPServerDetailView(detail: presentation.agentDetail(for: AgentPreviewData.localServer),
                        badges: presentation.badges.badges(for: AgentPreviewData.localServer.id),
                        actions: ActionRunner(helperActivity: HelperActivityLock(), coordinator: nil))
        .environment(MainWindowModel())
        .frame(width: 520, height: 820)
}

#Preview("Entfernt über http") {
    let presentation = AgentPreviewData.presentation
    MCPServerDetailView(detail: presentation.agentDetail(for: AgentPreviewData.remoteServer),
                        badges: presentation.badges.badges(for: AgentPreviewData.remoteServer.id),
                        actions: ActionRunner(helperActivity: HelperActivityLock(), coordinator: nil))
        .environment(MainWindowModel())
        .frame(width: 520, height: 700)
}
#endif
