import GrantryCharts
import SwiftUI

/// Entwurf LB-3.1 (#543): Verlauf im Lagebild – Zustandszeile, aktiver Filter, Abschnitt „Wiederherstellbar“, Änderungen
/// nach Tag gruppiert, ungelesene und angesprungene Einträge, Wiederherstellen läuft, Fehler, Leerzustände. Filter und
/// „Alle als gelesen markieren“ bleiben in der Symbolleiste (Entscheidung 8). Kein Detail: eine Zeile führt wie heute
/// zum Eintrag in seinem Bereich.
struct HistoryDraftBoard: View {
    var body: some View {
        AreaDraftPage(title: "Lagebild · Verlauf",
                      subtitle: "Entwurf LB-3.1: Zustandszeile, Filter, Wiederherstellbar, Änderungen nach Tag – feste "
                          + "Beispieldaten") {
            AreaDraftCaption(text: "1 · Ungelesene Änderungen, Wiederherstellbar, angesprungener Eintrag (Wachbuch)")
            Self.primary
            AreaDraftCaption(text: "2 · Wiederherstellen läuft (links) und Fehler mit Filter (rechts)")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                HistoryDraftScreen(verdict: HistorySamples.read, sections: [HistorySamples.sections(unread: false)[0]],
                                   restorable: HistorySamples.restorable(running: "receipt-updater"))
                HistoryDraftScreen(verdict: HistorySamples.filtered, filter: "Autostart · Letzte 7 Tage",
                                   failure: "Die Sicherung ist nicht mehr vorhanden. Es wurde nichts zurückgelegt.",
                                   sections: [HistorySamples.autostartOnly], restorable: [], showsLoadMore: false)
            }
            AreaDraftCaption(text: "3 · Ältere werden geladen, Verlauf nicht lesbar")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                HistoryDraftScreen(verdict: HistorySamples.read, sections: [HistorySamples.sections()[2]],
                                   restorable: [], isLoadingMore: true)
                HistoryDraftScreen(verdict: InventoryHead(verdict: "Verlauf nicht lesbar", shield: .open, items: [
                    StatusItem("Fehler", tone: .critical),
                ], facts: "–"), loadError: "Die Ablage des Verlaufs ließ sich nicht öffnen.", sections: [],
                                   restorable: [], showsLoadMore: false)
            }
            AreaDraftCaption(text: "4 · Keine Änderungen, keine Änderungen bei unvollständiger Abdeckung, keine Treffer")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                HistoryEmptyScreen(verdict: InventoryHead(verdict: "Keine Änderungen", shield: .calm, items: [], facts: "seit dem ersten Scan"),
                                   symbol: "clock", title: "Keine Änderungen",
                                   message: "Seit dem ersten Scan hat sich nichts geändert.")
                HistoryEmptyScreen(verdict: InventoryHead(verdict: "Keine Änderungen", shield: .calm, items: [
                    StatusItem("1 Quelle fehlt", tone: .neutral),
                ], facts: "seit dem ersten Scan"), symbol: "clock", title: "Keine Änderungen",
                                   message: "Keine Änderungen erkannt – nicht alle Quellen wurden gelesen.")
                HistoryEmptyScreen(verdict: InventoryHead(verdict: "3 Änderungen ungelesen", shield: .calm, items: [], facts: "0 von 42 passen"),
                                   filter: "Erweiterungen · Entfernt", symbol: "line.3.horizontal.decrease.circle",
                                   title: "Keine Treffer", message: "Keine Änderung passt zu den gewählten Filtern.",
                                   showsReset: true)
            }
        }
    }
}

extension HistoryDraftBoard {
    /// Hauptzustand des Bereichs, auch auf der Galerieseite „Alle Ansichten“ (LB-5.5, #556).
    @ViewBuilder static var primary: some View {
        HistoryDraftScreen(verdict: HistorySamples.unread, sections: HistorySamples.sections(),
                           restorable: HistorySamples.restorable(), focusedID: "agent-command")
    }
}

// MARK: - Bereich

/// Verlauf: Zustandszeile, aktiver Filter, Ergebnis einer Aktion, ein Panel mit „Wiederherstellbar“ und den Tagen –
/// gezeichnet aus den zentralen Bausteinen der Umsetzung (LB-3.3, #545: `HistoryList`, `ActiveFilterLine`).
struct HistoryDraftScreen: View {
    let verdict: InventoryHead
    var filter: String?
    var failure: String?
    var loadError: String?
    let sections: [HistorySection]
    let restorable: [HistoryEntry]
    var focusedID: String?
    var showsLoadMore = true
    var isLoadingMore = false

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            StatusLine(verdict: verdict.verdict, shield: verdict.shield, items: verdict.items, facts: verdict.facts)
            if let filter { ActiveFilterLine(filter) {} }
            if let failure { InstrumentBanner("Wiederherstellen fehlgeschlagen", message: failure, tone: .critical) { BannerDismissButton {} } }
            if let loadError { InstrumentNote(loadError, kind: .critical) }
            if !sections.isEmpty || !restorable.isEmpty {
                HistoryList(sections: allSections, focusedID: focusedID,
                            loadMore: showsLoadMore ? (isLoadingMore ? .loading : .available) : .hidden,
                            restore: { _ in }, copy: { _ in }, loadMoreAction: {})
                    // Im Bild so hoch wie der Inhalt; im Fenster füllt die Liste die Höhe.
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .areaDraftFrame()
    }

    private var allSections: [HistorySection] {
        (restorable.isEmpty ? [] : [HistorySection(id: "wiederherstellbar", title: "Wiederherstellbar", tone: .info,
                                                   entries: restorable)]) + sections
    }
}

/// Leerzustand im Panel unter Zustandszeile und Filter.
struct HistoryEmptyScreen: View {
    let verdict: InventoryHead
    var filter: String?
    let symbol: String
    let title: String
    let message: String
    var showsReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            StatusLine(verdict: verdict.verdict, shield: verdict.shield, items: verdict.items, facts: verdict.facts)
            if let filter { ActiveFilterLine(filter) {} }
            VStack(spacing: InstrumentSpacing.group) {
                InstrumentEmptyState(symbol: symbol, title: title, message: message)
                if showsReset { Button("Filter zurücksetzen") {} }
            }
            .padding(.bottom, InstrumentSpacing.empty)
            .instrumentPanel()
            .frame(height: AreaDraftHeight.empty)
        }
        .areaDraftFrame()
    }
}

// MARK: - Beispieldaten

private enum HistorySamples {
    static let unread = InventoryHead(verdict: "3 Änderungen ungelesen", shield: .calm, items: [StatusItem("2 neu", tone: .info), StatusItem("2 wiederherstellbar",
                                                                                          tone: .neutral)], facts: "42 Änderungen · Gesamter Verlauf")
    static let read = InventoryHead(verdict: "Alles gelesen", shield: .calm, items: [StatusItem("2 wiederherstellbar", tone: .neutral)], facts: "42 Änderungen · Gesamter Verlauf")
    static let filtered = InventoryHead(verdict: "Alles gelesen", shield: .calm, items: [], facts: "2 von 42 passen")

    static let available = HistoryEntry.Restore.available(help: "Gesicherte Plist zurücklegen", isEnabled: true)
    static let added = StatusItem("neu", tone: .info)
    static let modified = StatusItem("geändert", tone: .neutral)
    static let removed = StatusItem("entfernt", tone: .neutral)

    static func restorable(running: String? = nil) -> [HistoryEntry] {
        [
            HistoryEntry(id: "receipt-updater",
                         content: InstrumentRowContent(symbol: "archivebox", title: "com.example.updater",
                                                       detail: "Autostart entfernt · Benutzer"),
                         time: "vor 3 Tagen", restore: running == "receipt-updater" ? .running : available),
            HistoryEntry(id: "receipt-server",
                         content: InstrumentRowContent(symbol: "archivebox", title: "Beispiel-Server",
                                                       detail: "deaktiviert · Beispiel-Editor (Projekt web)"),
                         time: "vor 5 Tagen", restore: available),
        ]
    }

    static func sections(unread: Bool = true) -> [HistorySection] {
        [
            HistorySection(id: "Heute", title: "Heute", entries: [
                HistoryEntry(id: "grant-screen",
                             content: InstrumentRowContent(symbol: "plus", title: "Bildschirmaufnahme für Fernhilfe",
                                                           detail: "Berechtigung · erlaubt",
                                                           badges: [SampleBadge.reviewHigh], status: added,
                                                           finding: true),
                             time: "14:31", isUnread: unread),
                HistoryEntry(id: "autostart-updater",
                             content: InstrumentRowContent(symbol: "plus", title: "com.example.updater",
                                                           detail: "Autostart · LaunchAgent", status: added),
                             time: "14:20", isUnread: unread),
                HistoryEntry(id: "agent-command",
                             content: InstrumentRowContent(symbol: "pencil", title: "Beispiel-Server",
                                                           detail: "Agenten · Befehl geändert", status: modified),
                             time: "09:12", isUnread: unread,
                             command: HistoryEntry.Command(before: "npx beispiel-server@1.2",
                                                           after: "npx beispiel-server@1.3 --port 8021")),
            ]),
            HistorySection(id: "Gestern", title: "Gestern", entries: [
                HistoryEntry(id: "app-notes",
                             content: InstrumentRowContent(symbol: "pencil", title: "Notizblock",
                                                           detail: "App · Version 4.2 → 4.3", status: modified),
                             time: "18:45"),
            ]),
            HistorySection(id: "Montag, 9. Nov.", title: "Montag, 9. Nov.", entries: [
                HistoryEntry(id: "autostart-scanner",
                             content: InstrumentRowContent(symbol: "minus", title: "com.example.scanner.agent",
                                                           detail: "Autostart · LaunchAgent", status: removed),
                             time: "11:02", restore: available),
                HistoryEntry(id: "ext-filter",
                             content: InstrumentRowContent(symbol: "plus", title: "Beispiel-Inhaltsfilter",
                                                           detail: "Erweiterung · Netzwerkfilter", status: added),
                             time: "10:40"),
            ]),
        ]
    }

    static let autostartOnly = HistorySection(id: "Montag, 9. Nov.", title: "Montag, 9. Nov.", entries: [
        HistoryEntry(id: "autostart-scanner",
                     content: InstrumentRowContent(symbol: "minus", title: "com.example.scanner.agent",
                                                   detail: "Autostart · LaunchAgent", status: removed),
                     time: "11:02", restore: available),
        HistoryEntry(id: "autostart-backup",
                     content: InstrumentRowContent(symbol: "plus", title: "com.example.backup.daemon",
                                                   detail: "Autostart · LaunchDaemon", status: added),
                     time: "08:15"),
    ])
}

#Preview("LB-3.1 Verlauf") {
    ScrollView { DesignGallery(page: .historyDraft) }
}
