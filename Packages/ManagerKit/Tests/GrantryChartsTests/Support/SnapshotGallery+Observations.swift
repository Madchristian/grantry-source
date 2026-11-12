import SwiftUI
@testable import GrantryCharts

/// Bereich Beobachtungen (LB-3.4, #546) mit festen Beispieldaten wie im abgenommenen Entwurf LB-3.1 (#543): erfundene
/// Werkzeuge unter `com.example`, keine Benutzernamen, Hostnamen oder echten Pfade.
@MainActor
extension SnapshotGallery {
    /// Tragende Zustände des Entwurfs; die übrigen (wird beendet, nicht lesbar, nichts gewählt, Liste nicht lesbar,
    /// Blatt bereit bzw. läuft schon) zeigt die Galerie offscreen. Wenige Lagen halten die CI unter ihrer Zeitgrenze.
    enum ObservationsScene: String, CaseIterable, Sendable {
        case finished = "beendet"
        case running = "laeuft"
        case quiet = "keine-aenderungen"
        case empty = "keine"
        case sheetStarting = "blatt-erfasst"

        var size: CGSize {
            switch self {
            case .finished: CGSize(width: 1180, height: 1500)
            case .sheetStarting: CGSize(width: 480, height: 400)
            default: CGSize(width: 1180, height: 820)
            }
        }
    }

    static func observations(_ scene: ObservationsScene) -> some View {
        ObservationsSample(scene: scene)
    }

    static let observationsHead = InventoryHead(verdict: "1 Beobachtung läuft", shield: .open,
                                                items: [StatusItem("4 neue Einträge", tone: .info)],
                                                facts: "4 Beobachtungen")

    static let observationSections = [
        InstrumentListSection(id: "laeuft", title: "Läuft", tone: .info, items: [
            observation("tool", "Beispiel-Werkzeug", "11. Nov. 2026, 14:20 · 4 neue Einträge",
                        status: StatusItem("läuft", tone: .info)),
        ]),
        InstrumentListSection(id: "gespeichert", title: "Gespeichert", items: [
            observation("editor", "Beispiel-Editor", "10. Nov. 2026, 10:12 · 5 neue Einträge"),
            observation("printer", "Druckertreiber", "8. Nov. 2026, 16:02 · keine neuen Einträge"),
            observation("sync", "Sync-Werkzeug", "2. Nov. 2026, 09:30 · 3 neue Einträge · aufgeräumt"),
        ]),
    ]

    private static func observation(_ id: String, _ title: String, _ detail: String,
                                    status: StatusItem? = nil) -> InstrumentListItem<String> {
        InstrumentListItem(id: id, content: InstrumentRowContent(symbol: "binoculars", title: title, detail: detail,
                                                                 status: status))
    }
}

/// Beispiel-Detail einer Beobachtung im `ObservationDetailPanel`, wie es die App füllt.
struct ObservationDetailSampleView: View {
    enum Sample { case finished, running, finishing, quiet }

    let sample: Sample
    var runningText: String?

    private static let likely = InstrumentBadge("wahrscheinlich zugehörig", tone: .neutral)
    private static let unsure = InstrumentBadge("Zuordnung unsicher", tone: .finding)
    private static let new = StatusItem("neu", tone: .info)

    private static func row(_ id: String, _ symbol: String, _ title: String, _ detail: String,
                            badges: [InstrumentBadge] = [likely], status: StatusItem = new, finding: Bool = false,
                            destination: String) -> ObservationEntryRow {
        ObservationEntryRow(id: id, content: InstrumentRowContent(symbol: symbol, title: title, detail: detail,
                                                                  badges: badges, status: status, finding: finding),
                            destination: destination)
    }

    static let newRows = [
        row("app", "plus", "Beispiel-Editor", "App · /Applications", destination: "Apps"),
        row("agent", "plus", "com.example.editor.helper", "LaunchAgent · Beispiel-Editor", destination: "Autostart"),
        row("grant", "plus", "Bildschirmaufnahme", "Berechtigung · Fernhilfe · erlaubt", badges: [unsure],
            finding: true, destination: "Berechtigungen"),
    ]

    static let finishedGroups = [
        ObservationEntryGroup(id: "apps", title: "Neue Apps", rows: [newRows[0]]),
        ObservationEntryGroup(id: "autostart", title: "Neue Autostart-Einträge", rows: [newRows[1]]),
        ObservationEntryGroup(id: "grants", title: "Neue Berechtigungen", rows: [newRows[2]]),
        ObservationEntryGroup(id: "modified", title: "Geänderte Einträge",
                              note: DetailNoteContent("Geänderte Einträge setzt Grantry nicht automatisch zurück – über "
                                  + "den Eintrag zur passenden Aktion wechseln.", kind: .info),
                              rows: [row("server", "pencil", "Beispiel-Server", "MCP-Server · Befehl geändert",
                                         badges: [], status: StatusItem("geändert", tone: .neutral),
                                         destination: "Agenten")]),
    ]

    var content: ObservationDetailContent {
        switch sample {
        case .finished:
            ObservationDetailContent(
                title: "Beispiel-Editor", subtitle: "10. Nov. 2026, 10:12 – 10:31 (19 Min.)",
                status: StatusItem("beendet", tone: .neutral), finding: true,
                facts: [DetailFactContent("Notiz", value: "Test vor dem Kauf")],
                notes: [DetailNoteContent("Eingeschränkt beim Start oder Ende – die Bilanz ist dort unvollständig: "
                            + "Agenten: Konfiguration nicht lesbar", kind: .finding),
                        DetailNoteContent("Kamera, Mikrofon, Automation und andere Berechtigungen des Benutzerbereichs "
                            + "liest Grantry nicht – sie fehlen in der Bilanz.", kind: .info)],
                balance: ObservationBalanceContent(new: 3, modified: 1, removed: 0,
                                                   summary: "3 neu, 1 geändert, 0 entfernt – Bilanz unvollständig"),
                groups: Self.finishedGroups,
                records: [ObservationRecordContent(id: "1", facts: [
                    DetailFactContent("10. Nov. 2026, 10:40", value: "2 von 3 erledigt"),
                    DetailFactContent("Beispiel-Editor.app", value: "erledigt", tone: .positive),
                    DetailFactContent("com.example.editor.helper", value: "erledigt", tone: .positive),
                    DetailFactContent("Bildschirmaufnahme", value: "nicht zurückgesetzt: Eintrag hat sich geändert",
                                      tone: .critical),
                ])]
            )
        case .running, .finishing:
            ObservationDetailContent(
                title: "Beispiel-Werkzeug", subtitle: "Seit 11. Nov. 2026, 14:20",
                status: StatusItem("läuft", tone: .info),
                groups: [ObservationEntryGroup(id: "new", title: "Neue Apps", rows: [Self.newRows[0]]),
                         ObservationEntryGroup(id: "autostart", title: "Neue Autostart-Einträge",
                                               rows: [Self.newRows[1]])]
            )
        case .quiet:
            ObservationDetailContent(
                title: "Druckertreiber", subtitle: "8. Nov. 2026, 16:02 – 16:09 (7 Min.)",
                status: StatusItem("beendet", tone: .neutral),
                balance: ObservationBalanceContent(
                    new: 0, modified: 0, removed: 0, summary: "Keine Änderungen während der Beobachtung.",
                    note: DetailNoteContent("Während der Beobachtung ist nichts hinzugekommen, verändert oder "
                        + "verschwunden.", kind: .info))
            )
        }
    }

    static let cleanup = ObservationCleanupContent(
        rows: [
            ObservationCleanupRow(id: "app", title: "Beispiel-Editor.app",
                                  detail: "App · /Applications/Beispiel-Editor.app — Name passt zur Beobachtung",
                                  size: "412 MB", offersLeftovers: true),
            ObservationCleanupRow(id: "agent", title: "com.example.editor.helper",
                                  detail: "LaunchAgent · Beispiel-Editor — gehört zu einer neuen App", size: "–"),
            ObservationCleanupRow(id: "grant", title: "Bildschirmaufnahme",
                                  detail: "Berechtigung · Fernhilfe · erlaubt — anderer Hersteller", size: "–",
                                  hint: StatusItem("Zuordnung unsicher", tone: .finding),
                                  help: "Nicht sicher dem beobachteten Tool zugeordnet."),
        ],
        notes: [DetailNoteContent("1 neuer Eintrag ist nicht mehr (oder nicht mehr unverändert) vorhanden.", kind: .info)],
        footnote: "Angeboten wird, was von den neuen Einträgen heute noch existiert. Vorausgewählt ist nur, was "
            + "wahrscheinlich zum Tool gehört; geänderte Einträge setzt Grantry nicht zurück.",
        offersAction: true, canRemove: true, canRemoveWithLeftovers: true
    )

    var body: some View {
        ObservationDetailPanel(content: content) { _ in
        } actions: {
            DetailActions(runningText: sample == .finishing ? "Wird beendet …" : nil) { EmptyView() }
        } progress: {
            if sample == .finishing {
                ProgressSpur(title: "Abschluss-Scan", detail: "57 %", fraction: 4.0 / 7, tone: .info)
            } else if sample == .running {
                InstrumentNote("Installiere und starte jetzt das Tool. Neue Einträge erscheinen hier nach jedem Scan.",
                               kind: .info)
            }
        } rowAccessory: { _ in
            EmptyView()
        } cleanup: {
            if sample == .finished {
                ObservationCleanupGroup(
                    content: Self.cleanup.running(runningText),
                    isSelected: { .constant($0 != "grant") }, removeWithLeftovers: { _ in }, remove: {}
                )
            }
        }
    }
}

/// Blatt „Installation beobachten“ mit Beispielzustand.
struct ObservationStartSampleView: View {
    enum State { case ready, starting, blocked }

    let state: State

    var body: some View {
        ObservationStartForm(
            name: .constant(state == .blocked ? "" : "Beispiel-Werkzeug"), note: .constant(""),
            notes: state == .blocked
                ? [DetailNoteContent("Die Beobachtung „Beispiel-Werkzeug“ läuft bereits – es kann nur eine "
                    + "gleichzeitig laufen.", kind: .finding)] : [],
            isBusy: state == .starting, canStart: state == .ready, cancel: {}, start: {}
        ) {
            if state == .starting {
                ProgressSpur(title: "Ausgangsstand wird erfasst …", detail: "29 %", fraction: 2.0 / 7, tone: .info)
            }
        }
        .instrumentBackground()
    }
}

private struct ObservationsSample: View {
    let scene: SnapshotGallery.ObservationsScene

    var body: some View {
        switch scene {
        case .finished: board(selection: "editor") { ObservationDetailSampleView(sample: .finished) }
        case .running: board(selection: "tool") { ObservationDetailSampleView(sample: .running) }
        case .quiet: board(selection: "printer") { ObservationDetailSampleView(sample: .quiet) }
        case .empty:
            ObservationsEmptyBoard(head: InventoryHead(verdict: "Keine Beobachtung", shield: .open, items: [],
                                                       facts: "0 gespeichert"),
                                   message: "Starte eine Beobachtung, bevor du ein Tool installierst – danach zeigt "
                                       + "Grantry, was es eingerichtet hat.") { EmptyView() }
        case .sheetStarting: ObservationStartSampleView(state: .starting)
        }
    }

    private func board(selection: String?, @ViewBuilder detail: () -> some View) -> some View {
        InventoryBoard(head: SnapshotGallery.observationsHead) {
            EmptyView()
        } list: {
            InstrumentList("Beobachtungen", count: "4", sections: SnapshotGallery.observationSections,
                           selection: .constant(selection))
        } detail: {
            detail()
        }
    }
}
