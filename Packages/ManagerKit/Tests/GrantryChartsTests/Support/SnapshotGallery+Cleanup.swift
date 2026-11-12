import SwiftUI
@testable import GrantryCharts

/// Aufräumen › App-Reste (LB-4.2, #548) mit festen Beispieldaten wie im abgenommenen Entwurf LB-4.1 (#547): erfundene
/// Kennungen unter `com.example`, Pfade nur unter `~`. Vorauswahl wie in der App: sichere Funde und verwaiste
/// Autostart-Einträge.
@MainActor
extension SnapshotGallery {
    enum LeftoversScene: String, CaseIterable, Sendable {
        case result = "ergebnis"
        case notSearched = "vor-der-suche"
        case searching = "suche-laeuft"
        case outdated = "veraltet"
        case trashing = "papierkorb-laeuft"
        case partial = "teilerfolg"
        case empty = "keine-reste"
    }

    static let leftoversSize = CGSize(width: 1000, height: 760)

    static func leftovers(_ scene: LeftoversScene) -> some View {
        LeftoversSample(scene: scene)
    }
}

private enum LeftoverSample {
    static let head = InventoryHead(
        verdict: "Reste von 2 Apps", finding: true,
        items: [StatusItem("1 Erweiterung", tone: .finding), StatusItem("2 unsicher", tone: .neutral)],
        facts: "6 Funde · 1,6 GB · Suche 14:32"
    )
    static let complete = CleanupProgress(title: "Suche vollständig", detail: "alle Orte gelesen · Suche 14:32",
                                          fraction: 1, tone: .positive)
    static let scope = "Ausgewählt: 3 Objekte (mindestens 1,5 GB), 1 Autostart-Eintrag"
    static let uncertain = StatusItem("Zuordnung unsicher", tone: .info)
}

private struct LeftoversSample: View {
    let scene: SnapshotGallery.LeftoversScene

    var body: some View {
        switch scene {
        case .result:
            CleanupBoard(head: LeftoverSample.head, progress: LeftoverSample.complete) {
                Segments()
            } content: {
                CleanupFindingList {
                    ExtensionGroup()
                    ScannerGroup()
                    NotesGroup()
                    SelectionGroupHeader(title: "Autostart-Einträge ohne Programm", count: 1)
                    SelectionCheckRow("com.example.scanner.helper", detail: "Beispiel GmbH", size: "",
                                      isOn: .constant(true))
                    SelectionGroupHeader(title: "Berechtigungen entfernter Apps", count: 1)
                    DetailItem(InstrumentRowContent(symbol: "camera", title: "Kamera", detail: "Alter Scanner")) {
                        InstrumentNote("Einzeln lassen sich Berechtigungen entfernter Apps nicht entfernen.")
                    } actions: {
                        EmptyView()
                    }
                    InstrumentNote("Nicht durchsucht (keine Leserechte): ~/Library/Containers")
                        .padding(InstrumentSpacing.group)
                }
            } bar: {
                Bar(scope: LeftoverSample.scope)
            }
        case .notSearched:
            CleanupBoard(head: InventoryHead(verdict: "Noch nicht gesucht", shield: .open, items: [],
                                             facts: "sucht nur auf Knopfdruck"), progress: nil) {
                Segments()
            } content: {
                InstrumentEmptyState(symbol: "trash.circle", title: "Noch nicht gesucht",
                                     message: "Die Suche startet nur, wenn du sie anstößt. Entfernt wird erst nach "
                                         + "deiner Bestätigung.")
            } bar: {
                Bar(scope: "Nichts ausgewählt", search: "Reste gelöschter Apps suchen")
            }
        case .searching:
            CleanupBoard(head: InventoryHead(verdict: "Suche läuft", shield: .open, items: [],
                                             facts: "1 Erweiterung ohne App"),
                         progress: CleanupProgress(title: "Suche läuft", detail: "35 % · noch ca. 20 s", fraction: 0.35,
                                                   tone: .info)) {
                Segments()
            } content: {
                CleanupFindingList { ExtensionGroup() }
            } bar: {
                Bar(scope: "Nichts ausgewählt", search: "Suche abbrechen")
            }
        case .outdated:
            CleanupBoard(head: LeftoverSample.head,
                         progress: CleanupProgress(title: "Ergebnis veraltet",
                                                   detail: "Suche 14:32 · Apps seitdem geändert", fraction: 1,
                                                   tone: .finding)) {
                Segments()
            } banner: {
                InstrumentBanner("Ergebnis veraltet", message: "Das Ergebnis ist veraltet – Apps haben sich seit der "
                    + "Suche geändert oder sie liegt länger zurück. Bitte erneut suchen.", tone: .finding)
            } content: {
                CleanupFindingList { ScannerGroup() }
            } bar: {
                Bar(scope: LeftoverSample.scope)
            }
        case .trashing:
            CleanupBoard(head: LeftoverSample.head, progress: LeftoverSample.complete) {
                Segments()
            } content: {
                CleanupFindingList { ScannerGroup().disabled(true) }
            } bar: {
                // Die laufende Aktion (kleiner Fortschritt) zeichnet `ImageRenderer` nicht; sie steht in der Galerie.
                Bar(scope: LeftoverSample.scope)
            }
        case .partial:
            CleanupBoard(head: InventoryHead(verdict: "Reste von 1 App", finding: true, items: [],
                                             facts: "1 Fund · 12 KB · Suche 14:35"),
                         progress: LeftoverSample.complete) {
                Segments()
            } banner: {
                InstrumentBanner("2 von 3 Objekten in den Papierkorb gelegt",
                                 message: "• ~/Library/Preferences/com.example.scanner.plist: wird gerade benutzt",
                                 tone: .finding)
            } content: {
                CleanupFindingList {
                    SelectionGroupHeader(title: "com.example.scanner", count: 1, size: "12 KB")
                    SelectionCheckRow("Einstellungen", detail: "~/Library/Preferences/com.example.scanner.plist",
                                      size: "12 KB", isOn: .constant(true))
                }
            } bar: {
                Bar(scope: "Ausgewählt: 1 Objekt (12 KB)")
            }
        case .empty:
            CleanupBoard(head: InventoryHead(verdict: "Ruhig", shield: .calm, items: [],
                                             facts: "keine Reste · Suche 14:32"),
                         progress: LeftoverSample.complete) {
                Segments()
            } content: {
                InstrumentEmptyState(symbol: "checkmark.circle", title: "Keine Reste gefunden",
                                     message: "Grantry hat keine Reste gelöschter Apps gefunden.")
            } bar: {
                Bar(scope: "Nichts ausgewählt")
            }
        }
    }
}

private struct Segments: View {
    var body: some View {
        InstrumentSegments("Bereich", selection: .constant(0),
                           options: [(0, "App-Reste"), (1, "Speicher"), (2, "Prozesse"), (3, "Belegung")])
    }
}

/// Leiste wie in der App: Suchen bzw. Abbrechen, Umfang, „In den Papierkorb legen …“ ohne Auswahl gesperrt.
private struct Bar: View {
    let scope: String
    var search = "Erneut suchen"

    var body: some View {
        InstrumentActionBar(scope: scope) {
            Button(search) {}
        } trailing: {
            Button("In den Papierkorb legen …") {}.disabled(scope == "Nichts ausgewählt")
        }
    }
}

private struct ExtensionGroup: View {
    var body: some View {
        SelectionGroupHeader(title: "Erweiterungen ohne App", count: 1, finding: true)
        DetailItem(InstrumentRowContent(symbol: "puzzlepiece.extension", title: "Scanner-Treiber",
                                        detail: "Systemerweiterung · aktiv", finding: true)) {
            InstrumentNote("Die App ist gelöscht, die Erweiterung läuft weiter. Entfernen über die Deinstallation des "
                + "Herstellers.", kind: .finding)
        } actions: {
            EmptyView()
        }
    }
}

private struct ScannerGroup: View {
    var body: some View {
        SelectionGroupHeader(title: "com.example.scanner", count: 3, size: "1,5 GB")
        SelectionCheckRow("Caches", detail: "~/Library/Caches/com.example.scanner", size: "1,4 GB", isOn: .constant(true))
        SelectionCheckRow("Container", detail: "~/Library/Containers/com.example.scanner", size: "96 MB",
                          isOn: .constant(true))
        SelectionCheckRow("Einstellungen", detail: "~/Library/Preferences/com.example.scanner.plist", size: "12 KB",
                          isOn: .constant(true))
    }
}

private struct NotesGroup: View {
    var body: some View {
        SelectionGroupHeader(title: "com.example.notes", count: 2, size: "86 MB")
        SelectionCheckRow("Programmdaten", detail: "~/Library/Application Support/Notizblock", size: "84 MB",
                          isOn: .constant(false), hint: LeftoverSample.uncertain)
        SelectionCheckRow("Gruppen-Container", detail: "~/Library/Group Containers/Q1W2E3.com.example.notes",
                          size: "2,1 MB", isOn: .constant(false), hint: LeftoverSample.uncertain)
    }
}
