import GrantryCharts
import SwiftUI

/// Entwurf LB-4.1 (#547): Blatt „App entfernen“ – Kopf mit App, Gruppen der Reste, Berechtigungen und Autostart-Einträge
/// als Häkchenzeilen, Umfang und Knöpfe in der Leiste unten; Suche läuft, App läuft, Homebrew, Grantry selbst und der
/// Fortschritt der Selbstdeinstallation bis zum Teilerfolg. Apps, Pfade und Werte sind erfunden; App-Symbole stehen wie
/// in den Snapshot-Tests als Platzhalter.
struct RemovalDraftBoard: View {
    var body: some View {
        AreaDraftPage(title: "Lagebild · Blatt App entfernen",
                      subtitle: "Entwurf LB-4.1: Kopf mit App und Ort, Hinweise unter dem Kopf, Gruppen mit "
                          + "Häkchenzeilen, Umfang und Knöpfe in der Leiste unten – feste Beispieldaten") {
            AreaDraftCaption(text: "1 · Auswahl (Vorauswahl wie heute: sichere Funde, zulässige und eindeutige Einträge) "
                + "und Suche läuft")
            Self.primary
            AreaDraftCaption(text: "2 · App läuft (links) und mit Homebrew installiert (rechts)")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                RemovalDraftSheet(title: "„Fernhilfe“ entfernen", path: "/Applications/Fernhilfe.app") {
                    InstrumentBanner("„Fernhilfe“ läuft", message: "Zum Entfernen zuerst beenden.", tone: .finding) { Button("Beenden") {} }
                } content: {
                    CleanupDraftList {
                        SelectionGroupHeader(title: "App", count: 1, size: "186 MB")
                        SelectionCheckRow("Fernhilfe.app", detail: "/Applications", size: "186 MB", isOn: .constant(true))
                    }
                } bar: {
                    RemovalBar(scope: "Ausgewählt: 1 Objekt (186 MB)", confirm: "In den Papierkorb legen",
                               isEnabled: false)
                }
                RemovalDraftSheet(title: "„Videokonferenz“ entfernen", path: "/Applications/Videokonferenz.app") {
                    EmptyView()
                } content: {
                    CleanupDraftList {
                        DetailItem(InstrumentRowContent(symbol: "terminal", title: "Mit Homebrew installiert",
                                                        detail: "Entferne die App im Terminal")) {
                            DetailEntry("Befehl", value: "brew uninstall --cask videokonferenz", isCode: true)
                        } actions: {
                            Button("Befehl kopieren") {}
                        }
                        InstrumentNote("Die Reste findet danach der Bereich „Aufräumen“.")
                            .padding(InstrumentSpacing.group)
                    }
                } bar: {
                    RemovalBar(scope: "Grantry entfernt diese App nicht selbst", cancel: "Schließen")
                }
            }
            AreaDraftCaption(text: "3 · Grantry deinstallieren: Auswahl (links) und Fortschritt (rechts)")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                RemovalDraftSheet(title: "Grantry deinstallieren", path: "/Applications/Grantry.app") {
                    InstrumentNote("Grantry meldet den Hintergrunddienst und „Beim Anmelden starten“ ab, setzt die "
                        + "gewählten Berechtigungen zurück, legt die Auswahl in den Papierkorb und beendet sich. "
                        + "Einmal gestartet, lässt sich der Vorgang nicht abbrechen.")
                } content: {
                    CleanupDraftList {
                        SelectionGroupHeader(title: "App", count: 1, size: "38 MB")
                        SelectionCheckRow("Grantry.app", detail: "/Applications", size: "38 MB", isOn: .constant(true))
                        SelectionGroupHeader(title: "Berechtigungen zurücksetzen", count: 1)
                        SelectionCheckRow("Festplattenvollzugriff", detail: "Grantry", size: "–", isOn: .constant(true))
                    }
                } bar: {
                    RemovalBar(scope: "Ausgewählt: 1 Objekt (38 MB), 1 Berechtigung", confirm: "Grantry deinstallieren")
                }
                SelfUninstallDraft(title: "Grantry wird deinstalliert …", steps: SelfUninstallSamples.running,
                                   hint: "Der Finder legt die Auswahl in den Papierkorb. Fragt er nach dem Passwort, "
                                       + "bitte dort bestätigen.")
            }
            AreaDraftCaption(text: "4 · Selbstdeinstallation: Teilerfolg (links) und abgeschlossen (rechts)")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                SelfUninstallDraft(title: "Deinstallation nicht abgeschlossen", steps: SelfUninstallSamples.partial,
                                   outcome: SelfUninstallOutcome(title: "Grantry liegt im Papierkorb, der Hintergrunddienst ist "
                                                             + "noch angemeldet.", tone: .finding,
                                                         details: ["Abmelden: macOS meldet einen Fehler (Zeitüberschreitung)."]),
                                   buttons: ["Anmeldeobjekte öffnen"], close: "Beenden", retry: true)
                SelfUninstallDraft(title: "Grantry deinstalliert", steps: SelfUninstallSamples.finished,
                                   outcome: SelfUninstallOutcome(title: "Grantry liegt im Papierkorb.", tone: .positive,
                                                         details: []),
                                   close: "Beenden")
            }
        }
    }
}

extension RemovalDraftBoard {
    /// Hauptzustand des Bereichs, auch auf der Galerieseite „Alle Ansichten“ (LB-5.5, #556).
    @ViewBuilder static var primary: some View {
        HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
            RemovalDraftSheet(title: "„Alter Scanner“ entfernen", path: "/Applications/Alter Scanner.app") {
                InstrumentNote("Bringt eine Systemerweiterung mit; sie bleibt nach dem Entfernen aktiv, bis du sie "
                    + "in „Erweiterungen“ entfernst.")
            } content: {
                RemovalFindings()
            } bar: {
                RemovalBar(scope: "Ausgewählt: 3 Objekte (1,7 GB), 1 Berechtigung, 1 Autostart-Eintrag",
                           confirm: "In den Papierkorb legen")
            }
            RemovalDraftSheet(title: "„Alter Scanner“ entfernen", path: "/Applications/Alter Scanner.app") {
                EmptyView()
            } content: {
                VStack(spacing: InstrumentSpacing.panel) {
                    ProgressSpur(title: "Reste werden gesucht", detail: "Caches · 48 von 120 Orten",
                                 fraction: 0.4, tone: .info)
                    Spacer(minLength: 0)
                }
                .padding(InstrumentSpacing.panel)
            } bar: {
                RemovalBar(scope: "Nichts ausgewählt", confirm: "In den Papierkorb legen", isEnabled: false)
            }
        }
    }
}

// MARK: - Gerüst

/// Blatt im Lagebild aus `RemovalSheetBoard` mit Platzhalter-Symbol; im Bild hat das Panel die Höhe seines Inhalts, die
/// Fundliste rollt nicht (im Fenster `CleanupFindingList`).
private struct RemovalDraftSheet<Notes: View, Content: View, Bar: View>: View {
    let title: String
    let path: String
    @ViewBuilder let notes: Notes
    @ViewBuilder let content: Content
    @ViewBuilder let bar: Bar

    var body: some View {
        RemovalSheetBoard(title: title, path: path) {
            InstrumentRowIcon(symbol: "app.dashed", size: InstrumentSize.shield)
        } notes: {
            notes
        } content: {
            content
        } bar: {
            bar
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay {
            RoundedRectangle(cornerRadius: InstrumentRadius.panel, style: .continuous)
                .strokeBorder(.instrumentSecondary, lineWidth: InstrumentStroke.border)
                .accessibilityHidden(true)
        }
    }
}

/// Leiste des Blatts: Umfang links, rechts „Abbrechen“ bzw. „Schließen“ und die bestätigende Aktion (zerstörerisch, nie
/// Standardknopf: Return und Escape brechen ab wie heute).
private struct RemovalBar: View {
    let scope: String
    var confirm: String?
    var cancel = "Abbrechen"
    var isEnabled = true

    var body: some View {
        InstrumentActionBar(scope: scope) {
            EmptyView()
        } trailing: {
            Button(cancel) {}.keyboardShortcut(.cancelAction)
            if let confirm {
                Button(confirm, role: .destructive) {}.disabled(!isEnabled)
            }
        }
    }
}

/// Reste nach Art, Berechtigungen und Autostart-Einträge der App.
private struct RemovalFindings: View {
    var body: some View {
        CleanupDraftList {
            SelectionGroupHeader(title: "App", count: 1, size: "64 MB")
            SelectionCheckRow("Alter Scanner.app", detail: "/Applications", size: "64 MB", isOn: .constant(true))
            SelectionGroupHeader(title: "Caches", count: 1, size: "1,4 GB")
            SelectionCheckRow("~/Library/Caches/com.example.scanner", detail: "Zuordnung sicher", size: "1,4 GB",
                              isOn: .constant(true))
            SelectionGroupHeader(title: "Programmdaten", count: 2, size: "246 MB")
            SelectionCheckRow("~/Library/Application Support/Alter Scanner", detail: "Zuordnung sicher",
                              size: "240 MB", isOn: .constant(true))
            SelectionCheckRow("~/Library/Application Support/Beispiel GmbH", detail: "weitere Apps desselben Herstellers",
                              size: "6,1 MB", isOn: .constant(false), hint: StatusItem("Zuordnung unsicher", tone: .info))
            SelectionGroupHeader(title: "Berechtigungen zurücksetzen", count: 2)
            SelectionCheckRow("Kamera", detail: "Benutzer", size: "–", isOn: .constant(true))
            SelectionCheckRow("Bedienungshilfen", detail: "Gehört evtl. auch zu: Alter Scanner (~/Applications)",
                              size: "–", isOn: .constant(false), hint: StatusItem("mehrfach installiert", tone: .info))
            SelectionGroupHeader(title: "Autostart-Einträge entfernen", count: 2)
            SelectionCheckRow("com.example.scanner.agent", detail: "~/Library/LaunchAgents", size: "4 KB",
                              isOn: .constant(true))
            SelectionCheckRow("com.example.scanner.daemon", detail: "/Library/LaunchDaemons", size: "4 KB",
                              isOn: .constant(false), lockedReason: "Systemordner – nur mit Helper")
            InstrumentNote("Dieselbe App ist mehrfach installiert. Was beide Installationen träfe, ist nicht "
                + "vorausgewählt.")
                .padding(InstrumentSpacing.group)
        }
    }
}

// MARK: - Selbstdeinstallation

/// Ergebnis der Selbstdeinstallation: Satz im Zustandston, Einzelheiten darunter.
struct SelfUninstallOutcome {
    let title: String
    let tone: StatusTone
    let details: [String]
}

private enum SelfUninstallSamples {
    static let doneState = StatusItem("Erledigt", tone: .positive)
    static let pending = StatusItem("Ausstehend", tone: .neutral)
    static let titles = ["Finder-Freigabe prüfen", "Hintergrunddienst und „Beim Anmelden starten“ abmelden",
                         "Berechtigungen zurücksetzen", "In den Papierkorb legen", "Finder-Automation zurücksetzen"]

    static func steps(_ states: [StatusItem], running: Int? = nil) -> [ProcedureStep] {
        zip(titles, states).enumerated().map { index, pair in
            ProcedureStep(id: pair.0, title: pair.0, state: pair.1, isRunning: index == running)
        }
    }

    static let running = steps([doneState, doneState, doneState, StatusItem("Läuft …", tone: .info), pending],
                               running: 3)
    static let partial = steps([doneState, StatusItem("Fehlgeschlagen", tone: .critical), doneState, doneState,
                                StatusItem("Nicht ausgeführt", tone: .neutral)])
    static let finished = steps(Array(repeating: doneState, count: titles.count))
}

/// Fortschritt und Bericht von „Grantry deinstallieren“ im selben Blatt: Schritte auf der Mulde mit Zustandschip, Hinweis
/// zum laufenden Schritt, danach Ergebnis und Knöpfe; während des Ablaufs bewusst ohne Abbrechen.
private struct SelfUninstallDraft: View {
    let title: String
    let steps: [ProcedureStep]
    var hint: String?
    var outcome: SelfUninstallOutcome?
    var buttons: [String] = []
    var close: String?
    var retry = false

    var body: some View {
        RemovalDraftSheet(title: title, path: "/Applications/Grantry.app") {
            if let outcome {
                InstrumentBanner(outcome.title, message: outcome.details.joined(separator: " "), tone: outcome.tone)
            }
        } content: {
            VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
                ProcedureStepList(steps: steps)
                if let hint {
                    InstrumentNote(hint)
                }
            }
            .padding(InstrumentSpacing.panel)
        } bar: {
            InstrumentActionBar(scope: outcome == nil ? "Läuft – lässt sich nicht abbrechen" : "") {
                ForEach(buttons, id: \.self) { Button($0) {} }
            } trailing: {
                if let close { Button(close) {} }
                if retry { Button("Erneut versuchen") {}.keyboardShortcut(.defaultAction) }
            }
        }
    }
}

#Preview("LB-4.1 App entfernen") {
    ScrollView { DesignGallery(page: .removalDraft) }
}
