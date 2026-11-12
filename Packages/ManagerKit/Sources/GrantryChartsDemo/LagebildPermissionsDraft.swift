import GrantryCharts
import SwiftUI

/// Entwurf LB-2.1 (#538): Berechtigungen im Lagebild – nach App und nach Berechtigung, gewählt mit Befund, Aktion läuft,
/// Fehler, nichts gewählt, Leerzustände. Beispieldaten wie in LB-1.1, damit das Vorher-Bild passt.
struct PermissionsDraftBoard: View {
    var body: some View {
        AreaDraftPage(title: "Lagebild · Berechtigungen",
                      subtitle: "Entwurf LB-2.1: Zustandszeile, Auswahlliste nach App oder Berechtigung, Detail mit "
                          + "Aktionen je Berechtigung – feste Beispieldaten") {
            AreaDraftCaption(text: "1 · Nach App, gewählt mit Befund")
            Self.primary
            AreaDraftCaption(text: "2 · Aktion läuft (links) und Fehler einer Aktion (rechts)")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                PermissionColumn { RecorderDetail(isResetting: true) }
                PermissionColumn {
                    InstrumentBanner("Zurücksetzen fehlgeschlagen", message: "Der Helper hat nicht geantwortet. Es wurde nichts geändert.", tone: .critical) { BannerDismissButton {} }
                } content: {
                    SyncDetail()
                }
            }
            AreaDraftCaption(text: "3 · Nichts gewählt (links) und nach Berechtigung (rechts)")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                AreaDraftScreen(verdict: PermissionSamples.verdict, segments: PermissionSamples.segments(.app),
                                coverage: .complete,
                            height: AreaDraftHeight.permissionsState) {
                    InstrumentList("Apps", count: "6", sections: PermissionSamples.apps, selection: .constant(nil))
                } detail: {
                    InstrumentEmptyState(symbol: "hand.raised", title: "Nichts gewählt", message: "Wähle links eine App, um ihre Berechtigungen zu sehen.").instrumentPanel()
                }
                AreaDraftScreen(verdict: PermissionSamples.verdict, segments: PermissionSamples.segments(.service),
                                coverage: .complete,
                            height: AreaDraftHeight.permissionsState) {
                    InstrumentList("Berechtigungen", count: "7", sections: PermissionSamples.services, selection: .constant("camera"))
                } detail: {
                    PermissionColumn { CameraDetail() }
                }
            }
            AreaDraftCaption(text: "4 · Noch kein Scan, Abdeckung unvollständig, keine Treffer")
            AreaDraftEmptyStates(
                area: "die Berechtigungen aller Apps", itemsTitle: "Apps",
                partial: InventoryHead(verdict: "1 App auffällig", shield: .finding, items: [StatusItem("1 Quelle fehlt", tone: .finding)], facts: "2 Apps · 4 Berechtigungen"),
                partialCoverage: CoverageSample(title: "Abdeckung unvollständig",
                                               detail: "Systemdatenbank ohne Helper nicht gelesen",
                                               fraction: 2.0 / 3, tone: .finding, showsDetails: true),
                partialSections: [PermissionSamples.apps[0]],
                noMatches: InventoryHead(verdict: "2 Apps auffällig", shield: .finding, items: [], facts: "0 von 6 Apps passen")
            )
        }
    }
}

extension PermissionsDraftBoard {
    /// Hauptzustand des Bereichs, auch auf der Galerieseite „Alle Ansichten“ (LB-5.5, #556).
    @ViewBuilder static var primary: some View {
        AreaDraftScreen(verdict: PermissionSamples.verdict, segments: PermissionSamples.segments(.app),
                        coverage: .complete,
                        height: AreaDraftHeight.permissions) {
            InstrumentList("Apps", count: "6", sections: PermissionSamples.apps, selection: .constant("recorder"))
        } detail: {
            PermissionColumn { RecorderDetail() }
        }
    }
}

// MARK: - Beispieldaten

private enum PermissionSamples {
    enum Grouping: String {
        case app, service
    }

    static let verdict = InventoryHead(verdict: "2 Apps auffällig", shield: .finding, items: [StatusItem("2 prüfen", tone: .finding), StatusItem("2 neu seit 7 Tagen", tone: .neutral)], facts: "6 Apps · 12 Berechtigungen · Scan 14:32")

    static func segments(_ grouping: Grouping) -> SegmentsSample {
        SegmentsSample(label: "Gruppierung", options: [("app", "Nach App"), ("service", "Nach Berechtigung")],
                      selected: grouping.rawValue)
    }

    static let apps = [
        InstrumentListSection(id: "befund", title: "Mit Befund", finding: true, items: [
            .sample("recorder", "record.circle", "Bildschirmrekorder", "Bildschirmaufnahme, Mikrofon, Bedienungshilfen",
                    badges: [SampleBadge.review, SampleBadge.new], finding: true),
            .sample("sync", "arrow.triangle.2.circlepath", "Ordner-Sync", "Festplattenvollzugriff",
                    badges: [SampleBadge.review], finding: true),
        ]),
        InstrumentListSection(id: "uebrige", title: "Übrige", items: [
            .sample("meeting", "video", "Videokonferenz", "Kamera, Mikrofon, Bildschirmaufnahme"),
            .sample("notes", "note.text", "Notizblock", "Erinnerungen, Kalender"),
            .sample("terminal", "terminal", "Terminal", "Festplattenvollzugriff", badges: [SampleBadge.new]),
            .sample("old", "questionmark.app.dashed", "Alter Scanner", "Kamera · App nicht mehr vorhanden",
                    badges: [SampleBadge.cleanup]),
        ]),
    ]

    static let services = [
        InstrumentListSection(id: "befund", title: "Mit Befund", finding: true, items: [
            .sample("accessibility", "accessibility", "Bedienungshilfen", "1 App", badges: [SampleBadge.review],
                    finding: true),
            .sample("fulldisk", "internaldrive", "Festplattenvollzugriff", "2 Apps", badges: [SampleBadge.review],
                    finding: true),
        ]),
        InstrumentListSection(id: "uebrige", title: "Übrige", items: [
            .sample("camera", "camera", "Kamera", "3 Apps", badges: [SampleBadge.cleanup]),
            .sample("microphone", "mic", "Mikrofon", "2 Apps"),
            .sample("screen", "rectangle.dashed.badge.record", "Bildschirmaufnahme", "2 Apps"),
            .sample("reminders", "checklist", "Erinnerungen", "1 App"),
            .sample("calendar", "calendar", "Kalender", "1 App"),
        ]),
    ]

    static let allowed = StatusItem("erlaubt", tone: .positive)
    static let denied = StatusItem("abgelehnt", tone: .neutral)
}

// MARK: - Details

/// Detail-Spalte mit optionalem Banner darüber; das Panel bringt `GrantDetailPanel` selbst mit.
private struct PermissionColumn<Banner: View, Content: View>: View {
    @ViewBuilder let banner: Banner
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            banner
            content
        }
    }
}

extension PermissionColumn where Banner == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.init(banner: { EmptyView() }, content: content)
    }
}

/// Details aus dem zentralen `GrantDetailPanel` (seit LB-2.2, #539) mit den Knöpfen der App.
private struct PermissionDetail: View {
    let content: GrantDetailContent
    var isResetting = false

    var body: some View {
        GrantDetailPanel(content: content) {
            InstrumentRowIcon(symbol: content.symbol, size: InstrumentSize.shield)
        } actions: {
            EmptyView()
        } grantIcon: {
            InstrumentRowIcon(symbol: $0.row.symbol)
        } grantActions: { grant in
            ForEach(PermissionSamples.actions[grant.id] ?? [], id: \.self) { title in
                Button(title) {}.disabled(isResetting && title == PermissionSamples.reset)
            }
        } extra: {
            EmptyView()
        }
    }
}

/// Detail einer App mit Befund; `isResetting` zeigt die laufende Aktion an „Bedienungshilfen“.
private struct RecorderDetail: View {
    var isResetting = false

    var body: some View {
        PermissionDetail(content: PermissionSamples.recorder(isResetting: isResetting), isResetting: isResetting)
    }
}

/// Detail der zweiten App mit Befund, nach einem fehlgeschlagenen Zurücksetzen.
private struct SyncDetail: View {
    var body: some View { PermissionDetail(content: PermissionSamples.sync) }
}

/// Detail nach Berechtigung: alle Apps mit Kamera-Zugriff.
private struct CameraDetail: View {
    var body: some View { PermissionDetail(content: PermissionSamples.camera) }
}

extension PermissionSamples {
    static let reset = "Zurücksetzen …"
    static let settings = "In Systemeinstellungen öffnen"
    /// Knöpfe je Eintrag wie in der App (`GrantActions`).
    static let actions = [
        "screen": [reset, settings], "accessibility": [reset, settings], "microphone": [settings],
        "fulldisk": [reset, settings], "meeting": [reset], "old": ["Für alle Apps zurücksetzen …"],
    ]

    static func recorder(isResetting: Bool) -> GrantDetailContent {
        GrantDetailContent(
            symbol: "record.circle", title: "Bildschirmrekorder", subtitle: "com.example.recorder",
            items: [StatusItem("prüfen", tone: .finding), StatusItem("neu", tone: .neutral)], finding: true,
            notes: [DetailNoteContent("Darf den Bildschirm aufnehmen und andere Apps steuern – seit 3 Tagen installiert.",
                                      kind: .finding)],
            facts: [DetailFactContent("Signatur", value: "Developer ID · Beispiel GmbH (A1B2C3D4E5)", tone: .positive),
                    DetailFactContent("Pfad", value: "/Applications/Bildschirmrekorder.app", isCode: true)],
            grantsTitle: "Berechtigungen", emptyGrantsText: "Keine Berechtigungen",
            grants: [
                GrantEntryContent(id: "screen", row: InstrumentRowContent(
                    symbol: "rectangle.dashed.badge.record", title: "Bildschirmaufnahme",
                    detail: "Benutzer · geändert am 8. Nov. 2026", status: allowed)),
                GrantEntryContent(id: "accessibility", row: InstrumentRowContent(
                    symbol: "accessibility", title: "Bedienungshilfen", detail: "Benutzer · geändert am 8. Nov. 2026",
                    badges: [SampleBadge.review], status: allowed, finding: true),
                    notes: [DetailNoteContent("Steuert andere Apps – nur erlauben, wenn du die App dafür brauchst.",
                                              kind: .finding)],
                    runningText: isResetting ? "Wird zurückgesetzt …" : nil),
                GrantEntryContent(id: "microphone", row: InstrumentRowContent(
                    symbol: "mic", title: "Mikrofon", detail: "System · geändert am 2. Nov. 2026", status: denied),
                    notes: [DetailNoteContent("Systemweiter Eintrag – Zurücksetzen nur mit Helper.", kind: .locked)]),
            ]
        )
    }

    static let sync = GrantDetailContent(
        symbol: "arrow.triangle.2.circlepath", title: "Ordner-Sync", subtitle: "com.example.foldersync",
        items: [StatusItem("prüfen", tone: .finding)], finding: true,
        notes: [DetailNoteContent("Liest alle Dateien dieses Benutzers, auch Mail und Nachrichten.", kind: .finding)],
        facts: [DetailFactContent("Signatur", value: "Developer ID · Beispiel AG (F6G7H8J9K0)", tone: .positive),
                DetailFactContent("Pfad", value: "/Applications/Ordner-Sync.app", isCode: true)],
        grantsTitle: "Berechtigungen", emptyGrantsText: "Keine Berechtigungen",
        grants: [
            GrantEntryContent(id: "fulldisk", row: InstrumentRowContent(
                symbol: "internaldrive", title: "Festplattenvollzugriff", detail: "Benutzer · geändert am 30. Okt. 2026",
                badges: [SampleBadge.review], status: allowed, finding: true),
                notes: [DetailNoteContent("Unverändert: Der Eintrag ist noch erlaubt.", kind: .info)]),
        ]
    )

    static let camera = GrantDetailContent(
        symbol: "camera", title: "Kamera", subtitle: "kTCCServiceCamera", items: [StatusItem("3 Apps", tone: .neutral)],
        grantsTitle: "Apps", emptyGrantsText: "Keine Berechtigungen",
        grants: [
            GrantEntryContent(id: "meeting", row: InstrumentRowContent(
                symbol: "video", title: "Videokonferenz", detail: "Benutzer · geändert am 1. Nov. 2026",
                status: allowed)),
            GrantEntryContent(id: "old", row: InstrumentRowContent(
                symbol: "questionmark.app.dashed", title: "Alter Scanner", detail: "Benutzer · App nicht mehr vorhanden",
                badges: [SampleBadge.cleanup], status: allowed),
                notes: [DetailNoteContent("Die App fehlt; der Eintrag lässt sich nur für alle Apps zurücksetzen.",
                                          kind: .locked)]),
        ]
    )
}

#Preview("LB-2.1 Berechtigungen") {
    ScrollView { DesignGallery(page: .permissionsDraft) }
}
