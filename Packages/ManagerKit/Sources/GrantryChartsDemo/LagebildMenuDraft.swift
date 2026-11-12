import GrantryCharts
import SwiftUI

/// Entwurf LB-5.1 (#552): Menüleisten-Menü (`MenuBarContent`, Breite 380, Spec § 11 Entscheidung 7) – Kopf mit Schild
/// und Urteil wie die Übersicht, Hinweise als Hinweiszeilen, Beobachtung, letzte Änderungen, Befehle als Aktionsleiste.
/// Seit LB-5.4 (#555) aus den zentralen Bausteinen (`MenuBarMenu.swift`) mit den Urteilen von `DashboardVerdict`.
struct MenuDraftBoard: View {
    var body: some View {
        AreaDraftPage(title: "Lagebild · Menüleisten-Menü",
                      subtitle: "Entwurf LB-5.1: Lagezeile mit Schild, Hinweise, Beobachtung, letzte Änderungen, "
                          + "Befehle – feste Beispieldaten") {
            AreaDraftCaption(text: "1 · Ruhig, mit Hinweisen, Scan und Beobachtung laufen")
            Self.primary
            AreaDraftCaption(text: "2 · Noch kein Scan, Fehler der Datenbank mit unvollständiger Abdeckung")
            GalleryRow {
                MenuWindow(state: .notScanned)
                MenuWindow(state: .storeError)
            }
        }
    }
}

extension MenuDraftBoard {
    /// Hauptzustand des Bereichs, auch auf der Galerieseite „Alle Ansichten“ (LB-5.5, #556).
    @ViewBuilder static var primary: some View {
        GalleryRow {
            MenuWindow(state: .quiet)
            MenuWindow(state: .notices)
            MenuWindow(state: .scanning)
        }
    }
}

private enum MenuState {
    case quiet, notices, scanning, notScanned, storeError
}

private struct MenuWindow: View {
    let state: MenuState

    var body: some View {
        GalleryWindow(name: "Menüleisten-Menü", width: MenuBarMenuLayout.width) {
            head
            if state == .scanning {
                ProgressSpur(title: "Scan läuft", detail: "42 % · noch ca. 20 s", fraction: 0.42, tone: .info)
                    .instrumentPanel()
            }
            notices
            observation
            changes
        } bar: {
            MenuBarCommandBar(isScanning: state == .scanning, hasReleaseHighlights: true, showMainWindow: {}, scan: {},
                              settings: {}, whatsNew: {}, quit: {})
        }
    }

    /// Urteil wie die Übersicht (`DashboardVerdict`, Entscheidung 7), ohne Chips und mit knappen Kenndaten.
    @ViewBuilder
    private var head: some View {
        switch state {
        case .quiet, .scanning:
            VerdictBar(verdict: "Ruhig", reason: "Keine Befunde, nichts aus dem Netz erreichbar, alle Quellen gelesen.",
                       shield: .calm, items: [], facts: state == .scanning ? "Scan läuft" : "Scan 14:32")
        case .notices:
            VerdictBar(verdict: "1 Punkt auffällig", reason: "Sicherheit: SIP aus.", shield: .finding, items: [],
                       facts: "Scan 14:32")
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
        switch state {
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
        if state == .scanning {
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
                        .disabled(state == .notScanned)
                        .help("Hält den aktuellen Stand fest und zeigt später, was ein Tool eingerichtet hat.")
                }
            }
        }
    }

    @ViewBuilder
    private var changes: some View {
        switch state {
        case .notScanned:
            SettingsPanel("Letzte Änderungen") {
                InstrumentNote("Noch kein Scan durchgeführt.")
            }
        case .storeError:
            SettingsPanel("Letzte Änderungen") {
                InstrumentNote("Keine Änderungen erkannt – nicht alle Quellen sind vollständig lesbar (siehe Hinweise).")
            }
        case .quiet, .notices, .scanning:
            SettingsPanel("Letzte Änderungen", detail: "5 neueste · 2 ungelesen") {
                ChangeLines {
                    ForEach(MenuSamples.changes) { change in
                        ChangeLine(symbol: change.symbol, title: change.title, detail: change.detail, time: change.time,
                                   isUnread: change.isUnread)
                    }
                }
            }
        }
    }
}

private enum MenuSamples {
    struct Change: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let detail: String
        let time: String
        var isUnread = false
    }

    static let changes = [
        Change(id: "1", symbol: "plus", title: "Neuer LaunchAgent", detail: "com.example.updater startet bei "
            + "jeder Anmeldung ein Skript.", time: "vor 5 Min.", isUnread: true),
        Change(id: "2", symbol: "plus", title: "Neue Berechtigung",
               detail: "Bildschirmaufnahme für Bildschirmrekorder erlaubt.", time: "vor 1 Std.", isUnread: true),
        Change(id: "3", symbol: "pencil", title: "Agenten-Server geändert",
               detail: "beispiel-dateien: neuer Befehl in der Konfiguration.", time: "gestern"),
        Change(id: "4", symbol: "minus", title: "Autostart entfernt",
               detail: "com.example.scanner.agent ist nicht mehr eingerichtet.", time: "gestern"),
        Change(id: "5", symbol: "plus", title: "Neue App", detail: "Notizblock 3.2 in /Applications.",
               time: "Mo."),
    ]
}

#Preview("LB-5.1 Menüleisten-Menü") {
    ScrollView { DesignGallery(page: .menuDraft) }
}
