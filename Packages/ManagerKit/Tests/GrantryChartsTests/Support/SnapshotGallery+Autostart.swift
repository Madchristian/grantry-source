import SwiftUI
@testable import GrantryCharts

/// Bereich Autostart (LB-2.3, #540) mit festen Beispieldaten wie im abgenommenen Entwurf LB-2.1 (#538): erfundene
/// Einträge unter `com.example`, keine Benutzernamen, Hostnamen oder echten Pfade.
@MainActor
extension SnapshotGallery {
    enum AutostartScene: String, CaseIterable, Sendable {
        case selected = "gewaehlt"
        case nothingSelected = "nichts-gewaehlt"
        case readOnly = "schreibgeschuetzt"
        case notScanned = "kein-scan"
        case incomplete = "unvollstaendig"
        case noMatches = "keine-treffer"
    }

    static let autostartSize = CGSize(width: 1180, height: 680)

    static func autostart(_ scene: AutostartScene) -> some View {
        AutostartSample(scene: scene)
    }

    static let autostartHead = InventoryHead(
        verdict: "2 Einträge auffällig", finding: true,
        items: [StatusItem("2 prüfen", tone: .finding), StatusItem("1 neu seit 7 Tagen", tone: .neutral),
                StatusItem("2 deaktiviert", tone: .neutral)],
        facts: "9 Einträge · Scan 14:32"
    )

    static let autostartActive = StatusItem("aktiv", tone: .positive)
    static let autostartDisabled = StatusItem("deaktiviert", tone: .neutral)

    private static func entry(_ id: String, _ symbol: String, _ title: String, _ detail: String,
                              badges: [InstrumentBadge] = [], status: StatusItem, finding: Bool = false)
        -> InstrumentListItem<String> {
        InstrumentListItem(id: id, content: InstrumentRowContent(symbol: symbol, title: title, detail: detail,
                                                                 badges: badges, status: status, finding: finding))
    }

    static let autostartSections = [
        InstrumentListSection(id: "login", title: "Anmeldeobjekte", items: [
            entry("notes", "note.text", "Notizblock", "Notizblock", status: autostartActive),
            entry("meeting", "video", "Videokonferenz", "Videokonferenz", status: autostartDisabled),
        ]),
        InstrumentListSection(id: "agents", title: "LaunchAgents", finding: true, items: [
            entry("updater", "gearshape", "com.example.updater", "~/Library/Application Support/Updater/run.sh",
                  badges: [review, new], status: autostartActive, finding: true),
            entry("sync", "gearshape", "com.example.foldersync.helper", "Ordner-Sync", status: autostartActive),
            entry("old", "gearshape", "com.example.scanner.agent", "/usr/local/bin/scanner", badges: [cleanup],
                  status: autostartDisabled),
        ]),
        InstrumentListSection(id: "daemons", title: "LaunchDaemons", finding: true, items: [
            entry("vpn", "gearshape.2", "com.example.vpn.daemon", "Beispiel-VPN",
                  badges: [InstrumentBadge("prüfen", tone: .critical, spoken: "prüfen, hoher Schweregrad")],
                  status: autostartActive, finding: true),
            entry("backup", "gearshape.2", "com.example.backup.daemon", "Sicherung", status: autostartActive),
        ]),
    ]

    static let updaterDetail = RecordDetailContent(
        symbol: "gearshape", title: "com.example.updater", subtitle: "LaunchAgent · Benutzer",
        items: [StatusItem("prüfen", tone: .finding), StatusItem("neu", tone: .neutral), autostartActive],
        finding: true,
        groups: [
            DetailGroupContent(id: "hinweise", title: "Hinweise", count: 1, notes: [
                DetailNoteContent("Startet ein Skript aus dem Benutzerordner bei jeder Anmeldung.", kind: .finding),
            ]),
            DetailGroupContent(id: "programm", title: "Programm", facts: [
                DetailFactContent("Programm", value: "~/Library/Application Support/Updater/run.sh", isCode: true),
                DetailFactContent("Signatur", value: "nicht signiert", tone: .finding),
                DetailFactContent("Befehl", value: "/bin/sh run.sh --quiet --token ****", isCode: true),
            ]),
            DetailGroupContent(id: "ort", title: "Ort", facts: [
                DetailFactContent("Plist", value: "~/Library/LaunchAgents/com.example.updater.plist", isCode: true),
                DetailFactContent("Gleiches Label auch in",
                                  value: "~/Library/LaunchAgents/com.example.updater.alt.plist", isCode: true),
                DetailFactContent("Session-Typen", value: "Aqua"),
            ], notes: [
                DetailNoteContent("launchd führt je Label nur einen Dienst; Aktivieren/Deaktivieren ist dann gesperrt.",
                                  kind: .info),
            ]),
        ]
    )

    static let notesDetail = RecordDetailContent(
        symbol: "note.text", title: "Notizblock", subtitle: "Anmeldeobjekt · Benutzer", items: [autostartActive],
        groups: [
            DetailGroupContent(id: "programm", title: "Programm", facts: [
                DetailFactContent("Besitzer-App", value: "Notizblock (com.example.notes)"),
                DetailFactContent("Programm", value: "/Applications/Notizblock.app", isCode: true),
                DetailFactContent("Signatur", value: "App Store · Team A1B2C3D4E5", tone: .positive),
            ]),
        ]
    )

    static let notesLockedReason = "Von macOS verwaltet – ändern lässt er sich nur in den Anmeldeobjekten."
}

private struct AutostartSample: View {
    let scene: SnapshotGallery.AutostartScene

    var body: some View {
        switch scene {
        case .selected:
            board(selection: "updater") { RecordDetailPanel(content: SnapshotGallery.updaterDetail) }
        case .nothingSelected:
            board(selection: nil) { nothingSelected }
        case .readOnly:
            board(selection: "notes") {
                RecordDetailPanel(content: SnapshotGallery.notesDetail) {
                    InstrumentRowIcon(symbol: "note.text", size: InstrumentSize.shield)
                } actions: {
                    InstrumentNote(SnapshotGallery.notesLockedReason, kind: .locked)
                } accessory: { _ in
                    EmptyView()
                }
            }
        case .notScanned:
            InventoryBoard(head: InventoryHead(verdict: "Noch nicht geprüft", shield: .open, items: [],
                                               facts: "kein Scan seit dem Start")) {
                ProgressSpur(title: "Abdeckung unbekannt", detail: "noch nichts gelesen", fraction: 0, tone: .neutral)
            } list: {
                InstrumentEmptyState(symbol: "clock", title: "Noch kein Scan",
                                     message: "Der erste Scan liest alle Autostart-Einträge ein.")
                    .instrumentPanel()
            } detail: {
                nothingSelected
            }
        case .incomplete:
            InventoryBoard(head: InventoryHead(verdict: "Nicht vollständig geprüft", finding: true,
                                               items: [StatusItem("1 Quelle fehlt", tone: .finding),
                                                       StatusItem("1 deaktiviert", tone: .neutral)],
                                               facts: "2 Einträge · Scan 14:32")) {
                ProgressSpur(title: "Abdeckung unvollständig", detail: "Hintergrundobjekte nicht gelesen",
                             fraction: 3.0 / 4, tone: .finding)
            } list: {
                InstrumentList("Einträge", count: "2", sections: [SnapshotGallery.autostartSections[0]],
                               selection: .constant(nil))
            } detail: {
                nothingSelected
            }
        case .noMatches:
            InventoryBoard(head: SnapshotGallery.autostartHead) {
                complete
            } list: {
                InstrumentEmptyState(symbol: "magnifyingglass", title: "Keine Treffer",
                                     message: "Nichts passt zu Suche und Filter.")
                    .instrumentPanel()
            } detail: {
                nothingSelected
            }
        }
    }

    private var nothingSelected: some View {
        InstrumentEmptyState(symbol: "hand.raised", title: "Nichts gewählt",
                             message: "Wähle links einen Autostart-Eintrag, um Details und Aktionen zu sehen.")
            .instrumentPanel()
    }

    private var complete: ProgressSpur<EmptyView> {
        ProgressSpur(title: "Abdeckung vollständig", detail: "alle Quellen gelesen · 14:32", fraction: 1,
                     tone: .positive)
    }

    private func board(selection: String?, @ViewBuilder detail: () -> some View) -> some View {
        InventoryBoard(head: SnapshotGallery.autostartHead) {
            complete
        } list: {
            InstrumentList("Einträge", count: "7", sections: SnapshotGallery.autostartSections,
                           selection: .constant(selection))
        } detail: {
            detail()
        }
    }
}
