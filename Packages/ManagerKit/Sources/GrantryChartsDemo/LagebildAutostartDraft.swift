import GrantryCharts
import SwiftUI

/// Entwurf LB-2.1 (#538): Autostart im Lagebild – Einträge je Art, gewählt mit Befund, Aktion läuft, Fehler, nichts
/// gewählt, schreibgeschützter Eintrag, Leerzustände.
struct AutostartDraftBoard: View {
    var body: some View {
        AreaDraftPage(title: "Lagebild · Autostart",
                      subtitle: "Entwurf LB-2.1: Zustandszeile, Einträge je Art mit Zustand, Detail mit Aktionen, "
                          + "Start und Ort – feste Beispieldaten") {
            AreaDraftCaption(text: "1 · Gewählt mit Befund")
            Self.primary
            AreaDraftCaption(text: "2 · Aktion läuft (links) und Fehler einer Aktion (rechts)")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                UpdaterDetail(runningText: "Wird deaktiviert …")
                VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
                    InstrumentBanner("Entfernen fehlgeschlagen", message: "Die Datei hat sich seit dem Scan geändert. Es wurde nichts entfernt.", tone: .critical) { BannerDismissButton {} }
                    UpdaterDetail()
                }
            }
            AreaDraftCaption(text: "3 · Nichts gewählt (links) und schreibgeschützter Eintrag (rechts)")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                AreaDraftScreen(verdict: AutostartSamples.verdict, coverage: .complete,
                            height: AreaDraftHeight.autostart) {
                    InstrumentList("Einträge", count: "9", sections: AutostartSamples.sections, selection: .constant(nil))
                } detail: {
                    InstrumentEmptyState(symbol: "hand.raised", title: "Nichts gewählt", message: "Wähle links einen Eintrag, um Details und Aktionen zu sehen.").instrumentPanel()
                }
                AreaDraftScreen(verdict: AutostartSamples.verdict, coverage: .complete,
                            height: AreaDraftHeight.autostart) {
                    InstrumentList("Einträge", count: "9", sections: AutostartSamples.sections, selection: .constant("notes"))
                } detail: {
                    LoginItemDetail()
                }
            }
            AreaDraftCaption(text: "4 · Noch kein Scan, Abdeckung unvollständig, keine Treffer")
            AreaDraftEmptyStates(
                area: "alle Autostart-Einträge", itemsTitle: "Einträge",
                partial: InventoryHead(verdict: "Ruhig", shield: .calm, items: [StatusItem("1 Quelle fehlt", tone: .finding)], facts: "2 Einträge"),
                partialCoverage: CoverageSample(title: "Abdeckung unvollständig",
                                               detail: "Hintergrundobjekte nicht gelesen", fraction: 3.0 / 4,
                                               tone: .finding, showsDetails: true),
                partialSections: [AutostartSamples.sections[0]],
                noMatches: InventoryHead(verdict: "2 Einträge auffällig", shield: .finding, items: [], facts: "0 von 9 passen")
            )
        }
    }
}

extension AutostartDraftBoard {
    /// Hauptzustand des Bereichs, auch auf der Galerieseite „Alle Ansichten“ (LB-5.5, #556).
    @ViewBuilder static var primary: some View {
        AreaDraftScreen(verdict: AutostartSamples.verdict, coverage: .complete,
                        height: AreaDraftHeight.autostart) {
            InstrumentList("Einträge", count: "9", sections: AutostartSamples.sections, selection: .constant("updater"))
        } detail: {
            UpdaterDetail()
        }
    }
}

// MARK: - Beispieldaten

private enum AutostartSamples {
    static let verdict = InventoryHead(verdict: "2 Einträge auffällig", shield: .finding, items: [StatusItem("2 prüfen", tone: .finding), StatusItem("1 neu seit 7 Tagen", tone: .neutral),
                StatusItem("2 deaktiviert", tone: .neutral)], facts: "9 Einträge · Scan 14:32")

    static let active = StatusItem("aktiv", tone: .positive)
    static let disabled = StatusItem("deaktiviert", tone: .neutral)

    static let sections = [
        InstrumentListSection(id: "login", title: "Anmeldeobjekte", items: [
            .sample("notes", "note.text", "Notizblock", "Beim Anmelden öffnen", status: active),
            .sample("meeting", "video", "Videokonferenz", "Beim Anmelden öffnen", status: disabled),
        ]),
        InstrumentListSection(id: "agents", title: "LaunchAgents", finding: true, items: [
            .sample("updater", "gearshape", "com.example.updater", "~/Library/Application Support/Updater/run.sh",
                    badges: [SampleBadge.review, SampleBadge.new], status: active, finding: true),
            .sample("sync", "gearshape", "com.example.foldersync.helper", "Ordner-Sync", status: active),
            .sample("old", "gearshape", "com.example.scanner.agent", "Programm fehlt", badges: [SampleBadge.cleanup],
                    status: disabled),
        ]),
        InstrumentListSection(id: "daemons", title: "LaunchDaemons", finding: true, items: [
            .sample("vpn", "gearshape.2", "com.example.vpn.daemon", "Beispiel-VPN", badges: [SampleBadge.reviewHigh],
                    status: active, finding: true),
            .sample("backup", "gearshape.2", "com.example.backup.daemon", "Sicherung", status: active),
        ]),
        InstrumentListSection(id: "background", title: "Hintergrundobjekte", items: [
            .sample("recorder", "square.stack.3d.down.right", "Bildschirmrekorder", "Hilfsprogramm der App",
                    status: active),
            .sample("terminal", "square.stack.3d.down.right", "Terminal-Hilfe", "Hilfsprogramm der App",
                    status: active),
        ]),
    ]
}

// MARK: - Details

/// LaunchAgent mit Befund aus dem zentralen `RecordDetailPanel` (seit LB-2.3, #540); `runningText` zeigt die laufende
/// Aktion.
private struct UpdaterDetail: View {
    var runningText: String?

    var body: some View {
        RecordDetailPanel(content: AutostartSamples.updater) {
            InstrumentRowIcon(symbol: AutostartSamples.updater.symbol, size: InstrumentSize.shield)
        } actions: {
            DetailActions(runningText: runningText) {
                Button("Deaktivieren") {}
                Button("Entfernen …", role: .destructive) {}
            }
            .disabled(runningText != nil)
        } accessory: { _ in
            EmptyView()
        }
    }
}

/// Anmeldeobjekt, das macOS verwaltet: keine Aktionen, Grund vor dem Sprung in die Systemeinstellungen.
private struct LoginItemDetail: View {
    var body: some View {
        RecordDetailPanel(content: AutostartSamples.loginItem) {
            InstrumentRowIcon(symbol: AutostartSamples.loginItem.symbol, size: InstrumentSize.shield)
        } actions: {
            InstrumentNote("Von macOS verwaltet – ändern lässt er sich nur in den Anmeldeobjekten.", kind: .locked)
            DetailActions {
                Button("In Anmeldeobjekten öffnen") {}
            }
        } accessory: { _ in
            EmptyView()
        }
    }
}

extension AutostartSamples {
    static let updater = RecordDetailContent(
        symbol: "gearshape", title: "com.example.updater", subtitle: "LaunchAgent · Benutzer",
        items: [StatusItem("prüfen", tone: .finding), active], finding: true,
        groups: [
            DetailGroupContent(id: "hinweise", title: "Hinweise", count: 2, notes: [
                DetailNoteContent("Startet ein Skript aus dem Benutzerordner bei jeder Anmeldung.", kind: .finding),
                DetailNoteContent("Neu seit dem 9. Nov. 2026.", kind: .info),
            ]),
            DetailGroupContent(id: "programm", title: "Programm", facts: [
                DetailFactContent("Besitzer-App", value: "unbekannt"),
                DetailFactContent("Programm", value: "~/Library/Application Support/Updater/run.sh", isCode: true),
                DetailFactContent("Signatur", value: "nicht signiert", tone: .finding),
                DetailFactContent("Befehl", value: "/bin/sh run.sh --quiet", isCode: true),
            ]),
            DetailGroupContent(id: "ort", title: "Ort", facts: [
                DetailFactContent("Plist", value: "~/Library/LaunchAgents/com.example.updater.plist", isCode: true),
                DetailFactContent("Session-Typen", value: "Aqua"),
            ]),
        ]
    )

    static let loginItem = RecordDetailContent(
        symbol: "note.text", title: "Notizblock", subtitle: "Anmeldeobjekt · Benutzer", items: [active],
        groups: [
            DetailGroupContent(id: "programm", title: "Programm", facts: [
                DetailFactContent("Besitzer-App", value: "Notizblock (com.example.notes)"),
                DetailFactContent("Programm", value: "/Applications/Notizblock.app", isCode: true),
                DetailFactContent("Signatur", value: "App Store", tone: .positive),
            ]),
        ]
    )
}

#Preview("LB-2.1 Autostart") {
    ScrollView { DesignGallery(page: .autostartDraft) }
}
