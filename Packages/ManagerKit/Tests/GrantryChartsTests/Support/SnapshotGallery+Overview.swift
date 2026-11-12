import SwiftUI
@testable import GrantryCharts

/// Übersicht im Lagebild (LB-3.2, #544) mit festen Beispieldaten wie im abgenommenen Entwurf LB-3.1 (#543): Lagezeile,
/// Zählkacheln mit Sprung, Beobachtung und letzte Änderungen. Erfundene Einträge unter `com.example`.
@MainActor
extension SnapshotGallery {
    enum OverviewScene: String, CaseIterable, Sendable {
        case findings = "auffaellig"
        case calm = "ruhig"
        case incomplete = "unvollstaendig"
        case notScanned = "kein-scan"
    }

    static let overviewSize = CGSize(width: 1180, height: 560)

    static func overview(_ scene: OverviewScene) -> some View {
        OverviewSample(scene: scene)
    }

    /// Kacheln wie im Entwurf: Titel, Zahl, Detail, Ton und Ziel.
    static func overviewTiles(flagged: Bool) -> [(String, Int, String, StatusTone, String)] {
        [
            ("Apps mit Zugriff", flagged ? 18 : 16, "mit mindestens einer Berechtigung", .neutral, "Berechtigungen"),
            ("Neu seit 7 Tagen", 3, "Apps, Rechte, Autostart, Agenten", .info, "Verlauf"),
            ("Auffällig", flagged ? 2 : 0, flagged ? "1 hoch · 1 mittel" : "keine Befunde",
             flagged ? .finding : .positive, "Apps"),
            ("Sicherheit", flagged ? 1 : 0, flagged ? "1 Punkt offen" : "alles geschützt",
             flagged ? .finding : .positive, "Sicherheit"),
            ("Aus dem Netz erreichbar", flagged ? 1 : 0, flagged ? "Dienst nimmt Verbindungen an" : "keine Dienste",
             flagged ? .finding : .positive, "Netzwerk"),
        ]
    }

    static let overviewChanges = [
        RecentChangesOverviewPanel.Change(
            id: "1", row: InstrumentRowContent(symbol: "plus", title: "com.example.updater",
                                               detail: "Neuer Autostart-Eintrag · vor 12 Minuten",
                                               status: StatusItem("neu", tone: .info)), destination: "Autostart"),
        RecentChangesOverviewPanel.Change(
            id: "2", row: InstrumentRowContent(symbol: "pencil", title: "Beispiel-Server: Befehl geändert.",
                                               detail: "MCP-Server geändert · gestern",
                                               status: StatusItem("geändert", tone: .neutral)), destination: "Agenten"),
        RecentChangesOverviewPanel.Change(
            id: "3", row: InstrumentRowContent(symbol: "minus", title: "com.example.scanner.agent",
                                               detail: "Autostart-Eintrag entfernt · Montag",
                                               status: StatusItem("entfernt", tone: .neutral)), destination: "Verlauf"),
    ]
}

private struct OverviewSample: View {
    let scene: SnapshotGallery.OverviewScene

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            switch scene {
            case .findings:
                VerdictBar(verdict: "4 Punkte auffällig",
                           reason: "Fernhilfe darf andere Apps steuern; dazu ein weiterer auffälliger Eintrag, ein "
                               + "offener Punkt der Sicherheit und ein Dienst, der Verbindungen aus dem Netz annimmt.",
                           shield: .finding,
                           items: [StatusItem("1 kritisch", tone: .critical), StatusItem("2 prüfen", tone: .finding),
                                   StatusItem("1 aus dem Netz", tone: .finding)],
                           facts: "Scan 14:32 · Abdeckung vollständig")
                tiles(flagged: true)
                panels(running: false, changes: SnapshotGallery.overviewChanges)
            case .calm:
                VerdictBar(verdict: "Ruhig", reason: "Keine Befunde, nichts aus dem Netz erreichbar, alle Quellen gelesen.",
                           shield: .calm, items: [StatusItem("3 neu seit 7 Tagen", tone: .neutral)],
                           facts: "Scan 14:32 · Abdeckung vollständig")
                tiles(flagged: false)
                panels(running: true, changes: Array(SnapshotGallery.overviewChanges.prefix(2)))
            case .incomplete:
                VerdictBar(verdict: "Unvollständig geprüft",
                           reason: "Keine Befunde in dem, was gelesen wurde; 2 Bereiche sind nicht vollständig.",
                           shield: .open, items: [StatusItem("2 Bereiche unvollständig", tone: .neutral)],
                           facts: "Scan 14:32 · 2 Quellen fehlen")
                tiles(flagged: false)
                panels(running: false, changes: [])
            case .notScanned:
                VerdictBar(verdict: "Noch nicht geprüft",
                           reason: "Ein Scan liest Apps, Berechtigungen, Autostart und Agenten ein.",
                           shield: .open, items: [], facts: "kein Scan seit dem Start")
                InstrumentEmptyState(symbol: "magnifyingglass", title: "Noch keine Daten",
                                     message: "„Jetzt scannen“ erfasst Berechtigungen und Autostart-Einträge.")
                    .frame(maxWidth: .infinity, minHeight: InstrumentSize.detailMin)
                    .instrumentPanel()
            }
        }
        .padding(InstrumentSpacing.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .instrumentBackground()
    }

    private func tiles(flagged: Bool) -> some View {
        JumpTileGrid(columns: 5) {
            ForEach(SnapshotGallery.overviewTiles(flagged: flagged), id: \.0) { tile in
                JumpTile(title: tile.0, value: tile.1, detail: tile.2, tone: tile.3, destination: tile.4) {}
            }
        }
    }

    private func panels(running: Bool, changes: [RecentChangesOverviewPanel.Change]) -> some View {
        HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
            ObservationOverviewPanel(state: running
                ? .running(since: "läuft seit 12 Min.", value: "4 neu",
                           row: InstrumentRowContent(symbol: "binoculars", title: "Beispiel-Werkzeug",
                                                     detail: "seit 14:20 · 4 neue Einträge",
                                                     status: StatusItem("läuft", tone: .info)),
                           destination: "Beobachtungen")
                : .idle(message: "Neues Tool? Beobachte die Installation – Grantry zeigt danach, was hinzugekommen "
                    + "ist, und räumt es auf Wunsch wieder auf.", isAvailable: true)) {} show: {}
                .frame(width: InstrumentSize.columnWide)
            RecentChangesOverviewPanel(changes: changes,
                                       emptyText: "Keine Änderungen erkannt – nicht alle Quellen wurden gelesen.") {
            } select: { _ in }
        }
    }
}
