import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

/// Liefert Seiten aus `events` (neueste zuerst); mit `gates` hält der n-te Aufruf von `events(limit:after:)` an.
private final class PagedStore: SnapshotStore {
    let events: [HistoryEvent]
    private let calls = Mutex(0)
    private let gates: [Int: Gate]

    init(events: [HistoryEvent], gates: [Int: Gate] = [:]) {
        self.events = events
        self.gates = gates
    }

    func events(limit: Int, after cursor: HistoryEvent?) async throws -> [HistoryEvent] {
        let call = calls.withLock { calls in
            defer { calls += 1 }
            return calls
        }
        try await gates[call]?.wait()
        let start = cursor.flatMap { cursor in events.firstIndex { $0.id == cursor.id }.map { $0 + 1 } } ?? 0
        return Array(events.dropFirst(start).prefix(limit))
    }

    func latestSnapshot() async throws -> Snapshot? { nil }
    func record(_ snapshot: Snapshot, events: [ChangeEvent], checkedAt: Date?) async throws -> [HistoryEvent] { [] }
    func touch(_ snapshot: Snapshot, checkedAt: Date?) async throws {}
    func lastCheckedAt() async throws -> Date? { nil }
    func unreadCount() async throws -> Int { 0 }
    func markAllRead() async throws {}
    func pruneEvents(olderThan date: Date) async throws {}
}

@MainActor
@Suite struct HistoryModelTests {
    private static func events(_ count: Int) -> [HistoryEvent] {
        (0..<count).map { index in
            TestData.historyEvent(.added, .autostartItem(TestData.item("e\(index)")),
                                  at: TestData.date.addingTimeInterval(-TimeInterval(index)))
        }
    }

    /// Belegablage ohne Datei (liefert keine Belege); die Tests schreiben keine.
    private func withReceipts(_ body: (ReceiptStore) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "history-model-\(UUID().uuidString)/Receipts.json")
        try await body(ReceiptStore(url: url))
    }

    @Test func pagesThroughTheStore() async throws {
        try await withReceipts { receipts in
            let all = Self.events(HistoryModel.pageSize + 20)
            let model = HistoryModel(store: PagedStore(events: all), receipts: receipts)

            await model.reload()
            #expect(model.events == Array(all.prefix(HistoryModel.pageSize)))
            #expect(model.hasMore && !model.isLoading && model.loadError == nil)

            await model.loadMore()
            #expect(model.events == all)
            #expect(!model.hasMore)

            // Neu laden behält alle bisher sichtbaren Seiten.
            await model.reload()
            #expect(model.events == all)
        }
    }

    /// Ein älteres Nachladen, das erst nach einem neueren Neuladen fertig wird, verwirft sein Ergebnis.
    @Test(.timeLimit(.minutes(1))) func staleLoadIsDiscarded() async throws {
        try await withReceipts { receipts in
            let all = Self.events(HistoryModel.pageSize + 20)
            let slow = Gate()
            let store = PagedStore(events: all, gates: [1: slow])
            let model = HistoryModel(store: store, receipts: receipts)
            await model.reload()

            let loadingMore = Task { await model.loadMore() }
            while !model.isLoading { await Task.yield() }
            await model.reload()
            let afterReload = model.events
            slow.open()
            await loadingMore.value

            #expect(afterReload == Array(all.prefix(HistoryModel.pageSize)))
            #expect(model.events == afterReload)
            #expect(!model.isLoading)
        }
    }

    @Test func withoutStoreStaysEmpty() async throws {
        try await withReceipts { receipts in
            let model = HistoryModel(store: nil, receipts: receipts)
            await model.reload()
            #expect(model.events.isEmpty && !model.hasMore)
        }
    }
}

/// Außerhalb des Main Actors, damit die Scratch-Ablage den ganzen Test umschließt.
@Suite struct HistoryModelAgentBackupTests {
    /// Mit Sicherungsablage: Laden räumt sie zuerst auf (`sweep`) und ordnet die übrigen Belege ihren Ereignissen zu.
    @Test func loadsSweptAgentChangesAndMatchesThem() async throws {
        try await ScratchDirectory.with { directory in
            let backups = AgentConfigBackupStore(root: directory.appending(path: "AgentBackups"), now: { TestData.date })
            let entry = TestData.mcpServer("files")
            func change(at date: Date) -> AgentConfigChange {
                AgentConfigChange(id: UUID(), kind: .removedServer, server: entry.reference, changedAt: date,
                                  originalDigest: AgentConfigFileAccess.digest(of: Data("{}".utf8)), resultDigest: "b")
            }
            let fresh = change(at: TestData.date)
            let expired = change(at: TestData.date.addingTimeInterval(-AgentConfigBackupStore.retentionPeriod - 1))
            try backups.save(fresh, original: Data("{}".utf8))
            try backups.save(expired, original: Data("{}".utf8))
            let event = TestData.historyEvent(.removed, .mcpServer(entry), at: TestData.date.addingTimeInterval(5))
            let receipts = ReceiptStore(url: directory.appending(path: "Receipts.json"))

            let model = await HistoryModel(store: PagedStore(events: [event]), receipts: receipts, agentBackups: backups)
            await model.reload()
            #expect(await model.agentChanges == [fresh])
            #expect(backups.changes() == [fresh])
            #expect(await model.restorablesByEvent == [event.id: .agentConfig(fresh)])
        }
    }
}
