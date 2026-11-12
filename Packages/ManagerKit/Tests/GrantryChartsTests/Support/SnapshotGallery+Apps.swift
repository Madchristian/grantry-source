import SwiftUI
@testable import GrantryCharts

/// Bereich Apps (LB-2.5, #542) mit festen Beispieldaten wie im abgenommenen Entwurf LB-2.1 (#538): erfundene Apps unter
/// `com.example`, keine Benutzernamen, Hostnamen oder echten Pfade.
@MainActor
extension SnapshotGallery {
    enum AppsScene: String, CaseIterable, Sendable {
        case selected = "gewaehlt"
        case nothingSelected = "nichts-gewaehlt"
        case accepted = "akzeptiert"
        case bySize = "nach-groesse"
        case notScanned = "kein-scan"
        case incomplete = "unvollstaendig"
    }

    static let appsSize = CGSize(width: 1180, height: 820)

    static func apps(_ scene: AppsScene) -> some View {
        AppsSample(scene: scene)
    }

    static let appsHead = InventoryHead(
        verdict: "2 Apps auffällig", finding: true,
        items: [StatusItem("2 prüfen", tone: .finding), StatusItem("3 neu seit 7 Tagen", tone: .neutral),
                StatusItem("1 akzeptiert", tone: .neutral)],
        facts: "214 Apps · Scan 14:32"
    )

    static let acceptedBadge = InstrumentBadge("akzeptiert", tone: .neutral, spoken: "Risiko akzeptiert")

    private static func app(_ id: String, _ symbol: String, _ title: String, _ detail: String,
                            badges: [InstrumentBadge] = [], finding: Bool = false) -> InstrumentListItem<String> {
        InstrumentListItem(id: id, content: InstrumentRowContent(symbol: symbol, title: title, detail: detail,
                                                                 badges: badges, finding: finding))
    }

    static let flaggedApps = [
        app("remote", "display", "Fernhilfe", "Beispiel Software · 186 MB · heute benutzt", badges: [reviewHigh, new],
            finding: true),
        app("recorder", "record.circle", "Bildschirmrekorder", "Beispiel GmbH · 92 MB · vor 3 Tagen",
            badges: [review, new], finding: true),
    ]

    static let otherApps = [
        app("capture", "camera.viewfinder", "Fotowerkzeug", "Beispiel Labs · 54 MB · gestern", badges: [acceptedBadge]),
        app("meeting", "video", "Videokonferenz", "App Store · 412 MB · vor 2 Tagen"),
        app("notes", "note.text", "Notizblock", "App Store · 38 MB · heute benutzt"),
        app("sync", "arrow.triangle.2.circlepath", "Ordner-Sync", "Beispiel AG · 120 MB · heute benutzt", badges: [new]),
        app("old", "questionmark.app.dashed", "Alter Scanner", "Beispiel GmbH · 64 MB · vor 14 Monaten",
            badges: [cleanup]),
    ]

    static let appSections = [
        InstrumentListSection(id: "befund", title: "Mit Befund", finding: true, items: flaggedApps),
        InstrumentListSection(id: "uebrige", title: "Übrige", items: otherApps),
    ]

    /// Sortierung nach Größe: eine Gruppe in der gewählten Reihenfolge (Spec §11.2 b).
    static let appsBySize = [
        InstrumentListSection(id: "alle", title: "Alle Apps",
                              items: [otherApps[1], flaggedApps[0], otherApps[3], flaggedApps[1], otherApps[4],
                                      otherApps[0], otherApps[2]]),
    ]

    /// Detail einer Beispiel-App: Inhalt des Panels, laufende Aktion, eigene Einschätzung und Sprungzeilen je Gruppe.
    struct AppDetailSample {
        let record: RecordDetailContent
        var runningText: String?
        let acceptance: RiskAcceptanceContent
        var links: [String: [InstrumentRowContent]] = [:]
    }

    static let trustNote = "Wenn du diese App kennst und ihr vertraust, kannst du ihre App-Warnungen ausblenden. "
        + "Die Prüfergebnisse bleiben einsehbar."

    static let remoteHelpDetail = AppDetailSample(
        record: RecordDetailContent(
            symbol: "display", title: "Fernhilfe", subtitle: "com.example.remotehelp",
            items: [StatusItem("prüfen", tone: .critical), StatusItem("neu", tone: .neutral)], finding: true,
            groups: [
                DetailGroupContent(id: "hinweise", title: "Hinweise", count: 2, notes: [
                    DetailNoteContent("Nicht notarisiert und darf andere Apps steuern.", kind: .critical),
                    DetailNoteContent("Startet bei jeder Anmeldung einen Hintergrunddienst.", kind: .finding),
                ]),
                DetailGroupContent(id: "einschaetzung", title: "Eigene Einschätzung"),
                DetailGroupContent(id: "angaben", title: "Angaben", facts: [
                    DetailFactContent("Version", value: "3.2 (412)"),
                    DetailFactContent("Signatur", value: "Developer ID", tone: .positive),
                    DetailFactContent("Team", value: "Q1W2E3R4T5"),
                    DetailFactContent("Notarisierung", value: "Nicht notarisiert"),
                    DetailFactContent("Größe", value: "186 MB"),
                    DetailFactContent("Zuletzt benutzt", value: "heute"),
                ], notes: [DetailNoteContent("Signatur nicht geprüft seit 3 Tagen", kind: .info)]),
                DetailGroupContent(id: "ort", title: "Ort", facts: [
                    DetailFactContent("Pfad", value: "/Applications/Fernhilfe.app", isCode: true),
                ]),
                DetailGroupContent(id: "berechtigungen", title: "Berechtigungen", count: 2),
                DetailGroupContent(id: "autostart", title: "Autostart", count: 1),
            ]
        ),
        runningText: "Wird entfernt …",
        acceptance: RiskAcceptanceContent(isAccepted: false, explanation: trustNote),
        links: [
            "berechtigungen": [
                InstrumentRowContent(symbol: "accessibility", title: "Bedienungshilfen", detail: "Benutzer",
                                     badges: [review], status: allowed, finding: true),
                InstrumentRowContent(symbol: "rectangle.dashed.badge.record", title: "Bildschirmaufnahme",
                                     detail: "Benutzer", status: allowed),
            ],
            "autostart": [
                InstrumentRowContent(symbol: "gearshape.2", title: "com.example.remotehelp.daemon",
                                     detail: "LaunchDaemon", badges: [review],
                                     status: StatusItem("aktiv", tone: .positive), finding: true),
            ],
        ]
    )

    static let acceptedCaptureDetail = AppDetailSample(
        record: RecordDetailContent(
            symbol: "camera.viewfinder", title: "Fotowerkzeug", subtitle: "com.example.capture",
            items: [StatusItem("akzeptiert", tone: .neutral)],
            groups: [
                DetailGroupContent(id: "einschaetzung", title: "Eigene Einschätzung"),
                DetailGroupContent(id: "akzeptiert", title: "Akzeptierte Prüfhinweise", count: 1,
                                   notes: [DetailNoteContent("Darf den Bildschirm aufnehmen.", kind: .info)]),
                DetailGroupContent(id: "angaben", title: "Angaben", facts: [
                    DetailFactContent("Signatur", value: "Developer ID", tone: .positive),
                    DetailFactContent("Größe", value: "54 MB"),
                ]),
                DetailGroupContent(id: "ort", title: "Ort", facts: [
                    DetailFactContent("Pfad", value: "/Applications/Fotowerkzeug.app", isCode: true),
                ]),
                DetailGroupContent(id: "erweiterungen", title: "Erweiterungen", count: 1),
            ]
        ),
        acceptance: RiskAcceptanceContent(
            isAccepted: true,
            explanation: "Du vertraust dieser App. Ihre App-Warnungen sind ausgeblendet. Bei einem Wechsel des "
                + "Entwicklerteams wird erneut gewarnt.",
            error: "Entscheidung nicht gespeichert: Die Datei ist schreibgeschützt."),
        links: [
            "erweiterungen": [
                InstrumentRowContent(symbol: "square.and.arrow.up", title: "Fotowerkzeug teilen",
                                     detail: "Teilen · aktiv"),
            ],
        ]
    )
}

/// Detail einer Beispiel-App im `RecordDetailPanel`: eigene Einschätzung und Sprungzeilen über `accessory`, wie in der
/// App. `showsRunning` zeigt die laufende Aktion (`ImageRenderer` zeichnet `ProgressView` nur als Platzhalter).
struct AppDetailSampleView: View {
    let sample: SnapshotGallery.AppDetailSample
    var showsRunning = false

    var body: some View {
        RecordDetailPanel(content: sample.record) {
            InstrumentRowIcon(symbol: sample.record.symbol, size: InstrumentSize.shield)
        } actions: {
            DetailActions(runningText: showsRunning ? sample.runningText : nil) { EmptyView() }
        } accessory: { group in
            if group.id == "einschaetzung" {
                RiskAcceptanceControls(sample.acceptance) { EmptyView() }
            } else {
                ForEach(sample.links[group.id] ?? [], id: \.self) { row in
                    JumpRow(row, destination: group.title) {}
                }
            }
        }
    }
}

private struct AppsSample: View {
    let scene: SnapshotGallery.AppsScene

    private static let nothingSelected = "Wähle links eine App, um Details und Aktionen zu sehen."

    var body: some View {
        switch scene {
        case .selected:
            board(selection: "remote") { AppDetailSampleView(sample: SnapshotGallery.remoteHelpDetail) }
        case .nothingSelected:
            board(selection: nil) { nothing }
        case .accepted:
            board(selection: "capture") { AppDetailSampleView(sample: SnapshotGallery.acceptedCaptureDetail) }
        case .bySize:
            InventoryBoard(head: SnapshotGallery.appsHead) {
                complete
            } list: {
                InstrumentList("Apps", count: "7", sections: SnapshotGallery.appsBySize, selection: .constant(nil))
            } detail: {
                nothing
            }
        case .notScanned:
            InventoryBoard(head: InventoryHead(verdict: "Noch nicht geprüft", finding: false, items: [],
                                               facts: "kein Scan seit dem Start")) {
                ProgressSpur(title: "Abdeckung unbekannt", detail: "noch nichts gelesen", fraction: 0, tone: .neutral)
            } list: {
                InstrumentEmptyState(symbol: "clock", title: "Noch kein Scan",
                                     message: "Der erste Scan liest alle installierten Apps ein.")
                    .instrumentPanel()
            } detail: {
                nothing
            }
        case .incomplete:
            InventoryBoard(head: InventoryHead(verdict: "2 Apps auffällig", finding: true,
                                               items: [StatusItem("1 Quelle fehlt", tone: .finding),
                                                       StatusItem("2 prüfen", tone: .finding)],
                                               facts: "2 Apps · Scan 14:32")) {
                ProgressSpur(title: "Abdeckung unvollständig", detail: "Programme anderer Benutzer nicht gelesen",
                             fraction: 2.0 / 3, tone: .finding)
            } list: {
                InstrumentList("Apps", count: "2", sections: [SnapshotGallery.appSections[0]],
                               selection: .constant(nil))
            } detail: {
                nothing
            }
        }
    }

    private var nothing: some View {
        InstrumentEmptyState(symbol: "hand.raised", title: "Nichts gewählt", message: Self.nothingSelected)
            .instrumentPanel()
    }

    private var complete: ProgressSpur<EmptyView> {
        ProgressSpur(title: "Abdeckung vollständig", detail: "alle Quellen gelesen · 14:32", fraction: 1,
                     tone: .positive)
    }

    private func board(selection: String?, @ViewBuilder detail: () -> some View) -> some View {
        InventoryBoard(head: SnapshotGallery.appsHead) {
            complete
        } list: {
            InstrumentList("Apps", count: "7", sections: SnapshotGallery.appSections, selection: .constant(selection))
        } detail: {
            detail()
        }
    }
}
