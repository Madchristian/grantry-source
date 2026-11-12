import GrantryCharts
import ManagerKit
import SwiftUI

/// Agenten im Lagebild (Spec Agenten §7, #129; LB-2.4, #541, Entwurf LB-2.1): Zustandszeile mit Urteil, Scan-Abdeckung der
/// Agenten-Quelle (#142), links MCP-Server und automatische Freigaben je Tool als Auswahlliste, rechts das Detail; Suche
/// und Befund-Filter in der Symbolleiste. Liest nur aus `AppModel.presentation`; Aktionen laufen über `AppModel.actions`,
/// ihr Ergebnis steht über dem Detail. Zeichnet nur bei Scan, Suche, Filter, Auswahl und Aktion.
struct AgentsView: View {
    let appModel: AppModel
    @Environment(MainWindowModel.self) private var window
    @State private var selection: String?

    var body: some View {
        let presentation = appModel.presentation
        InventoryBoard(head: AgentsBoardMapping.head(presentation, scannedAt: appModel.monitoring.snapshot?.takenAt)) {
            VStack(alignment: .leading, spacing: 0) {
                if let coverage { AreaCoverageBar(coverage: coverage) }
                FlaggedNoticeBar(breakdown: presentation?.metrics.flagged, area: .agents,
                                 filter: window.filter(for: .agents).findings)
            }
        } list: {
            list(presentation)
        } detail: {
            ActionResultContainer(actions: appModel.actions, context: .agents) {
                detail(presentation)
            }
        }
        .inventorySearch(for: .agents, prompt: String(localized: "Agenten durchsuchen"))
        .toolbar {
            ToolbarItem { AgentFilterMenu(filter: filterBinding) }
        }
        // Verschwindet der ausgewählte Eintrag, gilt „keine Auswahl“ – auch, falls er später wiederkommt.
        .onChange(of: selectedItem == nil) { _, isGone in if isGone { selection = nil } }
        // Sprung von außen (Übersicht, Verlauf): Die Liste rollt die neue Auswahl selbst ins Bild.
        .onChange(of: window.focusedRecordID, initial: true) { _, recordID in
            if let recordID { selection = recordID }
        }
    }

    /// Filter des Bereichs; ausgewertet wird nur der Befund-Filter (setzt auch die Kachel „Auffällig“).
    private var filterBinding: Binding<ListFilter> {
        Binding(get: { window.filter(for: .agents) }, set: { window.filters[.agents] = $0 })
    }

    private var coverage: AreaCoverage? { appModel.presentation?.coverage[.agents] }

    // MARK: - Liste

    @ViewBuilder
    private func list(_ presentation: PresentationSnapshot?) -> some View {
        let findings = window.filter(for: .agents).findings
        let sections = AgentListSection.sections(
            presentation?.agents.groups ?? [], query: window.query(for: .agents),
            isIncluded: { findings.includes(presentation?.highestSeverity(for: $0)) }
        )
        if let presentation, !sections.isEmpty {
            let configPaths = Dictionary(
                sections.flatMap { $0.servers.map { ($0.id, $0.configPath) } + $0.approvals.map { ($0.id, $0.configPath) } },
                uniquingKeysWith: { first, _ in first }
            )
            let items = AgentsBoardMapping.sections(sections, presentation: presentation)
            InstrumentList(String(localized: "Server und Freigaben"), count: "\(items.reduce(0) { $0 + $1.items.count })",
                           sections: items, selection: $selection, contextMenu: { id in
                               if let path = configPaths[id] { ConfigFileButtons(path: path) }
                           })
        } else {
            InventoryEmptyState(
                section: .agents, coverage: coverage, hasSnapshot: presentation != nil,
                emptyTitle: "Keine Agenten-Konfigurationen gefunden", emptyDescription: Self.emptyDescription
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .instrumentPanel()
        }
    }

    private static let emptyDescription: LocalizedStringKey =
        "Grantry liest die Konfigurationen von \(AgentToolCatalog.standard.toolNamesText)."

    // MARK: - Detail

    /// Ausgewählter Eintrag – unabhängig von der Suche, solange er im aktuellen Snapshot existiert.
    private var selectedItem: AgentItem? {
        guard let selection, let presentation = appModel.presentation else { return nil }
        if let server = presentation.agentServer(id: selection) { return .server(server) }
        return presentation.agentApproval(id: selection).map(AgentItem.approval)
    }

    @ViewBuilder
    private func detail(_ presentation: PresentationSnapshot?) -> some View {
        if let presentation, let item = selectedItem {
            switch item {
            case .server(let server):
                MCPServerDetailView(detail: presentation.agentDetail(for: server),
                                    badges: presentation.badges.badges(for: server.id), actions: appModel.actions)
                    .id(server.id)
            case .approval(let approval):
                AgentApprovalDetailView(approval: approval, findings: presentation.findings(for: approval.id),
                                        badges: presentation.badges.badges(for: approval.id))
                    .id(approval.id)
            }
        } else {
            InstrumentEmptyState(
                symbol: "hand.raised", title: String(localized: "Nichts gewählt"),
                message: String(localized: "Wähle links einen MCP-Server oder eine Freigabe, um Details zu sehen.")
            )
            .instrumentPanel()
        }
    }
}

/// Ein Eintrag der Liste: MCP-Server oder automatische Freigabe.
private enum AgentItem {
    case server(MCPServerEntry)
    case approval(AgentAutoApproval)
}

/// Filtermenü des Bereichs: nur Befunde – Zustand und Bereich (Benutzer/System) gibt es hier nicht.
private struct AgentFilterMenu: View {
    @Binding var filter: ListFilter

    var body: some View {
        FilterMenu(isActive: filter.isActive, help: "Liste filtern", reset: { filter = ListFilter() }) {
            FindingFilterPicker(selection: $filter.findings)
        }
    }
}
