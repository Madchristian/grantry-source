import SwiftUI
@testable import GrantryCharts

/// Verlauf im Lagebild (LB-3.3, #545) mit festen Beispieldaten wie im abgenommenen Entwurf LB-3.1 (#543): Zustandszeile,
/// Filterzeile, „Wiederherstellbar“ und Änderungen nach Tag. Erfundene Einträge unter `com.example`.
@MainActor
extension SnapshotGallery {
    enum HistoryScene: String, CaseIterable, Sendable {
        case unread = "ungelesen"
        case restoring = "wiederherstellen-laeuft"
        case filtered = "gefiltert"
        case unreadable = "nicht-lesbar"
        case noChanges = "keine-aenderungen"
    }

    static let historySize = CGSize(width: 900, height: 680)

    static func history(_ scene: HistoryScene) -> some View {
        HistorySample(scene: scene)
    }
}

private enum HistorySamples {
    static let available = HistoryEntry.Restore.available(help: "Gesicherte Plist zurücklegen", isEnabled: true)
    static let added = StatusItem("neu", tone: .info)
    static let modified = StatusItem("geändert", tone: .neutral)
    static let removed = StatusItem("entfernt", tone: .neutral)

    static func restorable(running: Bool = false) -> HistorySection {
        HistorySection(id: "wiederherstellbar", title: "Wiederherstellbar", tone: .info, entries: [
            HistoryEntry(id: "beleg-1", content: InstrumentRowContent(symbol: "archivebox", title: "com.example.updater",
                                                                      detail: "Autostart entfernt · Benutzer"),
                         time: "vor 3 Tagen", restore: running ? .running : available),
        ])
    }

    static func today(unread: Bool) -> HistorySection {
        HistorySection(id: "heute", title: "Heute", entries: [
            HistoryEntry(id: "grant", content: InstrumentRowContent(
                symbol: "plus", title: "Bildschirmaufnahme für Fernhilfe", detail: "Berechtigung · erlaubt",
                badges: [InstrumentBadge("prüfen", tone: .critical, spoken: "prüfen, hoher Schweregrad")],
                status: added, finding: true), time: "14:31", isUnread: unread),
            HistoryEntry(id: "agent", content: InstrumentRowContent(symbol: "pencil", title: "Beispiel-Server",
                                                                    detail: "Agenten · Befehl geändert",
                                                                    status: modified),
                         time: "09:12", isUnread: unread,
                         command: HistoryEntry.Command(before: "npx beispiel-server@1.2",
                                                       after: "npx beispiel-server@1.3 --port 8021")),
        ])
    }

    static let monday = HistorySection(id: "montag", title: "Montag, 9. Nov.", entries: [
        HistoryEntry(id: "scanner", content: InstrumentRowContent(symbol: "minus", title: "com.example.scanner.agent",
                                                                  detail: "Autostart · LaunchAgent", status: removed),
                     time: "11:02", restore: available),
        HistoryEntry(id: "backup", content: InstrumentRowContent(symbol: "plus", title: "com.example.backup.daemon",
                                                                 detail: "Autostart · LaunchDaemon", status: added),
                     time: "08:15"),
    ])
}

private struct HistorySample: View {
    let scene: SnapshotGallery.HistoryScene

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            switch scene {
            case .unread:
                StatusLine(verdict: "3 Änderungen ungelesen", shield: .calm,
                           items: [StatusItem("2 neu", tone: .info), StatusItem("2 wiederherstellbar", tone: .neutral)],
                           facts: "42 Änderungen · Gesamter Verlauf")
                list([HistorySamples.restorable(), HistorySamples.today(unread: true), HistorySamples.monday],
                     focusedID: "agent", loadMore: .available)
            case .restoring:
                StatusLine(verdict: "Alles gelesen", shield: .calm,
                           items: [StatusItem("1 wiederherstellbar", tone: .neutral)],
                           facts: "42 Änderungen · Gesamter Verlauf")
                list([HistorySamples.restorable(running: true), HistorySamples.today(unread: false)],
                     focusedID: nil, loadMore: .loading)
            case .filtered:
                StatusLine(verdict: "Alles gelesen", shield: .calm, items: [], facts: "2 von 42 passen")
                ActiveFilterLine("Autostart · Letzte 7 Tage") {}
                list([HistorySamples.monday], focusedID: nil, loadMore: .hidden)
            case .unreadable:
                StatusLine(verdict: "Verlauf nicht lesbar", shield: .open,
                           items: [StatusItem("Fehler", tone: .critical)], facts: "–")
                InstrumentNote("Die Ablage des Verlaufs ließ sich nicht öffnen.", kind: .critical)
            case .noChanges:
                StatusLine(verdict: "Keine Änderungen", shield: .open,
                           items: [StatusItem("1 Quelle fehlt", tone: .neutral)], facts: "seit dem ersten Scan")
                InstrumentEmptyState(symbol: "clock", title: "Keine Änderungen",
                                     message: "Keine Änderungen erkannt – nicht alle Quellen wurden gelesen.")
                    .instrumentPanel()
            }
        }
        .padding(InstrumentSpacing.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .instrumentBackground()
    }

    private func list(_ sections: [HistorySection], focusedID: String?, loadMore: HistoryLoadMore) -> some View {
        HistoryList(sections: sections, focusedID: focusedID, loadMore: loadMore, restore: { _ in },
                    copy: { _ in }, loadMoreAction: {})
    }
}
