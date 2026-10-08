import CoreData
import Foundation
import SwiftData
import Testing
import TestSupport
@testable import ManagerKit

@Suite("SwiftDataSnapshotStore")
struct SwiftDataSnapshotStoreTests {
    private func makeStore() throws -> SwiftDataSnapshotStore {
        try SwiftDataSnapshotStore.inMemory()
    }

    private func event(_ kind: ChangeEvent.Kind = .added, label: String = "com.example.agent", at offset: TimeInterval) -> ChangeEvent {
        ChangeEvent(
            kind: kind, before: nil, after: .autostartItem(TestData.item(label)),
            detectedAt: TestData.date.addingTimeInterval(offset)
        )
    }

    @Test func emptyStoreHasNoSnapshotAndNoEvents() async throws {
        let store = try makeStore()
        #expect(try await store.latestSnapshot() == nil)
        #expect(try await store.lastCheckedAt() == nil)
        #expect(try await store.events(limit: 10).isEmpty)
        #expect(try await store.unreadCount() == 0)
    }

    @Test func recordRoundTripsSnapshot() async throws {
        let store = try makeStore()
        let snapshot = TestData.snapshot(
            grants: [TestData.grant()], items: [TestData.item()],
            errors: [SourceError(source: .btm, message: "keine Rechte")]
        )
        _ = try await store.record(snapshot, events: [])
        #expect(try await store.latestSnapshot() == snapshot)
        #expect(try await store.lastCheckedAt() == snapshot.takenAt)
    }

    @Test func recordReplacesLatestSnapshotKeepingExactlyOneRow() async throws {
        let store = try makeStore()
        _ = try await store.record(TestData.snapshot(items: [TestData.item("a")]), events: [])
        let second = TestData.snapshot(items: [TestData.item("b")], at: TestData.date.addingTimeInterval(60))
        _ = try await store.record(second, events: [])
        #expect(try await store.latestSnapshot() == second)
        #expect(try await store.storedSnapshotCount() == 1)
    }

    @Test func recordReturnsUnreadHistoryEvents() async throws {
        let store = try makeStore()
        let events = [event(at: 1), event(.removed, label: "b", at: 2)]
        let recorded = try await store.record(TestData.snapshot(), events: events)
        #expect(recorded.map(\.event) == events)
        #expect(recorded.allSatisfy { !$0.isRead })
        #expect(Set(recorded.map(\.id)).count == 2)
    }

    @Test func eventsAreSortedByDetectedAtDescending() async throws {
        let store = try makeStore()
        _ = try await store.record(TestData.snapshot(), events: [event(label: "a", at: 1), event(label: "c", at: 3)])
        _ = try await store.record(TestData.snapshot(), events: [event(label: "b", at: 2)])
        let offsets = try await store.events(limit: 10).map { $0.event.detectedAt.timeIntervalSince(TestData.date) }
        #expect(offsets == [3, 2, 1])
    }

    @Test func eventsPageWithLimitAndCursor() async throws {
        let store = try makeStore()
        _ = try await store.record(TestData.snapshot(), events: (1...5).map { event(label: "e\($0)", at: TimeInterval($0)) })
        let firstPage = try await store.events(limit: 2)
        #expect(firstPage.map { $0.event.detectedAt.timeIntervalSince(TestData.date) } == [5, 4])
        let secondPage = try await store.events(limit: 2, after: firstPage.last)
        #expect(secondPage.map { $0.event.detectedAt.timeIntervalSince(TestData.date) } == [3, 2])
    }

    @Test func pagingEventsWithSameTimestampHasNoGapsOrDuplicates() async throws {
        let store = try makeStore()
        _ = try await store.record(TestData.snapshot(), events: (1...5).map { event(label: "e\($0)", at: 7) })
        var pages: [[HistoryEvent]] = []
        var cursor: HistoryEvent?
        repeat {
            let page = try await store.events(limit: 2, after: cursor)
            if page.isEmpty { break }
            pages.append(page)
            cursor = page.last
        } while true
        #expect(pages.map(\.count) == [2, 2, 1])
        let ids = pages.flatMap { $0.map(\.id) }
        #expect(Set(ids).count == 5)
    }

    @Test func eventsFromLaterScanComeFirstWhenTimestampsTie() async throws {
        let store = try makeStore()
        let first = try await store.record(TestData.snapshot(), events: [event(label: "a", at: 1)])
        let second = try await store.record(TestData.snapshot(), events: [event(label: "b", at: 1)])
        #expect(try await store.events(limit: 10).map(\.id) == second.map(\.id) + first.map(\.id))
    }

    @Test func nonPositiveLimitReturnsNoEvents() async throws {
        let store = try makeStore()
        _ = try await store.record(TestData.snapshot(), events: [event(at: 1)])
        #expect(try await store.events(limit: 0).isEmpty)
        #expect(try await store.events(limit: -1).isEmpty)
    }

    @Test func protocolOffersEventsWithoutCursor() async throws {
        let store: any SnapshotStore = try makeStore()
        _ = try await store.record(TestData.snapshot(), events: [event(at: 1)])
        #expect(try await store.events(limit: 20).count == 1)
    }

    @Test func markAllReadResetsUnreadCount() async throws {
        let store = try makeStore()
        _ = try await store.record(TestData.snapshot(), events: [event(label: "a", at: 1), event(label: "b", at: 2)])
        #expect(try await store.unreadCount() == 2)
        try await store.markAllRead()
        #expect(try await store.unreadCount() == 0)
        #expect(try await store.events(limit: 10).allSatisfy(\.isRead))
    }

    /// Äquivalenter Vollscan: Der aufgefrischte Snapshot (neue Sichtungszeit) ersetzt den gespeicherten, ohne Events,
    /// und der Prüfzeitpunkt wird gesetzt.
    @Test func touchReplacesSnapshotAndCheckedAt() async throws {
        let store = try makeStore()
        _ = try await store.record(TestData.networkSnapshot([TestData.listener()]), events: [])
        let later = TestData.date.addingTimeInterval(900)
        let refreshed = TestData.networkSnapshot([TestData.listener(lastSeen: later)], at: later)
        try await store.touch(refreshed, checkedAt: later)
        #expect(try await store.lastCheckedAt() == later)
        #expect(try await store.latestSnapshot() == refreshed)
        #expect(try await store.events(limit: 10).isEmpty)
        #expect(try await store.storedSnapshotCount() == 1)
    }

    /// Beim Stopp der Engine: nur der Snapshot, der Prüfzeitpunkt bleibt der des letzten Vollscans.
    @Test func touchWithoutCheckedAtKeepsThePreviousOne() async throws {
        let store = try makeStore()
        _ = try await store.record(TestData.networkSnapshot([TestData.listener()]), events: [])
        let later = TestData.date.addingTimeInterval(60)
        let refreshed = TestData.networkSnapshot([TestData.listener(lastSeen: later)], at: later)
        try await store.touch(refreshed, checkedAt: nil)
        #expect(try await store.lastCheckedAt() == TestData.date)
        #expect(try await store.latestSnapshot() == refreshed)
    }

    /// Teilscan mit Änderung: Der Snapshot wird ersetzt, der Prüfzeitpunkt bleibt der des letzten Vollscans.
    @Test func recordWithoutCheckedAtKeepsThePreviousOne() async throws {
        let store = try makeStore()
        _ = try await store.record(TestData.snapshot(items: [TestData.item("a")]), events: [])
        let partial = TestData.snapshot(items: [TestData.item("b")], at: TestData.date.addingTimeInterval(60))
        _ = try await store.record(partial, events: [], checkedAt: nil)
        #expect(try await store.latestSnapshot() == partial)
        #expect(try await store.lastCheckedAt() == TestData.date)
    }

    @Test func recordWithoutCheckedAtIntoAnEmptyStoreUsesTakenAt() async throws {
        let store = try makeStore()
        let snapshot = TestData.snapshot(items: [TestData.item()])
        _ = try await store.record(snapshot, events: [], checkedAt: nil)
        #expect(try await store.lastCheckedAt() == snapshot.takenAt)
    }

    @Test func touchWithoutSnapshotDoesNothing() async throws {
        let store = try makeStore()
        try await store.touch(TestData.snapshot(), checkedAt: TestData.date)
        #expect(try await store.lastCheckedAt() == nil)
        #expect(try await store.latestSnapshot() == nil)
    }

    @Test func pruneEventsRemovesOnlyOlderEvents() async throws {
        let store = try makeStore()
        _ = try await store.record(TestData.snapshot(), events: [event(label: "a", at: 1), event(label: "b", at: 10)])
        try await store.pruneEvents(olderThan: TestData.date.addingTimeInterval(5))
        let remaining = try await store.events(limit: 10)
        #expect(remaining.map { $0.event.detectedAt } == [TestData.date.addingTimeInterval(10)])
    }

    @Test func persistsAcrossContainersOnSameFile() async throws {
        try await ScratchDirectory.with(prefix: "store-probe") { directory in
            let url = directory.appending(path: "Probe.store")
            let snapshot = TestData.snapshot(grants: [TestData.grant()])
            do {
                let store = try SwiftDataSnapshotStore(url: url)
                _ = try await store.record(snapshot, events: [event(at: 1)])
            }
            let reopened = try SwiftDataSnapshotStore(url: url)
            #expect(try await reopened.latestSnapshot() == snapshot)
            #expect(try await reopened.unreadCount() == 1)
        }
    }

    @Test func recordKeepsOnlyNewestSnapshotRow() async throws {
        try await ScratchDirectory.with(prefix: "store-probe") { directory in
            let url = directory.appending(path: "Probe.store")
            do {
                let context = ModelContext(try SwiftDataSnapshotStore.makeContainer(url: url))
                for offset in [0.0, 1.0] {
                    context.insert(StoredSnapshot(takenAt: TestData.date.addingTimeInterval(offset), checkedAt: TestData.date, payload: Data()))
                }
                try context.save()
            }
            let store = try SwiftDataSnapshotStore(url: url)
            let snapshot = TestData.snapshot(at: TestData.date.addingTimeInterval(60))
            _ = try await store.record(snapshot, events: [])
            #expect(try await store.storedSnapshotCount() == 1)
            #expect(try await store.latestSnapshot() == snapshot)
        }
    }

    @Test func unreadableSnapshotPayloadCountsAsNoSnapshot() async throws {
        try await ScratchDirectory.with(prefix: "store-probe") { directory in
            let url = directory.appending(path: "Probe.store")
            do {
                let store = try SwiftDataSnapshotStore(url: url)
                _ = try await store.record(TestData.snapshot(), events: [])
            }
            do {
                let context = ModelContext(try SwiftDataSnapshotStore.makeContainer(url: url))
                for stored in try context.fetch(FetchDescriptor<StoredSnapshot>()) {
                    stored.payload = Data("kein JSON".utf8)
                }
                try context.save()
            }
            let reopened = try SwiftDataSnapshotStore(url: url)
            #expect(try await reopened.latestSnapshot() == nil)
        }
    }

    @Test func corruptStoreFileIsMovedAsideAndReplaced() async throws {
        try await ScratchDirectory.with(prefix: "store-probe") { directory in
            let url = directory.appending(path: "Probe.store")
            try Data("das ist keine Datenbank".utf8).write(to: url)
            let store = try SwiftDataSnapshotStore.openRecovering(url: url)
            let snapshot = TestData.snapshot(items: [TestData.item()])
            _ = try await store.record(snapshot, events: [event(at: 1)])
            #expect(try await store.latestSnapshot() == snapshot)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(names.contains { $0.hasPrefix("Probe.store.defekt-") })
        }
    }

    /// Ein Rechteproblem ist kein Defekt: Der Fehler geht durch, die Datei bleibt liegen.
    @Test func unreadableStoreFileIsLeftAloneAndErrorRethrown() async throws {
        try await ScratchDirectory.with(prefix: "store-probe") { directory in
            let url = directory.appending(path: "Probe.store")
            _ = try await SwiftDataSnapshotStore(url: url).record(TestData.snapshot(), events: [])
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

            #expect(throws: SnapshotStoreError.self) { try SwiftDataSnapshotStore.openRecovering(url: url) }

            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(names.contains("Probe.store"))
            #expect(!names.contains { $0.contains(".defekt-") })
        }
    }

    @Test func openFailuresAreClassifiedByTheUnderlyingCocoaError() {
        struct Opaque: Error {}
        #expect(StoreOpenFailure(CocoaError(.fileReadCorruptFile)) == .corruptOrIncompatible)
        #expect(StoreOpenFailure(CocoaError(.persistentStoreIncompatibleVersionHash)) == .corruptOrIncompatible)
        #expect(StoreOpenFailure(CocoaError(.migrationMissingSourceModel)) == .corruptOrIncompatible)
        #expect(StoreOpenFailure(CocoaError(.sqlite, userInfo: ["NSSQLiteErrorDomain": 26])) == .corruptOrIncompatible)
        #expect(StoreOpenFailure(CocoaError(.sqlite, userInfo: ["NSSQLiteErrorDomain": 5])) == .environmental)
        #expect(StoreOpenFailure(CocoaError(.fileReadNoPermission)) == .environmental)
        #expect(StoreOpenFailure(CocoaError(.fileWriteOutOfSpace)) == .environmental)
        #expect(StoreOpenFailure(CocoaError(.fileWriteUnknown)) == .environmental)
        #expect(StoreOpenFailure(CocoaError(.fileLocking)) == .environmental)
        #expect(StoreOpenFailure(Opaque()) == .unclassifiable)
    }

    @Test func errorsHaveGermanDescriptions() {
        let error = SnapshotStoreError.encodingFailed(underlying: "kaputt")
        #expect(error.errorDescription?.contains("kaputt") == true)
        #expect(SnapshotStoreError.decodingFailed(underlying: "x").errorDescription?.isEmpty == false)
    }
}
