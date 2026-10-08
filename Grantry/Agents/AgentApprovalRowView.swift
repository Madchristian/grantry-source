import ManagerKit
import SwiftUI

/// Eine automatische Freigabe in der Liste: Erklärung und Einstellung mit Wert.
struct AgentApprovalRowView: View {
    let approval: AgentAutoApproval
    let badges: [RecordBadge]

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: approval.message)
                    .lineLimit(2)
                Text(verbatim: approval.settingText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !badges.isEmpty || approval.scope.scopeLabel != nil {
                    HStack(spacing: 4) {
                        RecordBadgesRow(badges: badges)
                        if let scopeLabel = approval.scope.scopeLabel {
                            Text(verbatim: scopeLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } icon: {
            Image(systemName: "exclamationmark.shield")
                .foregroundStyle(PresentationTone.warning.color)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

extension AgentAutoApproval {
    /// „permissions.defaultMode = bypassPermissions“.
    var settingText: String { "\(setting) = \(value)" }
}
