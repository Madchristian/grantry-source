import GrantryCharts
import ManagerKit
import SwiftUI

/// Eine automatische Freigabe im Detail (Spec Agenten §7; LB-2.4, #541): Tool, Hinweise direkt unter dem Kopf, Einstellung
/// mit Wert und Erklärung, Konfigurationsdatei mit „Im Finder zeigen“ und „Öffnen“ und Geltungsbereich. Ohne
/// Bearbeiten/Entfernen (Stufe 2).
struct AgentApprovalDetailView: View {
    let approval: AgentAutoApproval
    let findings: [RiskFinding]
    let badges: [RecordBadge]

    var body: some View {
        RecordDetailPanel(content: AgentsBoardMapping.approvalDetail(approval, findings: findings, badges: badges)) {
            InstrumentRowIcon(symbol: AgentAutoApproval.symbol, size: InstrumentSize.shield)
        } actions: {
            EmptyView()
        } accessory: { group in
            if group.id == AgentsBoardMapping.GroupID.configuration { ConfigFileControls(path: approval.configPath) }
        }
    }
}

#if DEBUG
#Preview("Freigabe") {
    AgentApprovalDetailView(approval: AgentPreviewData.approval, findings: [AgentPreviewData.approvalFinding],
                            badges: [.review(.medium)])
        .frame(width: 520, height: 520)
}
#endif
