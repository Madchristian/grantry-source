import SwiftUI
@testable import GrantryCharts

/// Blatt „App entfernen“ (LB-4.5, #551) mit festen Beispieldaten wie im abgenommenen Entwurf LB-4.1 (#547): erfundene
/// Apps unter `com.example`, keine Benutzernamen oder echten Pfade; App-Symbole als Platzhalter.
@MainActor
extension SnapshotGallery {
    enum RemovalScene: String, CaseIterable, Sendable {
        case selection = "auswahl"
        case searching = "suche"
        case running = "app-laeuft"
        case homebrew
        case grantry
        case uninstallRunning = "deinstallation-laeuft"
        case partial = "teilerfolg"
        case finished = "abgeschlossen"
    }

    static let removalSize = CGSize(width: RemovalSheetLayout.width, height: 780)
    static let removalScope = "Ausgewählt: 3 Objekte (1,7 GB), 1 Berechtigung, 1 Autostart-Eintrag"

    static func removal(_ scene: RemovalScene) -> some View {
        RemovalSheetSample(scene: scene)
            .frame(width: removalSize.width, height: removalSize.height, alignment: .top)
            .instrumentBackground()
    }

    static let uninstallTitles = ["Finder-Freigabe prüfen", "Hintergrunddienst und „Beim Anmelden starten“ abmelden",
                                  "Berechtigungen zurücksetzen", "In den Papierkorb legen",
                                  "Finder-Automation zurücksetzen"]

    static func uninstallSteps(_ states: [StatusItem], running: Int? = nil) -> [ProcedureStep] {
        zip(uninstallTitles, states).enumerated().map { index, pair in
            ProcedureStep(id: pair.0, title: pair.0, state: pair.1, isRunning: index == running)
        }
    }

    static let stepDone = StatusItem("Erledigt", tone: .positive)
}

/// Ein Zustand des Blatts aus zentralen Bausteinen; Leiste mit Umfang (Knöpfe zeichnet der Renderer nicht).
private struct RemovalSheetSample: View {
    let scene: SnapshotGallery.RemovalScene

    var body: some View {
        switch scene {
        case .selection:
            sheet("„Alter Scanner“ entfernen", path: "/Applications/Alter Scanner.app",
                  scope: SnapshotGallery.removalScope) {
                InstrumentNote("Bringt eine Systemerweiterung mit; sie bleibt nach dem Entfernen aktiv, bis du sie in "
                    + "„Erweiterungen“ entfernst.")
            } content: {
                list {
                    SelectionGroupHeader(title: "App", count: 1, size: "64 MB")
                    SelectionCheckRow("Alter Scanner.app", detail: "/Applications", size: "64 MB", isOn: .constant(true))
                    SelectionGroupHeader(title: "Caches", count: 1, size: "1,4 GB")
                    SelectionCheckRow("~/Library/Caches/com.example.scanner", detail: "Zuordnung sicher",
                                      size: "1,4 GB", isOn: .constant(true))
                    SelectionGroupHeader(title: "Programmdaten", count: 2, size: "246 MB")
                    SelectionCheckRow("~/Library/Application Support/Alter Scanner", detail: "Zuordnung sicher",
                                      size: "240 MB", isOn: .constant(true))
                    SelectionCheckRow("~/Library/Application Support/Beispiel GmbH",
                                      detail: "weitere Apps desselben Herstellers", size: "6,1 MB",
                                      isOn: .constant(false), hint: StatusItem("Zuordnung unsicher", tone: .info))
                    SelectionGroupHeader(title: "Berechtigungen zurücksetzen", count: 2)
                    SelectionCheckRow("Kamera", detail: "Benutzer", size: "–", isOn: .constant(true))
                    SelectionCheckRow("Bedienungshilfen", detail: "Benutzer", size: "–", isOn: .constant(false))
                    InstrumentNote("Gehört evtl. auch zu: Alter Scanner (~/Applications/Alter Scanner.app)",
                                   kind: .finding)
                    SelectionGroupHeader(title: "Autostart-Einträge entfernen", count: 2)
                    SelectionCheckRow("com.example.scanner.agent", detail: "Alter Scanner", size: "",
                                      isOn: .constant(true))
                    SelectionCheckRow("com.example.scanner.daemon", detail: "Alter Scanner", size: "",
                                      isOn: .constant(false), lockedReason: "Systemordner – nur mit Helper")
                    InstrumentNote("Dieselbe App ist mehrfach installiert. Was beide Installationen träfe, ist nicht "
                        + "vorausgewählt.")
                }
            }
        case .searching:
            sheet("„Alter Scanner“ entfernen", path: "/Applications/Alter Scanner.app", scope: "Nichts ausgewählt") {
                EmptyView()
            } content: {
                ProgressSpur(title: "Reste werden gesucht", detail: "", fraction: nil, tone: .info)
                    .padding(InstrumentSpacing.panel)
            }
        case .running:
            sheet("„Fernhilfe“ entfernen", path: "/Applications/Fernhilfe.app",
                  scope: "Ausgewählt: 1 Objekt (186 MB)") {
                InstrumentBanner("„Fernhilfe“ läuft", message: "Zum Entfernen zuerst beenden.", tone: .finding)
            } content: {
                list {
                    SelectionGroupHeader(title: "App", count: 1, size: "186 MB")
                    SelectionCheckRow("Fernhilfe.app", detail: "/Applications", size: "186 MB", isOn: .constant(true))
                }
            }
        case .homebrew:
            sheet("„Videokonferenz“ entfernen", path: "/Applications/Videokonferenz.app",
                  scope: "Grantry entfernt diese App nicht selbst") {
                EmptyView()
            } content: {
                list {
                    DetailItem(InstrumentRowContent(symbol: "terminal", title: "Mit Homebrew installiert",
                                                    detail: "Entferne die App im Terminal")) {
                        DetailEntry("Befehl", value: "brew uninstall --cask videokonferenz", isCode: true)
                    } actions: {
                        EmptyView()
                    }
                    InstrumentNote("Die Reste findet danach der Bereich „Aufräumen“.")
                }
            }
        case .grantry:
            sheet("Grantry deinstallieren", path: "/Applications/Grantry.app",
                  scope: "Ausgewählt: 1 Objekt (38 MB), 1 Berechtigung") {
                InstrumentNote("Grantry meldet den Hintergrunddienst und „Beim Anmelden starten“ ab, setzt die "
                    + "gewählten Berechtigungen zurück, legt die Auswahl in den Papierkorb und beendet sich.")
            } content: {
                list {
                    SelectionGroupHeader(title: "App", count: 1, size: "38 MB")
                    SelectionCheckRow("Grantry.app", detail: "/Applications", size: "38 MB", isOn: .constant(true))
                    SelectionGroupHeader(title: "Berechtigungen zurücksetzen", count: 1)
                    SelectionCheckRow("Festplattenvollzugriff", detail: "Grantry", size: "", isOn: .constant(true))
                }
            }
        case .uninstallRunning:
            progress("Grantry wird deinstalliert …", scope: "Läuft – lässt sich nicht abbrechen",
                     steps: SnapshotGallery.uninstallSteps([done, done, done, StatusItem("Läuft …", tone: .info),
                                                            StatusItem("Ausstehend", tone: .neutral)], running: 3),
                     notes: ["Der Finder legt die Auswahl in den Papierkorb. Fragt er nach dem Passwort, bitte dort "
                         + "bestätigen."]) {
                EmptyView()
            }
        case .partial:
            progress("Deinstallation nicht abgeschlossen", scope: "",
                     steps: SnapshotGallery.uninstallSteps([done, StatusItem("Fehlgeschlagen", tone: .critical), done,
                                                            done, StatusItem("Nicht ausgeführt", tone: .neutral)]),
                     notes: ["„Erneut versuchen“ setzt nur die noch offenen Teile der bestätigten Auswahl fort; "
                         + "Erledigtes wird nicht wiederholt."]) {
                InstrumentBanner("Grantry liegt im Papierkorb, der Hintergrunddienst ist noch angemeldet.",
                                 message: "• Abmelden: macOS meldet einen Fehler (Zeitüberschreitung).", tone: .finding)
            }
        case .finished:
            progress("Grantry deinstalliert", scope: "",
                     steps: SnapshotGallery.uninstallSteps(Array(repeating: done, count: 5)), notes: []) {
                InstrumentBanner("Grantry liegt im Papierkorb.", message: "", tone: .positive)
            }
        }
    }

    private var done: StatusItem { SnapshotGallery.stepDone }

    private func list(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.stack) { content() }
            .padding(InstrumentSpacing.item)
    }

    private func sheet(_ title: String, path: String, scope: String, @ViewBuilder notes: () -> some View,
                       @ViewBuilder content: () -> some View) -> some View {
        RemovalSheetBoard(title: title, path: path) {
            InstrumentRowIcon(symbol: "app.dashed", size: InstrumentSize.shield)
        } notes: {
            notes()
        } content: {
            content()
        } bar: {
            InstrumentActionBar(scope: scope) { EmptyView() } trailing: { EmptyView() }
        }
    }

    private func progress(_ title: String, scope: String, steps: [ProcedureStep], notes: [String],
                          @ViewBuilder banner: () -> some View) -> some View {
        sheet(title, path: "/Applications/Grantry.app", scope: scope, notes: banner) {
            VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
                ProcedureStepList(steps: steps)
                ForEach(notes, id: \.self) { InstrumentNote($0) }
            }
            .padding(InstrumentSpacing.panel)
        }
    }
}
