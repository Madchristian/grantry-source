import Observation

/// Geladene Seiten des Verlaufs und die Wiederherstellungsbelege, zugeordnet über `RestoreMatching`. Filtern und
/// Zuordnen sind Kit-Logik; das Modell lädt nur nach.
@MainActor
@Observable
public final class HistoryModel {
    /// Events je nachgeladener Seite.
    public static let pageSize = 100

    /// Geladene Events, neueste zuerst.
    public private(set) var events: [HistoryEvent] = []
    /// Alle Belege, neueste zuerst.
    public private(set) var receipts: [ReceiptEntry] = []
    /// Änderungen an Agenten-Konfigurationen mit Sicherung, neueste zuerst.
    public private(set) var agentChanges: [AgentConfigChange] = []
    /// Wiederherstellbares je Ereignis unter `events` (`RestoreMatching.restorablesByEvent`).
    public private(set) var restorablesByEvent: [HistoryEvent.ID: RestorableChange] = [:]
    /// Ob die Ablage weitere, ältere Events hat.
    public private(set) var hasMore = false
    public private(set) var isLoading = false
    /// Lesbare Meldung, wenn Verlauf oder Belege nicht geladen werden konnten.
    public private(set) var loadError: String?

    /// `nil`, wenn keine Ablage verfügbar ist (dann bleibt der Verlauf leer).
    private let store: (any SnapshotStore)?
    private let receiptStore: ReceiptStore
    private let agentBackups: AgentConfigBackupStore?
    /// Zählt Ladevorgänge; ein älterer, später fertiger Vorgang verwirft sein Ergebnis.
    private var generation = RequestGeneration()

    public init(store: (any SnapshotStore)?, receipts: ReceiptStore, agentBackups: AgentConfigBackupStore? = nil) {
        self.store = store
        receiptStore = receipts
        self.agentBackups = agentBackups
    }

    /// Lädt die bisher sichtbaren Seiten (mindestens eine) und die Belege neu – nach neuen Events, „Alle als gelesen
    /// markieren“ oder einer Aktion.
    public func reload() async {
        await load(limit: max(Self.pageSize, events.count), after: nil)
    }

    /// Hängt die nächste ältere Seite an.
    public func loadMore() async {
        guard hasMore, !isLoading, let last = events.last else { return }
        await load(limit: Self.pageSize, after: last)
    }

    /// Lädt eine Seite (ohne `cursor`: ab der neuesten, ersetzt die geladenen) und die Belege. Ein Neuladen
    /// überholt ein laufendes Nachladen.
    private func load(limit: Int, after cursor: HistoryEvent?) async {
        guard let store else { return }
        let request = generation.begin()
        isLoading = true
        var errors: [String] = []
        let page: [HistoryEvent]?
        do {
            page = try await store.events(limit: limit, after: cursor)
        } catch {
            page = nil
            errors.append(error.readableDescription)
        }
        let loadedReceipts: [ReceiptEntry]?
        do {
            loadedReceipts = try await receiptStore.receipts()
        } catch {
            loadedReceipts = nil
            errors.append(error.readableDescription)
        }
        // Liest nur die Belege (`change.json`), nie die gesicherten Dateien; räumt dabei verfallene und unvollständige
        // Sicherungen auf und übernimmt die verbliebenen.
        let loadedChanges = await Task.detached { [agentBackups] in
            agentBackups?.sweep() ?? []
        }.value
        guard generation.isCurrent(request) else { return }
        isLoading = false
        if let page {
            events = cursor == nil ? page : events + page
            hasMore = page.count == limit
        }
        if let loadedReceipts {
            receipts = loadedReceipts
        }
        agentChanges = loadedChanges
        restorablesByEvent = RestoreMatching.restorablesByEvent(events: events, receipts: receipts, changes: agentChanges)
        loadError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }
}
