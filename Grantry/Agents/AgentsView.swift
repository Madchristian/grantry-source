import ManagerKit
import SwiftUI

/// Bereich „Agenten“ (Spec Agenten §7, #129): MCP-Server und automatische Freigaben je Tool links, Detail rechts; Suche
/// und Filter „Nur auffällige“ in der Symbolleiste, Scan-Abdeckung der Agenten-Quelle über der Liste (#142). Liest nur aus
/// `AppModel.presentation`; Aktionen laufen über `AppModel.actions`, ihr Ergebnis steht über dem Detail.
struct AgentsView: View {
    let appModel: AppModel
    @Environment(MainWindowModel.self) private var window
    @State private var selection: String?

    var body: some View {
        ListDetailSplit {
            VStack(spacing: 0) {
                SectionCoverageHeader(coverage: appModel.presentation?.coverage[.agents])
                list
            }
        } detail: {
            ActionResultContainer(actions: appModel.actions, context: .agents) {
                detail
            }
        }
        .inventorySearch(for: .agents, prompt: String(localized: "Agenten durchsuchen"))
        .toolbar {
            ToolbarItem { AgentFilterMenu(filter: filterBinding) }
        }
        // Verschwindet der ausgewählte Eintrag, gilt „keine Auswahl“ – auch, falls er später wiederkommt.
        .onChange(of: selectedItem == nil) { _, isGone in if isGone { selection = nil } }
    }

    /// Filter des Bereichs; ausgewertet wird nur „Nur auffällige“ (setzt auch die Kachel „Auffällig“).
    private var filterBinding: Binding<ListFilter> {
        Binding(get: { window.filter(for: .agents) }, set: { window.filters[.agents] = $0 })
    }

    // MARK: - Liste

    private var list: some View {
        let presentation = appModel.presentation
        let onlyFlagged = window.filter(for: .agents).onlyFlagged
        let sections = AgentListSection.sections(
            presentation?.agents.groups ?? [], query: window.query(for: .agents),
            isIncluded: { recordID in !onlyFlagged || presentation?.highestSeverity(for: recordID) != nil }
        )
        let badges = presentation?.badges
        return ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.approvals) { approval in
                            AgentApprovalRowView(approval: approval, badges: badges?.badges(for: approval.id) ?? [])
                                .id(approval.id)
                                .contextMenu { ConfigFileButtons(path: approval.configPath) }
                        }
                        ForEach(section.servers) { server in
                            MCPServerRowView(server: server, badges: badges?.badges(for: server.id) ?? [])
                                .id(server.id)
                                .contextMenu { ConfigFileButtons(path: server.configPath) }
                        }
                    } header: {
                        Text(verbatim: section.title)
                    }
                }
            }
            .onChange(of: window.focusedRecordID, initial: true) { _, recordID in
                guard let recordID else { return }
                selection = recordID
                proxy.scrollTo(recordID, anchor: .center)
            }
        }
        .overlay {
            if sections.isEmpty {
                InventoryEmptyState(
                    section: .agents, coverage: presentation?.coverage[.agents], hasSnapshot: presentation != nil,
                    emptyTitle: "Keine Agenten-Konfigurationen gefunden", emptyDescription: Self.emptyDescription
                )
            }
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
    private var detail: some View {
        if let presentation = appModel.presentation, let item = selectedItem {
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
            NoSelectionView(hint: "Wähle links einen MCP-Server oder eine Freigabe, um Details zu sehen.")
        }
    }
}

/// Ein Eintrag der Liste: MCP-Server oder automatische Freigabe.
private enum AgentItem {
    case server(MCPServerEntry)
    case approval(AgentAutoApproval)
}

/// Abschnitt der Liste: ein Tool mit den Servern und Freigaben, die zu Suche und Filter passen.
private struct AgentListSection: Identifiable {
    let id: String
    let name: String
    let servers: [MCPServerEntry]
    let approvals: [AgentAutoApproval]

    /// „Claude Code · 2 Server · 1 Freigabe“; Teile ohne Einträge entfallen.
    var title: String {
        [
            name,
            servers.isEmpty ? nil : String(localized: "\(servers.count) Server"),
            approvals.isEmpty ? nil : String(localized: "\(approvals.count) Freigaben"),
        ].compactMap(\.self).joined(separator: " · ")
    }

    /// Gruppen gefiltert nach `query` (Server nach Name, Befehl/URL, Tool und Geltungsbereich, Freigaben nach
    /// Einstellung, Wert, Erklärung, Tool und Geltungsbereich; ohne Beachtung von Groß-/Kleinschreibung) und
    /// `isIncluded` (Record-ID); Tools ohne Treffer entfallen.
    static func sections(
        _ groups: [AgentToolGroup], query: String, isIncluded: (String) -> Bool
    ) -> [AgentListSection] {
        let query = query.trimmingCharacters(in: .whitespaces)
        func matches(_ fields: [String]) -> Bool {
            query.isEmpty || fields.contains { $0.localizedStandardContains(query) }
        }
        return groups.compactMap { group in
            let section = AgentListSection(
                id: group.id, name: group.name,
                servers: group.servers.filter {
                    isIncluded($0.id) && matches([$0.name, $0.summary, $0.toolName] + $0.scope.searchTexts)
                },
                approvals: group.approvals.filter {
                    isIncluded($0.id)
                        && matches([$0.setting, $0.value, $0.message, $0.toolName] + $0.scope.searchTexts)
                }
            )
            return section.servers.isEmpty && section.approvals.isEmpty ? nil : section
        }
    }
}

/// Filtermenü des Bereichs: nur „Nur auffällige“ – Zustand und Bereich (Benutzer/System) gibt es hier nicht.
private struct AgentFilterMenu: View {
    @Binding var filter: ListFilter

    var body: some View {
        FilterMenu(isActive: filter.isActive, help: "Liste filtern", reset: { filter = ListFilter() }) {
            Toggle("Nur auffällige", isOn: $filter.onlyFlagged)
        }
    }
}

private extension AgentScope {
    /// Geltungsbereich für die Suche: Kurzbezeichnung („Projekt web“, „verwaltet“) und Projektordner.
    var searchTexts: [String] {
        var texts = scopeLabel.map { [$0] } ?? []
        if case .project(let path) = self { texts.append(path) }
        return texts
    }
}
