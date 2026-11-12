import SwiftUI
@testable import GrantryCharts

/// Menüleisten-Menü im Lagebild (LB-5.4, #555) mit festen Beispieldaten wie im abgenommenen Entwurf LB-5.1 (#552):
/// Lagezeile mit Schild, Hinweise, Beobachtung, letzte Änderungen und Befehle aus den zentralen Bausteinen
/// (`MenuBarMenu`, `SettingsPanel`, `LinkedNote`, `ChangeLine`, `MenuBarCommandBar`). Erfundene Einträge unter `com.example`.
@MainActor
extension SnapshotGallery {
    enum MenuBarMenuScene: String, CaseIterable, Sendable {
        case quiet = "ruhig"
        case notices = "hinweise"
        case scanning = "scan"
        case notScanned = "kein-scan"
        case storeError = "fehler"
    }

    static func menuBarMenuSize(_ scene: MenuBarMenuScene) -> CGSize {
        let height: CGFloat = switch scene {
        case .quiet: 650
        case .notices: 830
        case .scanning: 700
        case .notScanned: 410
        case .storeError: 580
        }
        return CGSize(width: MenuBarMenuLayout.width, height: height)
    }

    static func menuBarMenu(_ scene: MenuBarMenuScene) -> some View {
        MenuBarMenuSample(scene: scene)
    }

    /// Fünf Änderungen wie im Entwurf, die ersten beiden ungelesen.
    static let menuBarChanges: [(symbol: String, title: String, detail: String, time: String, unread: Bool)] = [
        ("plus", "Neuer LaunchAgent", "com.example.updater startet bei jeder Anmeldung ein Skript.", "vor 5 Min.", true),
        ("plus", "Neue Berechtigung", "Bildschirmaufnahme für Bildschirmrekorder erlaubt.", "vor 1 Std.", true),
        ("pencil", "Agenten-Server geändert", "beispiel-dateien: neuer Befehl in der Konfiguration.", "gestern", false),
        ("minus", "Autostart entfernt", "com.example.scanner.agent ist nicht mehr eingerichtet.", "gestern", false),
        ("plus", "Neue App", "Notizblock 3.2 in /Applications.", "Mo.", false),
    ]
}

private struct MenuBarMenuSample: View {
    let scene: SnapshotGallery.MenuBarMenuScene

    var body: some View {
        MenuBarMenu {
            head
            if scene == .scanning {
                ProgressSpur(title: "Scan läuft", detail: "42 % · noch ca. 20 s", fraction: 0.42, tone: .info)
                    .instrumentPanel()
            }
            notices
            observation
            changes
        } commands: {
            MenuBarCommandBar(isScanning: scene == .scanning, hasReleaseHighlights: true, showMainWindow: {}, scan: {},
                              settings: {}, whatsNew: {}, quit: {})
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var head: some View {
        switch scene {
        case .quiet:
            VerdictBar(verdict: "Ruhig", reason: "Keine Befunde, nichts aus dem Netz erreichbar, alle Quellen gelesen.",
                       shield: .calm, items: [], facts: "Scan 14:32")
        case .notices:
            VerdictBar(verdict: "1 Punkt auffällig", reason: "Sicherheit: SIP aus.", shield: .finding, items: [],
                       facts: "Scan 14:32")
        case .scanning:
            VerdictBar(verdict: "Ruhig", reason: "Keine Befunde, nichts aus dem Netz erreichbar, alle Quellen gelesen.",
                       shield: .calm, items: [], facts: "Scan läuft")
        case .notScanned:
            VerdictBar(verdict: "Noch nicht geprüft",
                       reason: "Ein Scan liest Apps, Berechtigungen, Autostart und Agenten ein.", shield: .open,
                       items: [], facts: "kein Scan")
        case .storeError:
            VerdictBar(verdict: "Unvollständig geprüft",
                       reason: "Keine Befunde in dem, was gelesen wurde; ein Bereich ist nicht vollständig.",
                       shield: .open, items: [], facts: "Scan 14:32")
        }
    }

    @ViewBuilder
    private var notices: some View {
        switch scene {
        case .notices:
            SettingsPanel("Hinweise", detail: "3 offen", finding: true) {
                LinkedNote("Grantry 2026.11.14 ist verfügbar.", kind: .info) {
                    Button("Installieren und neu starten") {}
                    Button("Was ist neu?") {}
                }
                LinkedNote("Sicherheit: SIP kritisch", kind: .critical) {
                    Button("Sicherheit anzeigen …") {}
                }
                LinkedNote("Festplattenvollzugriff fehlt. Ohne ihn bleiben Teile des Systems ungeprüft.",
                           kind: .finding) {
                    Button("Festplattenvollzugriff öffnen …") {}
                    Button("Einrichtung öffnen …") {}
                }
            }
        case .storeError:
            SettingsPanel("Hinweise", detail: "2 offen", finding: true) {
                LinkedNote("Verlauf konnte nicht gespeichert werden: Die Datenbank ist schreibgeschützt.",
                           kind: .critical) {}
                LinkedNote("Autostart: unvollständig – Hintergrundobjekte nicht gelesen", kind: .finding) {}
            }
        case .quiet, .scanning, .notScanned:
            EmptyView()
        }
    }

    @ViewBuilder
    private var observation: some View {
        if scene == .scanning {
            SettingsPanel("Beobachtung", detail: "„Beispiel-Tool“ seit 12 Min. · 2 neue Einträge") {
                MenuBarLinks {
                    Button("Beobachtung beenden") {}
                    Button("Anzeigen …") {}
                }
            }
        } else {
            SettingsPanel("Beobachtung", detail: "keine läuft") {
                MenuBarLinks {
                    Button("Installation beobachten …") {}
                        .disabled(scene == .notScanned)
                }
            }
        }
    }

    @ViewBuilder
    private var changes: some View {
        switch scene {
        case .notScanned:
            SettingsPanel("Letzte Änderungen") { InstrumentNote("Noch kein Scan durchgeführt.") }
        case .storeError:
            SettingsPanel("Letzte Änderungen") {
                InstrumentNote("Keine Änderungen erkannt – nicht alle Quellen sind vollständig lesbar (siehe Hinweise).")
            }
        case .quiet, .notices, .scanning:
            SettingsPanel("Letzte Änderungen", detail: "5 neueste · 2 ungelesen") {
                ChangeLines {
                    ForEach(SnapshotGallery.menuBarChanges, id: \.title) { change in
                        ChangeLine(symbol: change.symbol, title: change.title, detail: change.detail,
                                   time: change.time, isUnread: change.unread)
                    }
                }
            }
        }
    }
}
