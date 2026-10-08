import ManagerKit
import SwiftUI

/// Eine automatische Freigabe im Detail (Spec Agenten §7): Tool, Einstellung mit Wert, Erklärung, Hinweise,
/// Konfigurationsdatei und Geltungsbereich. Ohne Bearbeiten/Entfernen (Stufe 2).
struct AgentApprovalDetailView: View {
    let approval: AgentAutoApproval
    let findings: [RiskFinding]
    let badges: [RecordBadge]

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.shield")
                        .font(.system(size: 32))
                        .foregroundStyle(PresentationTone.warning.color)
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Automatische Freigabe")
                            .font(.title2.weight(.semibold))
                        Text(verbatim: approval.toolName)
                            .foregroundStyle(.secondary)
                        RecordBadgesRow(badges: badges)
                    }
                }
            }
            if !findings.isEmpty {
                Section("Hinweise") { RecordHints(findings: findings) }
            }
            Section("Einstellung") {
                LabeledContent("Einstellung") {
                    Text(verbatim: approval.settingText)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                Text(verbatim: approval.message)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Konfiguration") {
                ConfigFileSection(path: approval.configPath,
                                  pathText: PathDisplay.abbreviatingHome(approval.configPath))
                LabeledContent("Geltungsbereich") { Text(verbatim: AgentPresenter.scopeText(approval.scope)) }
            }
        }
        .formStyle(.grouped)
    }
}

#if DEBUG
#Preview("Freigabe") {
    AgentApprovalDetailView(approval: AgentPreviewData.approval, findings: [AgentPreviewData.approvalFinding],
                            badges: [.review(.medium)])
        .frame(width: 520, height: 520)
}
#endif
