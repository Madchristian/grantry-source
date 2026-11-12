import SwiftUI
@testable import GrantryCharts

/// Einstellungen im Lagebild (LB-5.2, #553) mit festen Beispieldaten wie im abgenommenen Entwurf LB-5.1 (#552):
/// Gruppen als `SettingsPanel`, Einstellungen als `SettingToggle` bzw. `SettingRow`, Einrichtung als `CheckRows`.
/// Schalter zeichnet `SettingToggle` hier selbst (`chartDrawsSwitches`): Der fensterlose `NSSwitch` verschob die Zeilen je
/// nach Bildschirm-Skalierung (CI-Runner mit 1×-Bildschirm). Die nativen zeigt die Galerie (offscreen).
@MainActor
extension SnapshotGallery {
    enum SettingsScene: String, CaseIterable, Sendable {
        /// Alles eingerichtet, Grantry aktuell, Wachbuch an.
        case complete = "eingerichtet"
        /// Einrichtung offen (wichtigste Zeile aufgeklappt), Wachbuch aus.
        case missing = "offen"
        /// Helper wartet auf Genehmigung mit Fehler, Update verfügbar.
        case failed = "fehler"
        /// Zustand wird gelesen, Update-Prüfung läuft.
        case checking = "pruefung"
    }

    static let settingsSize = CGSize(width: 560, height: 1320)

    static func settings(_ scene: SettingsScene) -> some View {
        SettingsSample(scene: scene)
    }

    /// Einrichtung mit den Texten von `SetupStep` und `SetupChecklist` (gekürzt auf den Grund in einem Satz).
    static func setupItems(_ scene: SettingsScene) -> [CheckItem] {
        let states: [StatusItem] = switch scene {
        case .complete: [ok("Erteilt"), ok("Bereit"), ok("Erlaubt"), ok("Aktiv")]
        case .missing:
            [StatusItem("Nicht erteilt", tone: .critical), StatusItem("Nicht installiert", tone: .critical),
             StatusItem("Noch nicht erlaubt", tone: .finding), StatusItem("Aus", tone: .neutral)]
        case .failed: [ok("Erteilt"), StatusItem("Wartet auf Genehmigung", tone: .finding), ok("Erlaubt"), ok("Aktiv")]
        case .checking: Array(repeating: StatusItem("Wird geprüft …", tone: .neutral), count: 4)
        }
        return [
            CheckItem(id: "setup.fullDiskAccess", symbol: "lock.shield", title: "Festplattenvollzugriff",
                      reason: "Nötig, um die systemweiten Berechtigungen zu lesen.", status: states[0],
                      explanation: "Nach dem Erteilen erkennt Grantry ihn von selbst."),
            CheckItem(id: "setup.helper", symbol: "wrench.and.screwdriver", title: "Helper",
                      reason: "Liest die Hintergrundobjekte des Systems und führt Aktionen mit Administratorrechten aus.",
                      status: states[1],
                      explanation: "Er nimmt nur Verbindungen von Administratoren an; die Genehmigung erfordert ein "
                          + "Administratorkonto.",
                      details: scene == .failed ? ["Wartet auf Genehmigung unter „Anmeldeobjekte & Erweiterungen“"] : []),
            CheckItem(id: "setup.notifications", symbol: "bell", title: "Benachrichtigungen",
                      reason: "Meldet neue, geänderte und entfernte Einträge, auch wenn das Fenster geschlossen ist.",
                      status: states[2]),
            CheckItem(id: "setup.launchAtLogin", symbol: "power", title: "Beim Anmelden starten",
                      reason: "Startet Grantry beim Anmelden, damit keine Änderung unbemerkt bleibt.", status: states[3]),
        ]
    }

    private static func ok(_ text: String) -> StatusItem { StatusItem(text, tone: .positive) }
}

/// Tab „Allgemein“ in der Reihenfolge der App: Darstellung, Einrichtung, Updates, Netzwerk, Wachbuch, Prozesse, Lizenzen.
private struct SettingsSample: View {
    let scene: SnapshotGallery.SettingsScene

    var body: some View {
        VStack(spacing: InstrumentSpacing.panel) {
            SettingsPanel("Darstellung", detail: "Dock und Menüleiste") {
                SettingToggle("Dock-Symbol anzeigen",
                              note: "Grantry bleibt über die Menüleiste erreichbar, auch ohne Dock-Symbol.",
                              isOn: .constant(true))
            }
            SetupSample(scene: scene)
            UpdatesSample(scene: scene)
            SettingsPanel("Netzwerk", detail: "Mitteilungen zu Diensten") {
                SettingRow("Neue Netzwerkdienste melden",
                           note: "Dienste von macOS und beendete Dienste werden nie gemeldet; der Verlauf enthält alle "
                               + "Änderungen.") {
                    Picker("Neue Netzwerkdienste melden", selection: .constant(0)) {
                        Text(verbatim: "Nur von außen erreichbare").tag(0)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            SettingsPanel("Wachbuch", detail: watchbookOn ? "Aufzeichnung an · 7 Tage" : "Aufzeichnung aus") {
                SettingToggle("Wachbuch führen",
                              note: "Zeichnet alle 10 Sekunden Auslastung, größte Verbraucher, Befunde und "
                                  + "Systemereignisse auf, auch ohne offenes Fenster.",
                              isOn: .constant(watchbookOn))
                SettingToggle("Bei schweren Befunden benachrichtigen",
                              note: watchbookOn ? "Höchstens eine Mitteilung je Art und Stunde."
                                  : "Nur wirksam, solange das Wachbuch geführt wird.",
                              isOn: .constant(true))
                    .disabled(!watchbookOn)
            }
            SettingsPanel("Lizenzen", detail: "Komponenten anderer Anbieter") {
                SettingRow("Drittanbieter-Lizenzen",
                           note: "Lizenztexte der Komponenten anderer Anbieter, die Grantry enthält.",
                           labelsControl: false) {
                    Button("Lizenzen anzeigen …") {}.controlSize(.small)
                }
            }
        }
        .padding(InstrumentSpacing.page)
        .frame(width: SnapshotGallery.settingsSize.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .instrumentBackground()
    }

    private var watchbookOn: Bool { scene != .missing }
}

private struct SetupSample: View {
    let scene: SnapshotGallery.SettingsScene

    var body: some View {
        let items = SnapshotGallery.setupItems(scene)
        let (detail, value): (String, String) = switch scene {
        case .complete: ("4 von 4 erledigt", "")
        case .missing: ("0 von 4 erledigt · 2 kritisch", "4 offen")
        case .failed: ("3 von 4 erledigt", "1 offen")
        case .checking: ("Zustand wird gelesen …", "")
        }
        let expanded: String? = switch scene {
        case .missing: "setup.fullDiskAccess"
        case .failed: "setup.helper"
        case .complete, .checking: nil
        }
        SettingsPanel("Einrichtung", detail: detail, value: value, finding: !value.isEmpty) {
            Button("Erneut prüfen") {}.disabled(scene == .checking)
        } content: {
            CheckRows(items: items, selection: .constant(expanded)) { item in
                DetailActions {
                    if item.id == "setup.fullDiskAccess" { Button("Einstellungen öffnen") {} }
                    if item.id == "setup.helper" { Button("Genehmigen") {} }
                }
            }
            if scene == .failed {
                InstrumentNote("Helper konnte nicht installiert werden: Die Genehmigung wurde abgelehnt.",
                               kind: .critical)
            }
        }
    }
}

private struct UpdatesSample: View {
    let scene: SnapshotGallery.SettingsScene

    var body: some View {
        let detail = switch scene {
        case .checking: "Prüfung läuft"
        case .failed: "Grantry 2026.11.14 verfügbar"
        case .complete, .missing: "täglich · Grantry 2026.11.11"
        }
        SettingsPanel("Updates", detail: detail, finding: scene == .failed) {
            SettingToggle("Täglich nach Updates suchen", isOn: .constant(true))
            SettingToggle("Updates automatisch installieren",
                          note: "Lädt Updates im Hintergrund und installiert sie beim nächsten Beenden. "
                              + "Standardmäßig ausgeschaltet.",
                          isOn: .constant(false))
            InstrumentNote("Grantry fragt einmal täglich nach einer neuen Version.")
            switch scene {
            case .failed:
                InstrumentNote("Grantry 2026.11.14 ist verfügbar.", kind: .finding)
            case .complete, .missing:
                InstrumentNote("Grantry ist aktuell (2026.11.11).")
            case .checking:
                EmptyView()
            }
            SettingActionLine(scene == .checking ? "Noch nicht geprüft" : "Zuletzt geprüft: heute, 09:12",
                              runningText: scene == .checking ? "Wird geprüft …" : nil) {
                Button("Jetzt prüfen") {}.disabled(scene == .checking)
            }
        }
    }
}
