import GrantryCharts
import SwiftUI

/// Entwurf LB-2.1 (#538): Agenten im Lagebild – MCP-Server und automatische Freigaben je Werkzeug, gewählt mit Befund,
/// Aktion läuft, Fehler, nichts gewählt, Freigabe gewählt, Leerzustände. Werkzeuge und Server sind erfunden. Die Details
/// zeichnet seit LB-2.4 (#541) das zentrale `RecordDetailPanel`.
struct AgentsDraftBoard: View {
    var body: some View {
        AreaDraftPage(title: "Lagebild · Agenten",
                      subtitle: "Entwurf LB-2.1: Zustandszeile, Server und Freigaben je Werkzeug, Detail mit Start, "
                          + "Umgebung, Konfiguration und Rechten des Starters – feste Beispieldaten") {
            AreaDraftCaption(text: "1 · Server gewählt mit Befund")
            Self.primary
            AreaDraftCaption(text: "2 · Aktion läuft (links) und Fehler einer Aktion (rechts)")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                FileServerDetail(runningText: "Wird entfernt …")
                VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
                    InstrumentBanner("Server nicht entfernt", message: "Die Konfiguration hat sich seit dem Scan geändert. Es wurde nichts "
                                           + "geändert.", tone: .critical) { BannerDismissButton {} }
                    FileServerDetail()
                }
            }
            AreaDraftCaption(text: "3 · Nichts gewählt (links) und automatische Freigabe gewählt (rechts)")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                AreaDraftScreen(verdict: AgentSamples.verdict, coverage: .complete,
                            height: AreaDraftHeight.agentsState) {
                    InstrumentList("Server und Freigaben", count: "6", sections: AgentSamples.sections, selection: .constant(nil))
                } detail: {
                    InstrumentEmptyState(symbol: "hand.raised", title: "Nichts gewählt", message: "Wähle links einen Server oder eine Freigabe, um Details zu sehen.").instrumentPanel()
                }
                AreaDraftScreen(verdict: AgentSamples.verdict, coverage: .complete,
                            height: AreaDraftHeight.agentsState) {
                    InstrumentList("Server und Freigaben", count: "6", sections: AgentSamples.sections, selection: .constant("approval"))
                } detail: {
                    RecordDetailPanel(content: AgentSamples.approval)
                }
            }
            AreaDraftCaption(text: "4 · Noch kein Scan, Abdeckung unvollständig, keine Treffer")
            AreaDraftEmptyStates(
                area: "die Konfigurationen der Agenten-Werkzeuge", itemsTitle: "Server und Freigaben",
                partial: InventoryHead(verdict: "Ruhig", shield: .calm, items: [StatusItem("1 Datei nicht lesbar", tone: .finding)], facts: "2 Server"),
                partialCoverage: CoverageSample(title: "Abdeckung unvollständig",
                                               detail: "1 Konfigurationsdatei ließ sich nicht lesen",
                                               fraction: 1.0 / 2, tone: .finding, showsDetails: true),
                partialSections: [AgentSamples.sections[1]],
                noMatches: InventoryHead(verdict: "3 Einträge auffällig", shield: .finding, items: [], facts: "0 von 6 passen")
            )
        }
    }
}

extension AgentsDraftBoard {
    /// Hauptzustand des Bereichs, auch auf der Galerieseite „Alle Ansichten“ (LB-5.5, #556).
    @ViewBuilder static var primary: some View {
        AreaDraftScreen(verdict: AgentSamples.verdict, coverage: .complete,
                        height: AreaDraftHeight.agents) {
            InstrumentList("Server und Freigaben", count: "6", sections: AgentSamples.sections, selection: .constant("files"))
        } detail: {
            FileServerDetail()
        }
    }
}

// MARK: - Beispieldaten

private enum AgentSamples {
    static let verdict = InventoryHead(verdict: "3 Einträge auffällig", shield: .finding, items: [StatusItem("1 kritisch", tone: .critical), StatusItem("2 prüfen", tone: .finding),
                StatusItem("1 neu seit 7 Tagen", tone: .neutral)], facts: "5 Server · 1 Freigabe · 2 Werkzeuge · Scan 14:32")

    static let sections = [
        InstrumentListSection(id: "code", title: "Code-Assistent · 3 Server · 1 Freigabe", finding: true, items: [
            .sample("approval", "exclamationmark.shield", "Befehle ohne Rückfrage ausführen", "autoApprove = true",
                    badges: [SampleBadge.review], finding: true),
            .sample("files", "terminal", "dateien", "npx -y @example/server-files ~",
                    badges: [SampleBadge.reviewHigh, SampleBadge.new], finding: true),
            .sample("tickets", "globe", "tickets", "mcp.example.com", badges: [SampleBadge.review], finding: true),
            .sample("search", "terminal", "suche", "/usr/local/bin/example-search",
                    status: StatusItem("aus", tone: .neutral)),
        ]),
        InstrumentListSection(id: "editor", title: "Editor-Agent · 2 Server", items: [
            .sample("docs", "terminal", "doku", "uvx example-docs==1.4.2"),
            .sample("browser", "terminal", "browser", "npx @example/browser@2.1.0"),
        ]),
    ]
}

// MARK: - Details

extension AgentSamples {
    /// Lokaler Server mit kritischem Befund.
    static let fileServer = RecordDetailContent(
        symbol: "terminal", title: "dateien", subtitle: "Code-Assistent · Benutzer",
        items: [StatusItem("kritisch", tone: .critical), StatusItem("aktiv", tone: .positive)], finding: true,
        groups: [
            DetailGroupContent(id: "notes", title: "Hinweise", count: 2, notes: [
                DetailNoteContent("Darf den ganzen Benutzerordner lesen und schreiben.", kind: .critical),
                DetailNoteContent("Lädt das Paket bei jedem Start ohne feste Version nach.", kind: .finding),
            ]),
            DetailGroupContent(id: "start", title: "Start", facts: [
                DetailFactContent("Art", value: "lokal, startet ein Programm"),
                DetailFactContent("Befehl", value: "npx -y @example/server-files ~", isCode: true),
                DetailFactContent("Paketquelle", value: "npm, ohne feste Version", tone: .finding),
            ]),
            DetailGroupContent(id: "environment", title: "Umgebung", count: 1, facts: [
                DetailFactContent("EXAMPLE_TOKEN", value: "Wert im Klartext in der Datei", tone: .finding),
            ], notes: [DetailNoteContent("Grantry zeigt nur die Namen, nie die Werte.", kind: .info)]),
            DetailGroupContent(id: "configuration", title: "Konfiguration", facts: [
                DetailFactContent("Datei", value: "~/.example-assistant/config.json", isCode: true),
                DetailFactContent("Geltungsbereich", value: "alle Projekte dieses Benutzers"),
            ]),
            DetailGroupContent(id: "starter", title: "Rechte des Starters", notes: [
                DetailNoteContent("Der Code-Assistent startet in Terminal – der Server erbt dessen Berechtigungen.",
                                  kind: .info),
            ]),
        ]
    )

    /// Automatische Freigabe eines Werkzeugs.
    static let approval = RecordDetailContent(
        symbol: "exclamationmark.shield", title: "Automatische Freigabe", subtitle: "Code-Assistent",
        items: [StatusItem("prüfen", tone: .finding)], finding: true,
        notes: [DetailNoteContent("Der Assistent führt Befehle aus, ohne vorher zu fragen.", kind: .finding)],
        groups: [
            DetailGroupContent(id: "setting", title: "Einstellung", facts: [
                DetailFactContent("Einstellung", value: "autoApprove = true", isCode: true),
            ]),
            DetailGroupContent(id: "configuration", title: "Konfiguration", facts: [
                DetailFactContent("Datei", value: "~/.example-assistant/settings.json", isCode: true),
                DetailFactContent("Geltungsbereich", value: "alle Projekte dieses Benutzers"),
            ]),
        ]
    )
}

/// Lokaler Server aus dem zentralen `RecordDetailPanel` (LB-2.4, #541); `runningText` zeigt die laufende Aktion.
private struct FileServerDetail: View {
    var runningText: String?

    var body: some View {
        RecordDetailPanel(content: AgentSamples.fileServer) {
            InstrumentRowIcon(symbol: "terminal", size: InstrumentSize.shield)
        } actions: {
            DetailActions(runningText: runningText) {
                Button("Deaktivieren") {}
                Button("Server entfernen …", role: .destructive) {}
            }
            .disabled(runningText != nil)
        } accessory: { group in
            if group.id == "starter" {
                JumpRow(InstrumentRowContent(symbol: "internaldrive", title: "Festplattenvollzugriff",
                                             detail: "Terminal",
                                             status: StatusItem("erlaubt", tone: .positive)),
                        destination: "Berechtigungen") {}
            }
        }
    }
}

#Preview("LB-2.1 Agenten") {
    ScrollView { DesignGallery(page: .agentsDraft) }
}
