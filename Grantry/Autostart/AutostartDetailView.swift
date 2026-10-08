import ManagerKit
import SwiftUI

/// Ein Autostart-Eintrag im Detail: Zustand, Besitzer-App, Programm samt Signatur, ausgeführter Befehl (maskiert,
/// kopierbar), Plist, Session-Typen, Prüfhinweise
/// und die Aktionen „Deaktivieren“/„Aktivieren“ und „Entfernen…“; schreibgeschützte Einträge nennen den Grund,
/// BTM-Einträge verweisen auf die Anmeldeobjekte in den Systemeinstellungen.
struct AutostartDetailView: View {
    let item: AutostartItem
    let presentation: PresentationSnapshot
    let actions: ActionRunner
    @Environment(\.openURL) private var openURL
    @State private var pendingAction: AutostartAction?

    private static let policy = ActionPolicy()

    var body: some View {
        Form {
            header
            actionSection
            detailsSection
            findingsSection
        }
        .formStyle(.grouped)
        .actionConfirmation(for: $pendingAction, confirmation: \.confirmation) { action in
            Task { await action.perform(with: actions, context: .autostart) }
        }
    }

    private var header: some View {
        Section {
            HStack(spacing: 12) {
                AutostartItemIcon(item: item, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: item.label)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    Text(verbatim: "\(item.kind.displayName) · \(item.domain.displayName)")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        AutostartStatusRow(statuses: item.statusBadges)
                        RecordBadgesRow(badges: presentation.badges.badges(for: item.id))
                    }
                }
            }
        }
    }

    // MARK: - Aktionen

    private var actionSection: some View {
        Section("Aktionen") {
            HStack(spacing: 8) {
                switch Self.policy.availability(for: item) {
                case .available:
                    Button(item.isEnabled ? "Deaktivieren" : "Aktivieren") {
                        pendingAction = .setEnabled(item, !item.isEnabled)
                    }
                    .disabled(!actions.canStart)
                    Button("Entfernen …", role: .destructive) { pendingAction = .remove(item) }
                        .disabled(!actions.canStart)
                case .readOnly(let reason):
                    HintLabel(text: reason.description, systemImage: "lock", color: .secondary)
                    if let url = reason.settingsURL {
                        Spacer(minLength: 8)
                        Button("In Anmeldeobjekten öffnen") { openURL(url) }
                    }
                }
                if actions.runningRecordID == item.id {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Aktion läuft")
                }
            }
        }
    }

    // MARK: - Details

    private var detailsSection: some View {
        Section("Details") {
            if let note = item.verificationNote(now: .now) {
                HintLabel(text: note, systemImage: PresentationTone.warning.systemImage, color: PresentationTone.warning.color)
            }
            if let owner = item.owner {
                LabeledContent("Besitzer-App") {
                    HStack(spacing: 6) {
                        AppIconView(app: owner, size: 16)
                        Text(verbatim: owner.bundleID.map { "\(owner.displayName) (\($0))" } ?? owner.displayName)
                            .textSelection(.enabled)
                    }
                }
            }
            LabeledContent("Programm") {
                PathText(path: item.program ?? String(localized: "Unbekannt"))
            }
            if let commandLine = item.displayedCommandLine {
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 4) {
                        CodeText(text: commandLine)
                        CopyCommandButton(command: commandLine)
                            .controlSize(.small)
                    }
                } label: {
                    Text("Befehl")
                    if let note = item.commandNote {
                        Text(verbatim: note)
                    }
                }
            }
            if item.program != nil, item.programPresence != .present {
                LabeledContent("Programm auf dem Mac") {
                    Text(verbatim: item.programPresence.displayName)
                }
            }
            if let signing = item.programSigning {
                LabeledContent("Signatur des Programms") {
                    SigningLabel(signing: signing)
                }
            }
            if let plistPath = item.plistPath {
                LabeledContent("Plist") {
                    PathText(path: plistPath)
                }
            }
            let sharing = presentation.autostartItems(sharingServiceWith: item).compactMap(\.plistPath)
            if !sharing.isEmpty {
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(sharing, id: \.self) { PathText(path: $0) }
                    }
                } label: {
                    Text("Gleiches Label auch in")
                    Text("launchd führt je Label nur einen Dienst; Aktivieren/Deaktivieren ist dann gesperrt.")
                }
            }
            if let sessionTypes = item.sessionTypes, !sessionTypes.isEmpty {
                LabeledContent("Session-Typen") {
                    Text(verbatim: sessionTypes.joined(separator: ", "))
                }
            }
        }
    }

    @ViewBuilder
    private var findingsSection: some View {
        let hints = RecordHints(presentation: presentation, recordID: item.id)
        if !hints.isEmpty {
            Section("Hinweise") { hints }
        }
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

    func perform(with actions: ActionRunner, context: ActionContext) async {
        switch self {
        case .setEnabled(let item, let enabled): await actions.setEnabled(item, enabled, context: context)
        case .remove(let item): await actions.remove(item, context: context)
        }
    }
}
