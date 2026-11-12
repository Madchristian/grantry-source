import GrantryCharts
import SwiftUI

/// Entwurf LB-2.1 (#538): Apps im Lagebild – gewählt mit Befund, akzeptiertes Risiko, Aktion läuft, Fehler beim
/// Speichern der Einschätzung, nichts gewählt, Leerzustände. Apps und Hersteller sind erfunden; App-Symbole stehen wie
/// in den Snapshot-Tests als Platzhalter.
struct AppsDraftBoard: View {
    var body: some View {
        AreaDraftPage(title: "Lagebild · Apps",
                      subtitle: "Entwurf LB-2.1: Zustandszeile, Auswahlliste mit Größe und letzter Nutzung, Detail mit "
                          + "eigener Einschätzung, Angaben und Sprüngen – feste Beispieldaten") {
            AreaDraftCaption(text: "1 · Gewählt mit Befund")
            Self.primary
            AreaDraftCaption(text: "2 · Aktion läuft (links) und Fehler beim Speichern der Einschätzung (rechts)")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                RemoteHelpDetail(runningText: "Wird in den Papierkorb gelegt …")
                RemoteHelpDetail(acceptanceError: true)
            }
            AreaDraftCaption(text: "3 · Nichts gewählt (links) und akzeptiertes Risiko (rechts)")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                AreaDraftScreen(verdict: AppSamples.verdict, coverage: .complete,
                            height: AreaDraftHeight.appsState) {
                    InstrumentList("Apps", count: "214", sections: AppSamples.sections, selection: .constant(nil))
                } detail: {
                    InstrumentEmptyState(symbol: "hand.raised", title: "Nichts gewählt", message: "Wähle links eine App, um Details und Aktionen zu sehen.").instrumentPanel()
                }
                AreaDraftScreen(verdict: AppSamples.verdict, coverage: .complete,
                            height: AreaDraftHeight.appsState) {
                    InstrumentList("Apps", count: "214", sections: AppSamples.sections, selection: .constant("capture"))
                } detail: {
                    AcceptedAppDetail()
                }
            }
            AreaDraftCaption(text: "4 · Noch kein Scan, Abdeckung unvollständig, keine Treffer")
            AreaDraftEmptyStates(
                area: "alle installierten Apps", itemsTitle: "Apps",
                partial: InventoryHead(verdict: "1 App auffällig", shield: .finding, items: [StatusItem("1 Ordner fehlt", tone: .finding)], facts: "2 Apps"),
                partialCoverage: CoverageSample(title: "Abdeckung unvollständig",
                                               detail: "Programme anderer Benutzer nicht gelesen", fraction: 2.0 / 3,
                                               tone: .finding, showsDetails: true),
                partialSections: [AppSamples.sections[0]],
                noMatches: InventoryHead(verdict: "2 Apps auffällig", shield: .finding, items: [], facts: "0 von 214 Apps passen")
            )
        }
    }
}

extension AppsDraftBoard {
    /// Hauptzustand des Bereichs, auch auf der Galerieseite „Alle Ansichten“ (LB-5.5, #556).
    @ViewBuilder static var primary: some View {
        AreaDraftScreen(verdict: AppSamples.verdict, coverage: .complete,
                        height: AreaDraftHeight.apps) {
            InstrumentList("Apps", count: "214", sections: AppSamples.sections, selection: .constant("remote"))
        } detail: {
            RemoteHelpDetail()
        }
    }
}

// MARK: - Beispieldaten

enum AppSamples {
    static let verdict = InventoryHead(verdict: "2 Apps auffällig", shield: .finding, items: [StatusItem("2 prüfen", tone: .finding), StatusItem("1 akzeptiert", tone: .neutral),
                StatusItem("3 neu seit 7 Tagen", tone: .neutral)], facts: "214 Apps · 38,2 GB · Scan 14:32")

    static let sections = [
        InstrumentListSection(id: "befund", title: "Mit Befund", finding: true, items: [
            .sample("remote", "display", "Fernhilfe", "Beispiel Software · 186 MB · heute benutzt",
                    badges: [SampleBadge.reviewHigh, SampleBadge.new], finding: true),
            .sample("recorder", "record.circle", "Bildschirmrekorder", "Beispiel GmbH · 92 MB · vor 3 Tagen",
                    badges: [SampleBadge.review, SampleBadge.new], finding: true),
        ]),
        InstrumentListSection(id: "uebrige", title: "Übrige", items: [
            .sample("capture", "camera.viewfinder", "Fotowerkzeug", "Beispiel Labs · 54 MB · gestern",
                    badges: [SampleBadge.accepted]),
            .sample("meeting", "video", "Videokonferenz", "App Store · 412 MB · vor 2 Tagen"),
            .sample("notes", "note.text", "Notizblock", "App Store · 38 MB · heute benutzt"),
            .sample("sync", "arrow.triangle.2.circlepath", "Ordner-Sync", "Beispiel AG · 120 MB · heute benutzt",
                    badges: [SampleBadge.new]),
            .sample("old", "questionmark.app.dashed", "Alter Scanner", "Beispiel GmbH · 64 MB · vor 14 Monaten",
                    badges: [SampleBadge.cleanup]),
        ]),
    ]
}

// MARK: - Details

/// App mit Befund aus dem zentralen `RecordDetailPanel` (seit LB-2.5, #542); `runningText` zeigt die laufende Aktion,
/// `acceptanceError` den Fehler beim Speichern der Einschätzung.
private struct RemoteHelpDetail: View {
    var runningText: String?
    var acceptanceError = false

    var body: some View {
        AppDetailSample(content: AppSamples.remoteHelp(runningText: runningText, acceptanceError: acceptanceError),
                       acceptanceTitle: "Risiko akzeptieren")
    }
}

/// App, deren Risiko akzeptiert ist: Warnungen ausgeblendet, Prüfhinweise bleiben ruhig sichtbar.
private struct AcceptedAppDetail: View {
    var body: some View {
        AppDetailSample(content: AppSamples.acceptedCapture, acceptanceTitle: "Akzeptanz aufheben")
    }
}

/// Detail mit den Knöpfen der App aus dem zentralen `RecordDetailPanel` (in der Galerie ohne Wirkung).
private struct AppDetailSample: View {
    let content: AppSamples.Detail
    let acceptanceTitle: String

    var body: some View {
        RecordDetailPanel(content: content.record) {
            InstrumentRowIcon(symbol: content.record.symbol, size: InstrumentSize.shield)
        } actions: {
            DetailActions(runningText: content.runningText) {
                Group {
                    Button("App entfernen …") {}
                    Button("Reste anzeigen") {}
                }
                .disabled(content.runningText != nil)
            }
        } accessory: { group in
            if group.id == "einschaetzung" {
                RiskAcceptanceControls(content.acceptance) { Button(acceptanceTitle) {} }
            } else if group.id == "ort" {
                Button("Im Finder zeigen") {}.controlSize(.small)
            } else {
                ForEach(content.links[group.id] ?? [], id: \.self) { row in
                    JumpRow(row, destination: group.title) {}
                }
            }
        }
    }
}

extension AppSamples {
    /// Detail einer Beispiel-App: Inhalt des Panels, laufende Aktion, eigene Einschätzung und Sprungzeilen je Gruppe.
    struct Detail {
        let record: RecordDetailContent
        var runningText: String?
        let acceptance: RiskAcceptanceContent
        var links: [String: [InstrumentRowContent]] = [:]
    }

    static let trustNote = "Wenn du diese App kennst und ihr vertraust, kannst du ihre App-Warnungen ausblenden. "
        + "Die Prüfergebnisse bleiben einsehbar."

    static func remoteHelp(runningText: String?, acceptanceError: Bool) -> Detail {
        Detail(
            record: RecordDetailContent(
                symbol: "display", title: "Fernhilfe", subtitle: "com.example.remotehelp",
                items: [StatusItem("kritisch", tone: .critical), StatusItem("neu", tone: .neutral)], finding: true,
                groups: [
                    DetailGroupContent(id: "hinweise", title: "Hinweise", count: 2, notes: [
                        DetailNoteContent("Nicht notarisiert und darf andere Apps steuern.", kind: .critical),
                        DetailNoteContent("Startet bei jeder Anmeldung einen Hintergrunddienst.", kind: .finding),
                    ]),
                    DetailGroupContent(id: "einschaetzung", title: "Eigene Einschätzung"),
                    DetailGroupContent(id: "angaben", title: "Angaben", facts: [
                        DetailFactContent("Version", value: "3.2 (412)"),
                        DetailFactContent("Signatur", value: "Developer ID · Beispiel Software (Q1W2E3R4T5)",
                                          tone: .positive),
                        DetailFactContent("Notarisiert", value: "nein", tone: .critical),
                        DetailFactContent("Größe", value: "186 MB"),
                        DetailFactContent("Zuletzt benutzt", value: "heute, 09:12"),
                    ]),
                    DetailGroupContent(id: "ort", title: "Ort", facts: [
                        DetailFactContent("Pfad", value: "/Applications/Fernhilfe.app", isCode: true),
                    ]),
                    DetailGroupContent(id: "berechtigungen", title: "Berechtigungen", count: 2),
                    DetailGroupContent(id: "autostart", title: "Autostart", count: 1),
                ]
            ),
            runningText: runningText,
            acceptance: RiskAcceptanceContent(
                isAccepted: false, explanation: trustNote,
                error: acceptanceError ? "Entscheidung nicht gespeichert: Die Datei ist schreibgeschützt." : nil),
            links: [
                "berechtigungen": [
                    InstrumentRowContent(symbol: "accessibility", title: "Bedienungshilfen", detail: "Benutzer",
                                         badges: [SampleBadge.review], status: StatusItem("erlaubt", tone: .positive),
                                         finding: true),
                    InstrumentRowContent(symbol: "rectangle.dashed.badge.record", title: "Bildschirmaufnahme",
                                         detail: "Benutzer", status: StatusItem("erlaubt", tone: .positive)),
                ],
                "autostart": [
                    InstrumentRowContent(symbol: "gearshape.2", title: "com.example.remotehelp.daemon",
                                         detail: "LaunchDaemon", badges: [SampleBadge.review],
                                         status: StatusItem("aktiv", tone: .positive), finding: true),
                ],
            ]
        )
    }

    static let acceptedCapture = Detail(
        record: RecordDetailContent(
            symbol: "camera.viewfinder", title: "Fotowerkzeug", subtitle: "com.example.capture",
            items: [StatusItem("akzeptiert", tone: .neutral)],
            groups: [
                DetailGroupContent(id: "einschaetzung", title: "Eigene Einschätzung"),
                DetailGroupContent(id: "akzeptiert", title: "Akzeptierte Prüfhinweise", count: 1,
                                   notes: [DetailNoteContent("Darf den Bildschirm aufnehmen.", kind: .info)]),
                DetailGroupContent(id: "angaben", title: "Angaben", facts: [
                    DetailFactContent("Signatur", value: "Developer ID · Beispiel Labs (Z9X8C7V6B5)", tone: .positive),
                    DetailFactContent("Größe", value: "54 MB"),
                ]),
                DetailGroupContent(id: "ort", title: "Ort", facts: [
                    DetailFactContent("Pfad", value: "/Applications/Fotowerkzeug.app", isCode: true),
                ]),
            ]
        ),
        acceptance: RiskAcceptanceContent(
            isAccepted: true,
            explanation: "Du vertraust dieser App. Ihre App-Warnungen sind ausgeblendet. Bei einem Wechsel des "
                + "Entwicklerteams wird erneut gewarnt.")
    )
}

#Preview("LB-2.1 Apps") {
    ScrollView { DesignGallery(page: .appsDraft) }
}
