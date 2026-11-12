import SwiftUI
@testable import GrantryCharts

/// Bereich Agenten (LB-2.4, #541) mit festen Beispieldaten wie im abgenommenen Entwurf LB-2.1 (#538): erfundene Werkzeuge,
/// Server und Pfade, keine Benutzernamen oder Hostnamen.
@MainActor
extension SnapshotGallery {
    enum AgentsScene: String, CaseIterable, Sendable {
        case server = "server-gewaehlt"
        case approval = "freigabe-gewaehlt"
        case nothingSelected = "nichts-gewaehlt"
        case notScanned = "kein-scan"
        case incomplete = "unvollstaendig"
    }

    static let agentsSize = CGSize(width: 1180, height: 760)

    static func agents(_ scene: AgentsScene) -> some View {
        AgentsSample(scene: scene)
    }

    static let agentsHead = InventoryHead(
        verdict: "3 Einträge auffällig", finding: true,
        items: [StatusItem("1 kritisch", tone: .critical), StatusItem("2 prüfen", tone: .finding),
                StatusItem("1 neu seit 7 Tagen", tone: .neutral)],
        facts: "5 Server · 1 Freigabe · 2 Werkzeuge · Scan 14:32"
    )

    static let reviewHigh = InstrumentBadge("prüfen", tone: .critical, spoken: "prüfen, hoher Schweregrad")

    static let agentSections = [
        InstrumentListSection(id: "code", title: "Code-Assistent · 3 Server · 1 Freigabe", finding: true, items: [
            InstrumentListItem(id: "approval", content: InstrumentRowContent(
                symbol: "exclamationmark.shield", title: "Befehle ohne Rückfrage ausführen",
                detail: "autoApprove = true", badges: [review], finding: true)),
            InstrumentListItem(id: "files", content: InstrumentRowContent(
                symbol: "terminal", title: "dateien", detail: "npx -y @example/server-files ~",
                badges: [reviewHigh, new], finding: true)),
            InstrumentListItem(id: "tickets", content: InstrumentRowContent(
                symbol: "globe", title: "tickets", detail: "mcp.example.com", badges: [review], finding: true)),
            InstrumentListItem(id: "search", content: InstrumentRowContent(
                symbol: "terminal", title: "suche", detail: "/usr/local/bin/example-search",
                status: StatusItem("deaktiviert", tone: .neutral))),
        ]),
        InstrumentListSection(id: "editor", title: "Editor-Agent · 2 Server", items: [
            InstrumentListItem(id: "docs", content: InstrumentRowContent(
                symbol: "terminal", title: "doku", detail: "uvx example-docs==1.4.2")),
            InstrumentListItem(id: "browser", content: InstrumentRowContent(
                symbol: "terminal", title: "browser", detail: "npx @example/browser@2.1.0")),
        ]),
    ]

    /// Lokaler Server mit kritischem Befund wie im Entwurf.
    static let fileServerDetail = RecordDetailContent(
        symbol: "terminal", title: "dateien", subtitle: "Code-Assistent · Benutzer",
        items: [StatusItem("prüfen", tone: .critical), StatusItem("aktiviert", tone: .positive)], finding: true,
        groups: [
            DetailGroupContent(id: "notes", title: "Hinweise", count: 2, notes: [
                DetailNoteContent("Darf den ganzen Benutzerordner lesen und schreiben.", kind: .critical),
                DetailNoteContent("Lädt das Paket bei jedem Start ohne feste Version nach.", kind: .finding),
            ]),
            DetailGroupContent(id: "start", title: "Start", facts: [
                DetailFactContent("Art", value: "lokal"),
                DetailFactContent("Befehl", value: "npx -y @example/server-files ~", isCode: true),
                DetailFactContent("Paketquelle", value: "npm-Paket @example/server-files – ohne festgelegte Version",
                                  tone: .finding),
            ]),
            DetailGroupContent(id: "environment", title: "Umgebung", count: 1, facts: [
                DetailFactContent("EXAMPLE_TOKEN", value: "Wert im Klartext in der Datei", tone: .finding),
            ], notes: [DetailNoteContent("Grantry zeigt nur die Namen, nie die Werte.", kind: .info)]),
            DetailGroupContent(id: "configuration", title: "Konfiguration", facts: [
                DetailFactContent("Datei", value: "~/.example-assistant/config.json", isCode: true),
                DetailFactContent("Geltungsbereich", value: "global (Benutzer)"),
            ]),
            DetailGroupContent(id: "starter", title: "Rechte des Starters", notes: [
                DetailNoteContent("Code-Assistent startet in der Terminal-App – der Server erbt deren Berechtigungen:",
                                  kind: .info),
            ]),
        ]
    )

    /// Automatische Freigabe: Hinweis direkt unter dem Kopf, ohne Gruppe.
    static let approvalDetail = RecordDetailContent(
        symbol: "exclamationmark.shield", title: "Automatische Freigabe", subtitle: "Code-Assistent",
        items: [StatusItem("prüfen", tone: .finding)], finding: true,
        notes: [DetailNoteContent("Der Assistent führt Befehle aus, ohne vorher zu fragen.", kind: .finding)],
        groups: [
            DetailGroupContent(id: "setting", title: "Einstellung", facts: [
                DetailFactContent("Einstellung", value: "autoApprove = true", isCode: true),
            ]),
            DetailGroupContent(id: "configuration", title: "Konfiguration", facts: [
                DetailFactContent("Datei", value: "~/.example-assistant/settings.json", isCode: true),
                DetailFactContent("Geltungsbereich", value: "global (Benutzer)"),
            ]),
        ]
    )
}

private struct AgentsSample: View {
    let scene: SnapshotGallery.AgentsScene

    var body: some View {
        switch scene {
        case .server:
            board(selection: "files") {
                RecordDetailPanel(content: SnapshotGallery.fileServerDetail) {
                    InstrumentRowIcon(symbol: "terminal", size: InstrumentSize.shield)
                } actions: {
                    EmptyView()
                } accessory: { group in
                    if group.id == "starter" {
                        JumpRow(InstrumentRowContent(symbol: "internaldrive", title: "Festplattenvollzugriff",
                                                     detail: "Terminal", status: SnapshotGallery.allowed),
                                destination: "Berechtigungen") {}
                    }
                }
            }
        case .approval:
            board(selection: "approval") { RecordDetailPanel(content: SnapshotGallery.approvalDetail) }
        case .nothingSelected:
            board(selection: nil) { nothingSelected }
        case .notScanned:
            InventoryBoard(head: InventoryHead(verdict: "Noch nicht geprüft", finding: false, items: [],
                                               facts: "kein Scan seit dem Start")) {
                ProgressSpur(title: "Abdeckung unbekannt", detail: "noch nichts gelesen", fraction: 0, tone: .neutral)
            } list: {
                InstrumentEmptyState(symbol: "clock", title: "Noch kein Scan",
                                     message: "Der erste Scan liest die Konfigurationen der Agenten-Werkzeuge ein.")
                    .instrumentPanel()
            } detail: {
                nothingSelected
            }
        case .incomplete:
            InventoryBoard(head: InventoryHead(verdict: "Nicht vollständig geprüft", finding: true,
                                               items: [StatusItem("1 Quelle fehlt", tone: .finding)],
                                               facts: "2 Server · 0 Freigaben · 1 Werkzeug · Scan 14:32")) {
                ProgressSpur(title: "Abdeckung unvollständig", detail: "1 Konfigurationsdatei ließ sich nicht lesen",
                             fraction: 1.0 / 2, tone: .finding)
            } list: {
                InstrumentList("Server und Freigaben", count: "2", sections: [SnapshotGallery.agentSections[1]],
                               selection: .constant(nil))
            } detail: {
                nothingSelected
            }
        }
    }

    private var nothingSelected: some View {
        InstrumentEmptyState(symbol: "hand.raised", title: "Nichts gewählt",
                             message: "Wähle links einen MCP-Server oder eine Freigabe, um Details zu sehen.")
            .instrumentPanel()
    }

    private func board(selection: String?, @ViewBuilder detail: () -> some View) -> some View {
        InventoryBoard(head: SnapshotGallery.agentsHead) {
            ProgressSpur(title: "Abdeckung vollständig", detail: "alle Quellen gelesen · 14:32", fraction: 1,
                         tone: .positive)
        } list: {
            InstrumentList("Server und Freigaben", count: "6", sections: SnapshotGallery.agentSections,
                           selection: .constant(selection))
        } detail: {
            detail()
        }
    }
}
