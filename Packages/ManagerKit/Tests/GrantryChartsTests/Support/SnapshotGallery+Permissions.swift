import SwiftUI
@testable import GrantryCharts

/// Bereich Berechtigungen (LB-2.2, #539) mit festen Beispieldaten wie im abgenommenen Entwurf LB-2.1 (#538): erfundene
/// Apps unter `com.example`, keine Benutzernamen, Hostnamen oder echten Pfade.
@MainActor
extension SnapshotGallery {
    enum PermissionsScene: String, CaseIterable, Sendable {
        case byApp = "nach-app"
        case nothingSelected = "nichts-gewaehlt"
        case byService = "nach-berechtigung"
        case notScanned = "kein-scan"
        case incomplete = "unvollstaendig"
    }

    static let permissionsSize = CGSize(width: 1180, height: 720)

    static func permissions(_ scene: PermissionsScene) -> some View {
        PermissionsSample(scene: scene)
    }

    static let permissionsHead = InventoryHead(
        verdict: "2 Apps auffällig", finding: true,
        items: [StatusItem("2 prüfen", tone: .finding), StatusItem("2 neu seit 7 Tagen", tone: .neutral)],
        facts: "6 Apps · 12 Berechtigungen · Scan 14:32"
    )

    static let permissionServices = [
        InstrumentListSection(id: "befund", title: "Mit Befund", finding: true, items: [
            InstrumentListItem(id: "accessibility", content: InstrumentRowContent(
                symbol: "accessibility", title: "Bedienungshilfen", detail: "1 App", badges: [review], finding: true)),
            InstrumentListItem(id: "fulldisk", content: InstrumentRowContent(
                symbol: "internaldrive", title: "Festplattenvollzugriff", detail: "2 Apps", badges: [review],
                finding: true)),
        ]),
        InstrumentListSection(id: "uebrige", title: "Übrige", items: [
            InstrumentListItem(id: "camera", content: InstrumentRowContent(
                symbol: "camera", title: "Kamera", detail: "3 Apps", badges: [cleanup])),
            InstrumentListItem(id: "microphone", content: InstrumentRowContent(
                symbol: "mic", title: "Mikrofon", detail: "2 Apps")),
            InstrumentListItem(id: "calendar", content: InstrumentRowContent(
                symbol: "calendar", title: "Kalender", detail: "1 App")),
        ]),
    ]

    static let allowed = StatusItem("erlaubt", tone: .positive)

    static let recorderDetail = recorder(runningText: "Wird zurückgesetzt …")

    /// Ohne laufende Aktion: `ImageRenderer` zeichnet `ProgressView` nur als Platzhalter.
    static func recorder(runningText: String?) -> GrantDetailContent {
        GrantDetailContent(
            symbol: "record.circle", title: "Bildschirmrekorder", subtitle: "com.example.recorder",
            items: [StatusItem("prüfen", tone: .finding), StatusItem("neu", tone: .neutral)], finding: true,
            facts: [DetailFactContent("Signatur", value: "Developer ID · Beispiel GmbH (A1B2C3D4E5)", tone: .positive),
                    DetailFactContent("Pfad", value: "/Applications/Bildschirmrekorder.app", isCode: true)],
            grantsTitle: "Berechtigungen", emptyGrantsText: "Keine Berechtigungen",
            grants: [
                GrantEntryContent(id: "screen", row: InstrumentRowContent(
                    symbol: "rectangle.dashed.badge.record", title: "Bildschirmaufnahme",
                    detail: "Benutzer · geändert am 8. Nov. 2026", status: allowed)),
                GrantEntryContent(id: "accessibility", row: InstrumentRowContent(
                    symbol: "accessibility", title: "Bedienungshilfen", detail: "Benutzer · geändert am 8. Nov. 2026",
                    badges: [review], status: allowed, finding: true),
                    notes: [DetailNoteContent("Steuert andere Apps – nur erlauben, wenn du die App dafür brauchst.",
                                              kind: .finding)],
                    runningText: runningText),
                GrantEntryContent(id: "microphone", row: InstrumentRowContent(
                    symbol: "mic", title: "Mikrofon", detail: "System · geändert am 2. Nov. 2026",
                    status: StatusItem("abgelehnt", tone: .neutral)),
                    notes: [DetailNoteContent("Systemweiter Eintrag – Zurücksetzen nur mit Helper.",
                                              kind: .locked)]),
            ]
        )
    }

    static let cameraDetail = GrantDetailContent(
        symbol: "camera", title: "Kamera", subtitle: "kTCCServiceCamera", items: [StatusItem("3 Apps", tone: .neutral)],
        grantsTitle: "Apps", emptyGrantsText: "Keine Apps",
        grants: [
            GrantEntryContent(id: "meeting", row: InstrumentRowContent(
                symbol: "video", title: "Videokonferenz", detail: "Benutzer · geändert am 1. Nov. 2026",
                status: allowed)),
            GrantEntryContent(id: "old", row: InstrumentRowContent(
                symbol: "questionmark.app.dashed", title: "Alter Scanner",
                detail: "Benutzer · App nicht mehr vorhanden",
                badges: [cleanup], status: allowed),
                notes: [DetailNoteContent("Die App fehlt; der Eintrag lässt sich nur für alle Apps zurücksetzen.",
                                          kind: .locked)]),
        ]
    )
}

private struct PermissionsSample: View {
    let scene: SnapshotGallery.PermissionsScene

    var body: some View {
        switch scene {
        case .byApp:
            board(selection: "recorder") { GrantDetailPanel(content: SnapshotGallery.recorder(runningText: nil)) }
        case .nothingSelected:
            board(selection: nil) {
                InstrumentEmptyState(symbol: "hand.raised", title: "Nichts gewählt",
                                     message: "Wähle links eine App, um ihre Berechtigungen zu sehen.")
                    .instrumentPanel()
            }
        case .byService:
            InventoryBoard(head: SnapshotGallery.permissionsHead) {
                controls(grouping: "service", coverage: complete)
            } list: {
                InstrumentList("Berechtigungen", count: "5", sections: SnapshotGallery.permissionServices,
                               selection: .constant("camera"))
            } detail: {
                GrantDetailPanel(content: SnapshotGallery.cameraDetail)
            }
        case .notScanned:
            InventoryBoard(head: InventoryHead(verdict: "Noch nicht geprüft", shield: .open, items: [],
                                               facts: "kein Scan seit dem Start")) {
                controls(grouping: "app", coverage: ProgressSpur(title: "Abdeckung unbekannt",
                                                                 detail: "noch nichts gelesen", fraction: 0,
                                                                 tone: .neutral))
            } list: {
                InstrumentEmptyState(symbol: "clock", title: "Noch kein Scan",
                                     message: "Der erste Scan liest die Berechtigungen aller Apps ein.")
                    .instrumentPanel()
            } detail: {
                InstrumentEmptyState(symbol: "hand.raised", title: "Nichts gewählt",
                                     message: "Wähle links eine App, um ihre Berechtigungen zu sehen.")
                    .instrumentPanel()
            }
        case .incomplete:
            InventoryBoard(head: InventoryHead(verdict: "1 App auffällig", finding: true,
                                               items: [StatusItem("1 Quelle fehlt", tone: .finding),
                                                       StatusItem("1 prüfen", tone: .finding)],
                                               facts: "2 Apps · 4 Berechtigungen · Scan 14:32")) {
                controls(grouping: "app", coverage: ProgressSpur(title: "Abdeckung unvollständig",
                                                                 detail: "Systemdatenbank ohne Helper nicht gelesen",
                                                                 fraction: 2.0 / 3, tone: .finding))
            } list: {
                InstrumentList("Apps", count: "2", sections: [SnapshotGallery.lagebildSections[0]],
                               selection: .constant(nil))
            } detail: {
                InstrumentEmptyState(symbol: "hand.raised", title: "Nichts gewählt",
                                     message: "Wähle links eine App, um ihre Berechtigungen zu sehen.")
                    .instrumentPanel()
            }
        }
    }

    private var complete: ProgressSpur<EmptyView> {
        ProgressSpur(title: "Abdeckung vollständig", detail: "alle Quellen gelesen · 14:32", fraction: 1,
                     tone: .positive)
    }

    private func board(selection: String?, @ViewBuilder detail: () -> some View) -> some View {
        InventoryBoard(head: SnapshotGallery.permissionsHead) {
            controls(grouping: "app", coverage: complete)
        } list: {
            InstrumentList("Apps", count: "6", sections: SnapshotGallery.lagebildSections,
                           selection: .constant(selection))
        } detail: {
            detail()
        }
    }

    private func controls(grouping: String, coverage: some View) -> some View {
        HStack(spacing: InstrumentSpacing.panel) {
            InstrumentSegments("Gruppierung", selection: .constant(grouping),
                               options: [("app", "Nach App"), ("service", "Nach Berechtigung")])
                .frame(width: InstrumentSize.columnNarrow)
            coverage
        }
    }
}
