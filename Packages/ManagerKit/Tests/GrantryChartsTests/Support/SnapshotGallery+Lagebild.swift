import SwiftUI
@testable import GrantryCharts

/// Zentrale Bausteine der Liste-Detail-Ansichten (LB-1.2, #536) mit festen Beispieldaten wie im abgenommenen Entwurf
/// LB-1.1 (#535): erfundene Apps unter `com.example`, keine Benutzernamen, Hostnamen oder echten Pfade. Vier Lagen:
/// Liste mit Befund und gewählter Zeile samt Detail und laufender Aktion, nichts gewählt, Banner und Hinweise,
/// Häkchenzeilen mit Abdeckung und Scan-Fortschritt.
@MainActor
extension SnapshotGallery {
    enum LagebildScene: String, CaseIterable, Sendable {
        case listDetail = "liste-detail"
        case nothingSelected = "nichts-gewaehlt"
        case notes = "hinweise"
        case selection = "auswahl"
    }

    static let lagebildSize = CGSize(width: 1180, height: 760)

    static let lagebildSections = [
        InstrumentListSection(id: "befund", title: "Mit Befund", finding: true, items: [
            InstrumentListItem(id: "recorder", content: recorder),
            InstrumentListItem(id: "sync", content: InstrumentRowContent(
                symbol: "arrow.triangle.2.circlepath", title: "Ordner-Sync", detail: "Festplattenvollzugriff",
                badges: [review], finding: true)),
        ]),
        InstrumentListSection(id: "uebrige", title: "Übrige", items: [
            InstrumentListItem(id: "meeting", content: InstrumentRowContent(
                symbol: "video", title: "Videokonferenz", detail: "Kamera, Mikrofon, Bildschirmaufnahme")),
            InstrumentListItem(id: "notes", content: InstrumentRowContent(
                symbol: "note.text", title: "Notizblock", detail: "Erinnerungen, Kalender")),
            InstrumentListItem(id: "terminal", content: InstrumentRowContent(
                symbol: "terminal", title: "Terminal", detail: "Festplattenvollzugriff", badges: [new])),
            InstrumentListItem(id: "old", content: InstrumentRowContent(
                symbol: "questionmark.app.dashed", title: "Alter Scanner",
                detail: "Kamera · App nicht mehr vorhanden", badges: [cleanup])),
        ]),
    ]

    static let review = InstrumentBadge("prüfen", tone: .finding, spoken: "prüfen, mittlerer Schweregrad")
    static let new = InstrumentBadge("neu", tone: .neutral)
    static let cleanup = InstrumentBadge("aufräumen", tone: .neutral)
    static let recorder = InstrumentRowContent(symbol: "record.circle", title: "Bildschirmrekorder",
                                               detail: "Bildschirmaufnahme, Mikrofon, Bedienungshilfen",
                                               badges: [review, new], finding: true)

    static func lagebild(_ scene: LagebildScene) -> some View {
        LagebildSample(scene: scene)
    }
}

private struct LagebildSample: View {
    let scene: SnapshotGallery.LagebildScene

    var body: some View {
        Group {
            switch scene {
            case .listDetail: screen(selection: "recorder") { LagebildAppDetail() }
            case .nothingSelected:
                screen(selection: nil) {
                    InstrumentEmptyState(symbol: "hand.raised", title: "Nichts gewählt",
                                         message: "Wähle links eine App.")
                        .instrumentPanel()
                }
            case .notes: LagebildNotes()
            case .selection: LagebildChecks()
            }
        }
        .padding(InstrumentSpacing.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .instrumentBackground()
    }

    private func screen(selection: String?, @ViewBuilder detail: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            StatusLine(verdict: "2 Apps auffällig", finding: true,
                       items: [StatusItem("2 prüfen", tone: .finding), StatusItem("2 neu seit 7 Tagen", tone: .neutral)],
                       facts: "6 Apps · 12 Berechtigungen · Scan 14:32")
            ProgressSpur(title: "Abdeckung vollständig", detail: "alle 3 Quellen gelesen · 14:32", fraction: 1,
                         tone: .positive)
                .instrumentPanel()
            InstrumentSplit {
                InstrumentList("Apps", count: "6", sections: SnapshotGallery.lagebildSections,
                               selection: .constant(selection))
            } detail: {
                detail()
            }
        }
    }
}

/// Detail einer App: Kopf, Befund-Hinweis, Angaben als Schlüssel-Wert-Zeilen, Berechtigungen als Einträge auf der Mulde.
struct LagebildAppDetail: View {
    var body: some View {
        DetailPanel {
            DetailHead(symbol: "record.circle", title: "Bildschirmrekorder", subtitle: "com.example.recorder",
                       items: [StatusItem("prüfen", tone: .finding), StatusItem("neu", tone: .neutral)], finding: true)
            InstrumentNote("Darf den Bildschirm aufnehmen und den Mac fernsteuern – seit 3 Tagen installiert.",
                           kind: .finding)
            DetailGroup("Angaben") {
                DetailEntry("Signatur", value: "Developer ID · Beispiel GmbH (A1B2C3D4E5)", tone: .positive)
                DetailEntry("Pfad", value: "/Applications/Bildschirmrekorder.app", isCode: true)
                DetailEntry("Auf dem Mac", value: "vorhanden")
            }
            DetailGroup("Berechtigungen", count: 3) {
                DetailItem(InstrumentRowContent(symbol: "rectangle.dashed.badge.record", title: "Bildschirmaufnahme",
                                                detail: "Benutzer · geändert am 8. Nov. 2026",
                                                status: StatusItem("erlaubt", tone: .positive))) {
                    EmptyView()
                } actions: {
                    Button("Zurücksetzen …") {}
                }
                DetailItem(InstrumentRowContent(symbol: "accessibility", title: "Bedienungshilfen",
                                                detail: "Benutzer · geändert am 8. Nov. 2026",
                                                badges: [SnapshotGallery.review],
                                                status: StatusItem("erlaubt", tone: .positive), finding: true),
                           runningText: "Wird zurückgesetzt …") {
                    InstrumentNote("Steuert andere Apps – nur erlauben, wenn du die App dafür brauchst.",
                                   kind: .finding)
                } actions: {
                    Button("Zurücksetzen …") {}.disabled(true)
                }
                DetailItem(InstrumentRowContent(symbol: "mic", title: "Mikrofon",
                                                detail: "System · geändert am 2. Nov. 2026",
                                                status: StatusItem("abgelehnt", tone: .neutral))) {
                    InstrumentNote("Systemweiter Eintrag – Zurücksetzen nur mit Helper.", kind: .locked)
                } actions: {
                    EmptyView()
                }
            }
        }
    }
}

private struct LagebildNotes: View {
    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            InstrumentBanner("Festplattenvollzugriff fehlt",
                             message: "Ohne ihn bleiben Berechtigungen anderer Benutzer und einige Ordner ungeprüft.",
                             tone: .finding)
            InstrumentBanner("Update verfügbar: 2026.11.12",
                             message: "Prüfsumme und Signatur sind bestätigt; die Installation startet Grantry neu.",
                             tone: .info)
            InstrumentBanner("3 Einträge in den Papierkorb gelegt",
                             message: "1,4 GB frei. Im Papierkorb lässt sich alles wiederherstellen.", tone: .positive)
            InstrumentBanner("Zurücksetzen fehlgeschlagen",
                             message: "Der Helper hat nicht geantwortet. Es wurde nichts geändert.", tone: .critical)
            VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
                InstrumentNote("Einträge aus dem Systemordner zeigt Grantry nur an; ändern lassen sie sich mit dem Helper.")
                InstrumentNote("Schreibgeschützt: Eintrag eines Profils (MDM).", kind: .locked)
                InstrumentNote("Lädt bei jedem Start ein Skript aus dem Benutzerordner nach.", kind: .finding)
                InstrumentNote("Die Datei ist beschädigt und ließ sich nicht lesen.", kind: .critical)
                BadgeChips([InstrumentBadge("prüfen", tone: .critical), SnapshotGallery.review, SnapshotGallery.new,
                            SnapshotGallery.cleanup])
            }
            .instrumentPanel()
        }
    }
}

private struct LagebildChecks: View {
    var body: some View {
        HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                    InstrumentSectionHeader(title: "Reste von Alter Scanner", count: 3)
                    SelectionCheckRow("Einstellungen", detail: "~/Library/Preferences/com.example.scanner.plist",
                                      size: "12 KB", isOn: .constant(true))
                    SelectionCheckRow("Caches", detail: "~/Library/Caches/com.example.scanner", size: "1,4 GB",
                                      isOn: .constant(true), hint: StatusItem("groß", tone: .finding))
                    SelectionCheckRow("Programmunterstützung", detail: "~/Library/Application Support/Scanner",
                                      size: "86 MB", isOn: .constant(false),
                                      hint: StatusItem("enthält Dokumente", tone: .info))
                    SelectionCheckRow("Hintergrunddienst", detail: "/Library/LaunchDaemons/com.example.scanner.plist",
                                      size: "4 KB", isOn: .constant(false),
                                      lockedReason: "Systemordner – nur mit Helper")
                }
                .padding(InstrumentSpacing.item)
                HStack(spacing: InstrumentSpacing.group) {
                    Text(verbatim: "2 von 3 gewählt · 1,4 GB").font(InstrumentFont.numeric)
                    Spacer(minLength: InstrumentSpacing.group)
                }
                .instrumentBar()
            }
            .clipShape(RoundedRectangle(cornerRadius: InstrumentRadius.panel, style: .continuous))
            .instrumentPanel(padding: 0)
            VStack(alignment: .leading, spacing: InstrumentSpacing.bar) {
                ProgressSpur(title: "Abdeckung unvollständig", detail: "2 von 3 Quellen gelesen · 14:32",
                             fraction: 2.0 / 3, tone: .finding)
                ProgressSpur(title: "Scan läuft", detail: "Berechtigungen · 142 von 340 Einträgen",
                             fraction: 0.42, tone: .info)
                ProgressSpur(title: "Erster Scan", detail: "Dauer noch unbekannt", fraction: nil, tone: .info)
                ProgressSpur(title: "Noch nicht geprüft", detail: "kein Scan seit dem Start", fraction: 0,
                             tone: .neutral)
            }
            .instrumentPanel()
        }
    }
}
