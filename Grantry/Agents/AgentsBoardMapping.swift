import Foundation
import GrantryCharts
import ManagerKit

// Zuordnung der Agenten (ManagerKit) zu den Inhalten der Tafel (GrantryCharts, LB-2.4, #541; Entwurf LB-2.1, #538): eine
// Stelle für Zustandszeile, Listenzeilen und die Details von MCP-Server und automatischer Freigabe.

enum AgentsBoardMapping {
    /// Kennungen der Gruppen im Detail, an denen die Ansicht Knöpfe bzw. Sprungzeilen anhängt.
    enum GroupID {
        static let configuration = "configuration"
        static let starter = "starter"
    }

    // MARK: - Zustandszeile

    /// Zustandszeile (Spec §11.2 a) über alle Server und Freigaben, unabhängig von Suche und Filter; dritter Chip: deaktivierte
    /// Server.
    static func head(_ presentation: PresentationSnapshot?, scannedAt: Date?) -> InventoryHead {
        guard let presentation else {
            return InventoryVerdict.notScanned.head(facts: String(localized: "kein Scan seit dem Start"))
        }
        let groups = presentation.agents.groups
        let servers = groups.flatMap(\.servers)
        let approvals = groups.reduce(0) { $0 + $1.approvals.count }
        let disabled = servers.count { $0.isEnabled == false }
        let coverage = presentation.coverage[.agents]
        let verdict = InventoryVerdict(
            entryBadges: groups.flatMap(\.recordIDs).map { presentation.badges.badges(for: $0) }, subject: .entries,
            extra: disabled > 0 ? SystemVerdict.Item(text: String(localized: "\(disabled) deaktiviert"), tone: .neutral)
                : nil,
            missingSources: coverage.map { $0.isComplete ? 0 : max($0.gaps.count, 1) } ?? 0
        )
        var facts = [String(localized: "\(servers.count) Server"), String(localized: "\(approvals) Freigaben"),
                     String(localized: "\(groups.count) Werkzeuge")].joined(separator: " · ")
        if let scannedAt {
            facts += " · " + String(localized: "Scan \(scannedAt.formatted(date: .omitted, time: .shortened))")
        }
        return verdict.head(facts: facts)
    }

    // MARK: - Liste

    /// Je Werkzeug eine Gruppe, darin erst die Freigaben, dann die Server, die zu Suche und Filter passen.
    static func sections(_ sections: [AgentListSection],
                         presentation: PresentationSnapshot) -> [InstrumentListSection<String>] {
        sections.map { section in
            let items = section.approvals.map { approvalItem($0, presentation: presentation) }
                + section.servers.map { serverItem($0, presentation: presentation) }
            return InstrumentListSection(id: section.id, title: section.title, finding: items.contains { $0.content.finding },
                                         items: items)
        }
    }

    static func serverItem(_ server: MCPServerEntry, presentation: PresentationSnapshot) -> InstrumentListItem<String> {
        // Host bei entfernten Servern (sonst die URL), gekürzter Befehl bei lokalen; Projekt bzw. „verwaltet“ davor.
        let summary = server.transport.remoteHost ?? server.summary
        return InstrumentListItem(id: server.id, content: InstrumentRowContent(
            symbol: server.symbol, title: server.name, detail: withScope(summary, server.scope),
            badges: presentation.badges.badges(for: server.id).map(\.instrumentBadge),
            status: server.isEnabled == true ? nil : server.enabledText.map { StatusItem($0, tone: .neutral) },
            finding: presentation.highestSeverity(for: server.id) != nil
        ))
    }

    static func approvalItem(_ approval: AgentAutoApproval,
                             presentation: PresentationSnapshot) -> InstrumentListItem<String> {
        InstrumentListItem(id: approval.id, content: InstrumentRowContent(
            symbol: AgentAutoApproval.symbol, title: approval.message,
            detail: withScope(approval.settingText, approval.scope),
            badges: presentation.badges.badges(for: approval.id).map(\.instrumentBadge),
            finding: presentation.highestSeverity(for: approval.id) != nil
        ))
    }

    private static func withScope(_ text: String, _ scope: AgentScope) -> String {
        scope.scopeLabel.map { "\($0) · \(text)" } ?? text
    }

    // MARK: - Detail

    /// MCP-Server: Kopf mit Badges und Zustand, Hinweise, Start, Umgebung (nur Namen), Konfiguration, Rechte des Starters.
    static func serverDetail(_ detail: MCPServerDetail, badges: [RecordBadge]) -> RecordDetailContent {
        let entry = detail.entry
        var items = badges.map(\.statusItem)
        if let enabledText = detail.enabledText {
            items.append(StatusItem(enabledText, tone: entry.isEnabled == true ? .positive : .neutral))
        }
        var groups: [DetailGroupContent] = []
        if !detail.findings.isEmpty {
            groups.append(DetailGroupContent(id: "notes", title: String(localized: "Hinweise"),
                                             count: detail.findings.count, notes: findingNotes(detail.findings)))
        }
        groups.append(startGroup(detail))
        let keys = detail.environment.map { ($0, String(localized: "Umgebungsvariable")) }
            + detail.headers.map { ($0, String(localized: "Header")) }
        if !keys.isEmpty {
            groups.append(DetailGroupContent(
                id: "environment", title: String(localized: "Umgebung"), count: keys.count,
                facts: keys.map { key, kind in
                    key.isSecret ? DetailFactContent(key.name, value: String(localized: "Wert im Klartext in der Datei"),
                                                     tone: .finding)
                        : DetailFactContent(key.name, value: kind)
                },
                notes: [DetailNoteContent(String(localized: "Grantry zeigt nur die Namen, nie die Werte."), kind: .info)]
            ))
        }
        groups.append(configurationGroup(pathText: detail.configPathText, scopeText: detail.scopeText))
        groups.append(DetailGroupContent(id: GroupID.starter, title: String(localized: "Rechte des Starters"),
                                         notes: starterNotes(detail)))
        return RecordDetailContent(symbol: entry.symbol, title: entry.name, subtitle: entry.locationDescription,
                                   items: items, finding: !detail.findings.isEmpty, groups: groups)
    }

    /// Automatische Freigabe: Hinweise direkt unter dem Kopf, Einstellung mit Erklärung, Konfiguration.
    static func approvalDetail(_ approval: AgentAutoApproval, findings: [RiskFinding],
                               badges: [RecordBadge]) -> RecordDetailContent {
        RecordDetailContent(
            symbol: AgentAutoApproval.symbol, title: String(localized: "Automatische Freigabe"),
            subtitle: approval.toolName, items: badges.map(\.statusItem), finding: !findings.isEmpty,
            notes: findingNotes(findings),
            groups: [
                DetailGroupContent(id: "setting", title: String(localized: "Einstellung"),
                                   facts: [DetailFactContent(String(localized: "Einstellung"), value: approval.settingText,
                                                             isCode: true)],
                                   notes: [DetailNoteContent(approval.message, kind: .info)]),
                configurationGroup(pathText: PathDisplay.abbreviatingHome(approval.configPath),
                                   scopeText: AgentPresenter.scopeText(approval.scope)),
            ]
        )
    }

    private static func startGroup(_ detail: MCPServerDetail) -> DetailGroupContent {
        let entry = detail.entry
        var facts = [DetailFactContent(String(localized: "Art"), value: detail.kindText)]
        if let commandLine = detail.commandLine {
            facts.append(DetailFactContent(String(localized: "Befehl"), value: commandLine, isCode: true))
        }
        if let url = detail.url {
            facts.append(DetailFactContent(String(localized: "Ziel-URL"), value: url, isCode: true))
        }
        facts.append(DetailFactContent(String(localized: "Paketquelle"), value: detail.packageText,
                                       tone: entry.packageSource.isUnpinned ? .finding : nil))
        if case .localProgram = entry.packageSource {
            let signing = entry.programSigning ?? .unknown
            facts.append(DetailFactContent(String(localized: "Signatur"), value: signing.fullText,
                                           tone: signing.tone.statusTone))
        }
        return DetailGroupContent(id: "start", title: String(localized: "Start"), facts: facts,
                                  notes: detail.commandNote.map { [DetailNoteContent($0, kind: .info)] } ?? [])
    }

    private static func configurationGroup(pathText: String, scopeText: String) -> DetailGroupContent {
        DetailGroupContent(id: GroupID.configuration, title: String(localized: "Konfiguration"), facts: [
            DetailFactContent(String(localized: "Datei"), value: pathText, isCode: true),
            DetailFactContent(String(localized: "Geltungsbereich"), value: scopeText),
        ])
    }

    /// Wer den Server startet und ob seine Berechtigungen bekannt sind; die Berechtigungen selbst hängt die Ansicht als
    /// Sprungzeilen an.
    private static func starterNotes(_ detail: MCPServerDetail) -> [DetailNoteContent] {
        let toolName = detail.entry.toolName
        let intro: String
        switch detail.starter.kind {
        case .app:
            intro = String(localized: "\(toolName) startet diesen Server und vererbt seine Berechtigungen:")
        case .terminal:
            intro = String(localized: "\(toolName) startet in der Terminal-App – der Server erbt deren Berechtigungen:")
        case .unknown:
            return [DetailNoteContent(String(localized: "Für dieses Tool ist nicht bekannt, welche App die Server startet."),
                                      kind: .info)]
        }
        var notes = [DetailNoteContent(intro, kind: .info)]
        if detail.starter.grants.isEmpty {
            notes.append(DetailNoteContent(String(localized: "Keine erteilten Berechtigungen bekannt."), kind: .info))
        }
        return notes
    }

    /// Prüfhinweise wie in Autostart (`RecordBadge.noteKind`): hoher Schweregrad als Fehler, sonst auffällig.
    private static func findingNotes(_ findings: [RiskFinding]) -> [DetailNoteContent] {
        findings.map { DetailNoteContent($0.message, kind: RecordBadge.review($0.severity).noteKind) }
    }

    /// Berechtigung des Starters als Sprungzeile: Dienst, App, Zustand.
    static func starterGrant(_ grant: PermissionGrant) -> InstrumentRowContent {
        InstrumentRowContent(symbol: "hand.raised", title: grant.serviceName, detail: grant.client.displayName,
                             status: StatusItem(grant.authValue.displayName, tone: grant.authValue.tone.statusTone))
    }
}

/// Abschnitt der Liste: ein Tool mit den Servern und Freigaben, die zu Suche und Filter passen.
struct AgentListSection: Identifiable {
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

extension MCPServerEntry {
    /// Weltkugel für entfernte, Terminal für lokale Server.
    var symbol: String {
        if case .remote = transport { "globe" } else { "terminal" }
    }
}

extension AgentAutoApproval {
    static let symbol = "exclamationmark.shield"

    /// „permissions.defaultMode = bypassPermissions“.
    var settingText: String { "\(setting) = \(value)" }
}

private extension AgentScope {
    /// Geltungsbereich für die Suche: Kurzbezeichnung („Projekt web“, „verwaltet“) und Projektordner.
    var searchTexts: [String] {
        var texts = scopeLabel.map { [$0] } ?? []
        if case .project(let path) = self { texts.append(path) }
        return texts
    }
}
