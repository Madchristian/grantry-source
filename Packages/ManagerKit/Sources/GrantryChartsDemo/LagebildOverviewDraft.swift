import GrantryCharts
import SwiftUI

/// Entwurf LB-3.1 (#543, Spec docs/superpowers/specs/2026-11-10-lagebild-altansichten-design.md § 4.3, Entscheidung 4):
/// Übersicht im Lagebild – Lagezeile mit Urteil aus dem Scan, Zählkacheln mit Sprung, Panels „Beobachtung“ und „Letzte
/// Änderungen“, Banner für Voraussetzungen und Update, Abdeckung als Spur. Nur Galerie mit festen Beispieldaten; seit
/// LB-3.2 (#544) aus den zentralen Bausteinen `VerdictBar`, `JumpTileGrid`, `JumpTile`, `ObservationOverviewPanel` und
/// `RecentChangesOverviewPanel` gezeichnet.
struct OverviewDraftBoard: View {
    var body: some View {
        AreaDraftPage(title: "Lagebild · Übersicht",
                      subtitle: "Entwurf LB-3.1: Lagezeile mit Urteil, Zählkacheln, Beobachtung und letzte Änderungen, "
                          + "Banner – feste Beispieldaten") {
            AreaDraftCaption(text: "1 · Auffällig: Befunde und ein aus dem Netz erreichbarer Dienst")
            Self.primary
            AreaDraftCaption(text: "2 · Ruhig mit laufender Beobachtung (links) und unvollständig geprüft (rechts)")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                OverviewDraftScreen(verdict: OverviewSamples.calm, tiles: OverviewSamples.calmTiles,
                                    tileColumns: 3) {
                    OverviewObservationSample(state: .running)
                } changes: {
                    OverviewChangesSample(changes: Array(OverviewSamples.changes.prefix(2)))
                }
                OverviewDraftScreen(verdict: OverviewSamples.incomplete, tiles: OverviewSamples.calmTiles,
                                    tileColumns: 3) {
                    OverviewCoveragePanel()
                } changes: {
                    OverviewChangesSample(changes: [], emptyText: "Keine Änderungen erkannt – nicht alle Quellen "
                        + "wurden gelesen.")
                }
            }
            AreaDraftCaption(text: "3 · Banner: Voraussetzungen fehlen, Update verfügbar, Ablage nicht lesbar")
            OverviewBannersScreen()
            AreaDraftCaption(text: "4 · Noch kein Scan (links) und erster Scan läuft (rechts)")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                OverviewFirstScanScreen(isScanning: false)
                OverviewFirstScanScreen(isScanning: true)
            }
            AreaDraftCaption(text: "5 · Urteilsregel der Lagezeile")
            OverviewVerdictRule()
        }
    }
}

extension OverviewDraftBoard {
    /// Hauptzustand des Bereichs, auch auf der Galerieseite „Alle Ansichten“ (LB-5.5, #556).
    @ViewBuilder static var primary: some View {
        OverviewDraftScreen(verdict: OverviewSamples.findings, tiles: OverviewSamples.tiles) {
            OverviewObservationSample(state: .idle)
        } changes: {
            OverviewChangesSample(changes: OverviewSamples.changes)
        }
    }
}

// MARK: - Gerüst

/// Urteil der Lagezeile (Spec § 11 Entscheidung 4): Schild, Urteil, Grund in einem Satz, Chips und Kenndaten.
struct OverviewSampleVerdict {
    let verdict: String
    let reason: String
    var shield = ShieldForm.calm
    var items: [StatusItem] = []
    let facts: String
}

/// Beispieldaten einer Zählkachel (`JumpTile`); `destination` nennt den Bereich für VoiceOver und Hilfetext.
struct OverviewSampleTile: Identifiable {
    var id: String { title }
    let title: String
    let value: Int
    let detail: String
    let tone: StatusTone
    let destination: String
}

/// Übersicht: Lagezeile, Kacheln in einer Reihe (bzw. drei Spalten), darunter Beobachtung und letzte Änderungen.
struct OverviewDraftScreen<Observation: View, Changes: View>: View {
    let verdict: OverviewSampleVerdict
    let tiles: [OverviewSampleTile]
    var tileColumns = 5
    @ViewBuilder let observation: Observation
    @ViewBuilder let changes: Changes

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            VerdictBar(verdict: verdict.verdict, reason: verdict.reason, shield: verdict.shield,
                       items: verdict.items, facts: verdict.facts)
            JumpTileGrid(columns: tileColumns) {
                ForEach(tiles) { tile in
                    JumpTile(title: tile.title, value: tile.value, detail: tile.detail, tone: tile.tone,
                             destination: tile.destination) {}
                }
            }
            if tileColumns < 5 {
                observation
                changes
            } else {
                HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                    observation.frame(width: InstrumentSize.columnWide)
                    changes
                }
            }
        }
        .areaDraftFrame()
    }
}

// MARK: - Panels

/// Panel „Beobachtung“ (`ObservationOverviewPanel`): ohne laufende Beobachtung der Einstieg, sonst Stand und Sprung.
struct OverviewObservationSample: View {
    enum State { case idle, running }

    let state: State

    var body: some View {
        switch state {
        case .idle:
            ObservationOverviewPanel(state: .idle(
                message: "Neues Werkzeug? Grantry hält vor der Installation fest, was eingerichtet ist, und zeigt "
                    + "danach, was hinzugekommen ist – auf Wunsch räumt es das wieder auf.", isAvailable: true)) {} show: {}
        case .running:
            ObservationOverviewPanel(state: .running(
                since: "läuft seit 12 Min.", value: "4 neu",
                row: InstrumentRowContent(symbol: "binoculars", title: "Beispiel-Werkzeug",
                                          detail: "seit 14:20 · 4 neue Einträge", status: StatusItem("läuft", tone: .info)),
                destination: "Beobachtungen")) {} show: {}
        }
    }
}

/// Panel „Letzte Änderungen“ (`RecentChangesOverviewPanel`) mit Beispielzeilen; leer mit dem Satz zur Abdeckung.
struct OverviewChangesSample: View {
    let changes: [InstrumentRowContent]
    var emptyText = "Seit dem ersten Scan hat sich nichts geändert."

    var body: some View {
        RecentChangesOverviewPanel(
            changes: changes.map { RecentChangesOverviewPanel.Change(id: $0.title, row: $0, destination: "Verlauf") },
            emptyText: emptyText) {} select: { _ in }
    }
}

/// Abdeckung der Bereiche, die nicht vollständig gelesen wurden, je mit Sprung (heute `AreaCoverageBar`).
struct OverviewCoveragePanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
            PeilHead("Abdeckung", detail: "2 Bereiche unvollständig", finding: true)
            ProgressSpur(title: "Autostart", detail: "Hintergrundobjekte nicht gelesen", fraction: 3.0 / 4,
                         tone: .finding) {
                Button("Details anzeigen …") {}.buttonStyle(.link).font(InstrumentFont.label)
            }
            ProgressSpur(title: "Agenten", detail: "1 Konfiguration nicht lesbar", fraction: 5.0 / 6, tone: .finding) {
                Button("Details anzeigen …") {}.buttonStyle(.link).font(InstrumentFont.label)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }
}

/// Banner oben in der Übersicht, darunter der übrige Inhalt verkürzt.
struct OverviewBannersScreen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            InstrumentBanner("Voraussetzungen fehlen",
                             message: "Ohne Festplattenvollzugriff liest Grantry die Berechtigungen nicht.",
                             tone: .finding) {
                Button("Festplattenvollzugriff öffnen …") {}
                Button("Einrichtung öffnen …") {}
            }
            InstrumentBanner("Neue Version verfügbar", message: "Grantry 2026.11.12 steht zum Laden bereit.",
                             tone: .info) {
                Button("Prüfsumme") {}
                Button("Neuerungen") {}
                Button("Laden") {}.buttonStyle(.borderedProminent)
            }
            InstrumentNote("Der Verlauf ließ sich nicht speichern: Die Ablage ist schreibgeschützt.", kind: .critical)
            VerdictBar(verdict: OverviewSamples.findings.verdict, reason: OverviewSamples.findings.reason,
                       finding: true, items: OverviewSamples.findings.items, facts: OverviewSamples.findings.facts)
        }
        .areaDraftFrame()
    }
}

/// Vor dem ersten Scan: Lagezeile „Noch nicht geprüft“, darunter Leerzustand bzw. Fortschritt des ersten Scans.
struct OverviewFirstScanScreen: View {
    let isScanning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            VerdictBar(verdict: "Noch nicht geprüft",
                       reason: isScanning ? "Der erste Scan läuft; das Urteil folgt, sobald er fertig ist."
                           : "Ein Scan liest Apps, Berechtigungen, Autostart und Agenten ein.",
                       shield: .open, items: [], facts: "kein Scan seit dem Start")
            if isScanning {
                ProgressSpur(title: "Erster Scan", detail: "Berechtigungen · 3 von 7 Quellen", fraction: 3.0 / 7,
                             tone: .info)
                    .instrumentPanel()
                InstrumentEmptyState(symbol: "magnifyingglass", title: "Noch keine Daten", message: "Die Übersicht erscheint, sobald der erste Scan fertig ist.").instrumentPanel()
                    .frame(height: AreaDraftHeight.empty)
            } else {
                InstrumentEmptyState(symbol: "magnifyingglass", title: "Noch keine Daten", message: "„Jetzt scannen“ erfasst Berechtigungen und Autostart-Einträge.").instrumentPanel()
                    .frame(height: AreaDraftHeight.empty)
            }
        }
        .areaDraftFrame()
    }
}

/// Urteilsregel als Text im Entwurf (Issue #543): die erste zutreffende Zeile gilt; nur vorhandene Daten.
struct OverviewVerdictRule: View {
    private static let rules: [(verdict: String, rule: String)] = [
        ("Noch nicht geprüft", "Es gibt noch keinen abgeschlossenen Scan. Schildform offen (ohne Häkchen), keine Chips."),
        ("N Punkte auffällig", "Auffällige Einträge (Befund mittel oder hoch), offene Punkte der Sicherheit und aus "
            + "dem Netz erreichbare Dienste zusammen – dieselben Zahlen wie die Kacheln. Schild mit Befund-Punkt; Grund "
            + "ist der Punkt mit dem höchsten Schweregrad. Chips: kritisch (hoch), prüfen (mittel und Sicherheit), aus "
            + "dem Netz."),
        ("Unvollständig geprüft", "Keine Befunde, aber mindestens eine Quelle nicht gelesen. Keine Entwarnung: "
            + "Schildform offen, Chip „N Bereiche unvollständig“, Abdeckung als Spur."),
        ("Ruhig", "Keine Befunde, nichts aus dem Netz erreichbar, alle Quellen gelesen. Neue Einträge der letzten 7 "
            + "Tage als ruhiger Chip, nicht als Befund."),
    ]

    var body: some View {
        DetailPanel {
            DetailGroup("Lagezeile der Übersicht", count: Self.rules.count) {
                ForEach(Self.rules, id: \.verdict) { DetailEntry($0.verdict, value: $0.rule) }
            }
            InstrumentNote("Chips höchstens drei, in der Reihenfolge kritisch, prüfen, aus dem Netz, neu, "
                + "unvollständig. Kenndaten rechts: Scanzeit und Abdeckung. Bernstein nur mit Befund.", kind: .info)
        }
        .frame(height: AreaDraftHeight.overviewRule)
    }
}

extension AreaDraftHeight {
    static let overviewRule: CGFloat = 210
}

// MARK: - Beispieldaten

private enum OverviewSamples {
    static let findings = OverviewSampleVerdict(
        verdict: "4 Punkte auffällig",
        reason: "Fernhilfe darf andere Apps steuern und ist nicht notarisiert; dazu ein offener Punkt der Sicherheit "
            + "und ein Dienst, der Verbindungen aus dem Netz annimmt.",
        shield: .finding,
        items: [StatusItem("1 kritisch", tone: .critical), StatusItem("2 prüfen", tone: .finding),
                StatusItem("1 aus dem Netz", tone: .finding)],
        facts: "Scan 14:32 · Abdeckung vollständig"
    )

    static let calm = OverviewSampleVerdict(
        verdict: "Ruhig", reason: "Keine Befunde, nichts aus dem Netz erreichbar, alle Quellen gelesen.",
        items: [StatusItem("3 neu seit 7 Tagen", tone: .neutral)], facts: "Scan 14:32 · Abdeckung vollständig"
    )

    static let incomplete = OverviewSampleVerdict(
        verdict: "Unvollständig geprüft",
        reason: "Keine Befunde in dem, was gelesen wurde; zwei Bereiche sind nicht vollständig.",
        shield: .open,
        items: [StatusItem("2 Bereiche unvollständig", tone: .neutral)], facts: "Scan 14:32 · 2 Quellen fehlen"
    )

    static let tiles = [
        OverviewSampleTile(title: "Apps mit Zugriff", value: 18, detail: "mit mindestens einer Berechtigung", tone: .neutral,
                  destination: "Berechtigungen"),
        OverviewSampleTile(title: "Neu seit 7 Tagen", value: 3, detail: "Apps, Rechte, Autostart, Agenten", tone: .info,
                  destination: "Verlauf"),
        OverviewSampleTile(title: "Auffällig", value: 2, detail: "1 hoch · 1 mittel", tone: .finding, destination: "Apps"),
        OverviewSampleTile(title: "Sicherheit", value: 1, detail: "1 Punkt offen", tone: .finding, destination: "Sicherheit"),
        OverviewSampleTile(title: "Aus dem Netz erreichbar", value: 1, detail: "Dienst nimmt Verbindungen an", tone: .finding,
                  destination: "Netzwerk"),
    ]

    static let calmTiles = [
        OverviewSampleTile(title: "Apps mit Zugriff", value: 16, detail: "mit mindestens einer Berechtigung", tone: .neutral,
                  destination: "Berechtigungen"),
        OverviewSampleTile(title: "Neu seit 7 Tagen", value: 3, detail: "Apps, Rechte, Autostart, Agenten", tone: .info,
                  destination: "Verlauf"),
        OverviewSampleTile(title: "Auffällig", value: 0, detail: "keine Befunde", tone: .positive, destination: "Apps"),
        OverviewSampleTile(title: "Sicherheit", value: 0, detail: "alles geschützt", tone: .positive, destination: "Sicherheit"),
        OverviewSampleTile(title: "Aus dem Netz erreichbar", value: 0, detail: "keine Dienste", tone: .positive,
                  destination: "Netzwerk"),
    ]

    static let changes = [
        InstrumentRowContent(symbol: "plus", title: "com.example.updater", detail: "Autostart · vor 12 Minuten",
                             status: StatusItem("neu", tone: .info)),
        InstrumentRowContent(symbol: "plus", title: "Bildschirmaufnahme für Fernhilfe",
                             detail: "Berechtigung · vor 1 Stunde", status: StatusItem("neu", tone: .info)),
        InstrumentRowContent(symbol: "pencil", title: "Beispiel-Server", detail: "Agenten · Befehl geändert · gestern",
                             status: StatusItem("geändert", tone: .neutral)),
        InstrumentRowContent(symbol: "minus", title: "com.example.scanner.agent", detail: "Autostart · Montag",
                             status: StatusItem("entfernt", tone: .neutral)),
    ]
}

#Preview("LB-3.1 Übersicht") {
    ScrollView { DesignGallery(page: .overviewDraft) }
}
