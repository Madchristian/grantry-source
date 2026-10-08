import ManagerKit
import SwiftUI

/// Ein MCP-Server in der Liste: Name und Geltungsbereich, darunter Befehl (lokal) bzw. Host (entfernt), dazu Badges und
/// der Zustand, wenn der Server nicht läuft (`MCPServerEntry.enabledText`).
struct MCPServerRowView: View {
    let server: MCPServerEntry
    let badges: [RecordBadge]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: server.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let scopeLabel = server.scope.scopeLabel {
                    Text(verbatim: scopeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Label {
                Text(verbatim: subtitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: isRemote ? "globe" : "terminal")
                    .accessibilityLabel(isRemote ? Text("entfernt") : Text("lokal"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !badges.isEmpty || stateText != nil {
                HStack(spacing: 4) {
                    RecordBadgesRow(badges: badges)
                    if let stateText {
                        BadgeCapsule(title: stateText, color: .secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// Neutrales Kennzeichen, wenn der Server nicht läuft bzw. nicht freigegeben ist („deaktiviert“, „abgelehnt“,
    /// „Freigabe ausstehend“); `nil` für aktive Server.
    private var stateText: String? {
        server.isEnabled == true ? nil : server.enabledText
    }

    private var isRemote: Bool {
        if case .remote = server.transport { true } else { false }
    }

    /// Host bei entfernten Servern (sonst die URL), gekürzter Befehl bei lokalen.
    private var subtitle: String {
        server.transport.remoteHost ?? server.summary
    }
}

#if DEBUG
#Preview("Server und Freigabe") {
    List {
        Section {
            AgentApprovalRowView(approval: AgentPreviewData.approval, badges: [.review(.medium)])
            MCPServerRowView(server: AgentPreviewData.localServer, badges: [.new, .review(.high)])
            MCPServerRowView(server: AgentPreviewData.remoteServer, badges: [.review(.medium)])
        } header: {
            Text(verbatim: "Claude Code · 2 Server · 1 Freigabe")
        }
    }
    .frame(width: 320, height: 260)
}
#endif
