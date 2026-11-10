import GrantryCharts
import ManagerKit
import SwiftUI

// Vorschau von `NetworkServicesBoard` mit Detail; eigene Datei, damit die Tafel ohne `NetworkListenerDetailView`
// (und damit ohne `MainWindowModel`) gehostet werden kann (Snapshot-Tests, TM-11.7).
#if DEBUG
private struct NetworkServicesBoardPreview: View {
    @State private var filter = NetworkListenerFilter()
    @State private var query = ""
    @State private var selection: NetworkListener.ID?
    let firewallHint: NetworkFirewallHint?

    var body: some View {
        let presentation = NetworkServicesPresentation(listeners: NetworkServicesPreviewData.listeners,
                                                       severity: NetworkServicesPreviewData.severity(for:),
                                                       query: query, filter: filter)
        let verdict = presentation.verdict(firewallHint: firewallHint)
        let row = presentation.rows.first { $0.id == selection } ?? presentation.rows.first
        VStack(spacing: 0) {
            StatusLine(verdict: verdict.title, finding: verdict.hasFinding, items: verdict.statusItems,
                       facts: verdict.facts)
                .padding([.horizontal, .top], 14)
            NetworkServicesBoard(
                presentation: presentation, firewallHint: firewallHint,
                badges: { $0.severity.map { [.review($0)] } ?? [] }, filter: $filter, query: $query,
                selection: $selection, showSecurity: {}
            ) {
                if let row {
                    NetworkListenerDetailView(
                        row: row, badges: row.severity.map { [.review($0)] } ?? [], findings: [], launchedBy: nil,
                        termination: nil,
                        activity: .preview(frame: NetworkActivityPreviewData.frame, status: .running,
                                           hostNames: NetworkActivityPreviewData.hostNames)
                    )
                } else {
                    NetworkListenerNoSelection()
                }
            } contextMenu: { _ in
                EmptyView()
            }
        }
        .frame(width: 1240, height: 820)
        .instrumentBackground()
    }
}

#Preview("Dienste hell") {
    NetworkServicesBoardPreview(firewallHint: .firewallOff(exposedCount: 3)).preferredColorScheme(.light)
}

#Preview("Dienste dunkel") {
    NetworkServicesBoardPreview(firewallHint: .firewallOff(exposedCount: 3)).preferredColorScheme(.dark)
}
#endif
