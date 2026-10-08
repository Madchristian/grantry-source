import ManagerKit
import SwiftUI

/// Ein MCP-Server im Detail (Spec Agenten §7): Start (Befehl bzw. URL, maskiert), Paketquelle, Umgebung und Header nur
/// mit Namen, Konfigurationsdatei und Rechte des Starters mit Sprung in „Berechtigungen“; Aktionen „Deaktivieren“/
/// „Aktivieren“ (wo das Format einen Schalter kennt) und „Server entfernen …“ (Stufe 2). Befehle und Argumente
/// bearbeitet Grantry nicht.
struct MCPServerDetailView: View {
    let detail: MCPServerDetail
    let badges: [RecordBadge]
    let actions: ActionRunner
    @Environment(MainWindowModel.self) private var window
    @State private var pendingAction: AgentServerAction?

    private var entry: MCPServerEntry { detail.entry }

    var body: some View {
        Form {
            header
            actionSection
            findingsSection
            startSection
            environmentSection
            configurationSection
            starterSection
        }
        .formStyle(.grouped)
        .actionConfirmation(for: $pendingAction, confirmation: \.confirmation) { action in
            Task { await action.perform(with: actions, context: .agents) }
        }
    }

    private var header: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: MainSection.agents.systemImage)
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: entry.name)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    Text(verbatim: entry.locationDescription)
                        .foregroundStyle(.secondary)
                    RecordBadgesRow(badges: badges)
                }
            }
        }
    }

    // MARK: - Aktionen

    private var actionSection: some View {
        Section("Aktionen") {
            HStack(spacing: 8) {
                switch detail.editing.availability {
                case .available:
                    if detail.editing.canSwitch, let isEnabled = entry.isEnabled {
                        Button(isEnabled ? "Deaktivieren" : "Aktivieren") {
                            pendingAction = .setEnabled(entry, !isEnabled, detail.editing)
                        }
                        .disabled(!actions.canStart)
                    }
                    Button("Server entfernen …", role: .destructive) { pendingAction = .remove(entry, detail.editing) }
                        .disabled(!actions.canStart)
                case .readOnly(let reason):
                    HintLabel(text: reason.description, systemImage: "lock", color: .secondary)
                }
                if actions.runningRecordID == entry.id {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Aktion läuft")
                }
            }
        }
    }

    @ViewBuilder
    private var findingsSection: some View {
        if !detail.findings.isEmpty {
            Section("Hinweise") { RecordHints(findings: detail.findings) }
        }
    }

    private var startSection: some View {
        Section("Start") {
            LabeledContent("Art") { Text(verbatim: detail.kindText) }
            if let commandLine = detail.commandLine {
                LabeledContent {
                    CodeText(text: commandLine)
                } label: {
                    Text("Befehl")
                    if let note = detail.commandNote {
                        Text(verbatim: note)
                    }
                }
            }
            if let url = detail.url {
                LabeledContent("Ziel-URL") { CodeText(text: url) }
            }
            LabeledContent("Paketquelle") { Text(verbatim: detail.packageText).textSelection(.enabled) }
            if case .localProgram = entry.packageSource {
                LabeledContent("Signatur") { SigningLabel(signing: entry.programSigning ?? .unknown) }
            }
            if let enabledText = detail.enabledText {
                LabeledContent("Zustand") { Text(verbatim: enabledText) }
            }
        }
    }

    @ViewBuilder
    private var environmentSection: some View {
        if !detail.environment.isEmpty || !detail.headers.isEmpty {
            Section {
                ForEach(detail.environment) { key in
                    NamedKeyRow(key: key, kind: String(localized: "Umgebungsvariable"))
                }
                ForEach(detail.headers) { key in
                    NamedKeyRow(key: key, kind: String(localized: "Header"))
                }
            } header: {
                Text("Umgebung")
            } footer: {
                Text("Grantry zeigt nur die Namen, nie die Werte.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var configurationSection: some View {
        Section("Konfiguration") {
            ConfigFileSection(path: entry.configPath, pathText: detail.configPathText)
            LabeledContent("Geltungsbereich") { Text(verbatim: detail.scopeText) }
        }
    }

    @ViewBuilder
    private var starterSection: some View {
        Section("Rechte des Starters") {
            switch detail.starter.kind {
            case .app:
                Text("\(entry.toolName) startet diesen Server und vererbt seine Berechtigungen:")
                starterGrants
            case .terminal:
                Text("\(entry.toolName) startet in der Terminal-App – der Server erbt deren Berechtigungen:")
                starterGrants
            case .unknown:
                InfoLabel(text: String(localized: "Für dieses Tool ist nicht bekannt, welche App die Server startet."))
            }
        }
    }

    @ViewBuilder
    private var starterGrants: some View {
        if detail.starter.grants.isEmpty {
            InfoLabel(text: String(localized: "Keine erteilten Berechtigungen bekannt."))
        } else {
            ForEach(detail.starter.grants) { grant in
                Button { window.show(grant) } label: {
                    LabeledContent {
                        Text(verbatim: grant.authValue.displayName.capitalizedFirst)
                            .foregroundStyle(grant.authValue.tone.color)
                    } label: {
                        Text(verbatim: "\(grant.client.displayName) · \(grant.serviceName)")
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("In „Berechtigungen“ zeigen")
                .accessibilityHint(Text("Zeigt die Berechtigung im Bereich „Berechtigungen“."))
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

    func perform(with actions: ActionRunner, context: ActionContext) async {
        switch self {
        case .setEnabled(let entry, let enabled, _): await actions.setServerEnabled(entry, enabled, context: context)
        case .remove(let entry, _): await actions.removeServer(entry, context: context)
        }
    }
}

/// Name einer Umgebungsvariable bzw. eines Headers; geheimnisartige mit Schlüsselsymbol und Erklärung – nie der Wert.
private struct NamedKeyRow: View {
    let key: NamedKey
    let kind: String

    var body: some View {
        if key.isSecret {
            row
                .help(Text(Self.secretHelp))
                .accessibilityHint(Text(Self.secretHelp))
        } else {
            row
        }
    }

    private var row: some View {
        LabeledContent {
            Text(verbatim: kind).foregroundStyle(.secondary)
        } label: {
            Label {
                Text(verbatim: key.name).font(.body.monospaced()).textSelection(.enabled)
            } icon: {
                if key.isSecret {
                    Image(systemName: "key.fill").foregroundStyle(PresentationTone.warning.color)
                } else {
                    Image(systemName: "character.cursor.ibeam").foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private static let secretHelp: LocalizedStringKey =
        "Wert steht im Klartext in der Konfigurationsdatei – Grantry zeigt ihn nicht an."
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
