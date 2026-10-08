import Foundation
import SwiftData
import Testing
import TestSupport
@testable import ManagerKit

@Suite("Beobachtungen in der Ablage")
struct ObservationStoreTests {
    private func observation(_ name: String = "Cursor", at offset: TimeInterval = 0) -> InstallationObservation {
        InstallationObservation(
            name: name, note: "Test", startedAt: TestData.date.addingTimeInterval(offset),
            baseline: TestData.appSnapshot([TestData.installedApp()])
        )
    }

    @Test func startedObservationIsActiveAndRoundTrips() async throws {
        let store = try SwiftDataSnapshotStore.inMemory()
        let started = observation()
        try await store.startObservation(started)
        #expect(try await store.activeObservation() == started)
        #expect(try await store.observation(id: started.id) == started)
        let summary = try #require(try await store.observationSummaries().first)
        #expect(summary.name == "Cursor" && summary.isActive && summary.addedCount == nil && summary.cleanupCount == 0)
    }

    @Test func onlyOneObservationRunsAtATime() async throws {
        let store = try SwiftDataSnapshotStore.inMemory()
        try await store.startObservation(observation("Cursor"))
        await #expect(throws: ObservationStoreError.alreadyActive(name: "Cursor")) {
            try await store.startObservation(observation("Zed"))
        }
    }

    @Test func finishingStoresTheFinalSnapshotAndCountsAdditions() async throws {
        let store = try SwiftDataSnapshotStore.inMemory()
        let started = observation()
        try await store.startObservation(started)
        let final = TestData.appSnapshot(
            [TestData.installedApp(), TestData.installedApp("Cursor", bundleID: "com.todesktop.cursor")],
            at: TestData.date.addingTimeInterval(600)
        )
        let finished = try await store.finishObservation(id: started.id, final: final, at: final.takenAt)
        #expect(finished.final == final && finished.finishedAt == final.takenAt && !finished.isActive)
        #expect(try await store.activeObservation() == nil)
        #expect(try await store.observationSummaries().first?.addedCount == 1)
        await #expect(throws: ObservationStoreError.alreadyFinished) {
            _ = try await store.finishObservation(id: started.id, final: final, at: final.takenAt)
        }
        // Danach darf eine neue beginnen.
        try await store.startObservation(observation("Zed", at: 700))
    }

    @Test func cleanupRecordsAreAppendedAndCounted() async throws {
        let store = try SwiftDataSnapshotStore.inMemory()
        let started = observation()
        try await store.startObservation(started)
        let record = ObservationCleanupRecord(
            performedAt: TestData.date, entries: [.init(title: "„com.example.agent“", isDone: true, reason: nil)]
        )
        try await store.appendCleanup(record, toObservation: started.id)
        try await store.appendCleanup(record, toObservation: started.id)
        #expect(try await store.observation(id: started.id)?.cleanups == [record, record])
        #expect(try await store.observationSummaries().first?.cleanupCount == 2)
    }

    @Test func summariesAreNewestFirstAndDeletable() async throws {
        let store = try SwiftDataSnapshotStore.inMemory()
        let older = observation("Alt", at: 0)
        try await store.startObservation(older)
        _ = try await store.finishObservation(id: older.id, final: older.baseline, at: TestData.date.addingTimeInterval(10))
        let newer = observation("Neu", at: 100)
        try await store.startObservation(newer)
        #expect(try await store.observationSummaries().map(\.name) == ["Neu", "Alt"])
        try await store.deleteObservation(id: older.id)
        #expect(try await store.observationSummaries().map(\.name) == ["Neu"])
        #expect(try await store.observation(id: older.id) == nil)
    }

    @Test func missingObservationIsReported() async throws {
        let store = try SwiftDataSnapshotStore.inMemory()
        await #expect(throws: ObservationStoreError.notFound) {
            try await store.appendCleanup(ObservationCleanupRecord(performedAt: TestData.date, entries: []), toObservation: UUID())
        }
    }

    /// Die laufende Beobachtung übersteht das erneute Öffnen der Datei (Neustart von App oder Mac).
    @Test func activeObservationSurvivesReopening() async throws {
        try await ScratchDirectory.with(prefix: "observation-store") { directory in
            let url = directory.appending(path: "History.store")
            let started = observation()
            try await SwiftDataSnapshotStore(url: url).startObservation(started)
            #expect(try await SwiftDataSnapshotStore(url: url).activeObservation() == started)
        }
    }

    /// Ein Verlauf aus Schema V1 wird auf V2 migriert: Snapshot und Events bleiben, Beobachtungen sind möglich.
    @Test func migratesVersion1StoreKeepingHistory() async throws {
        try await ScratchDirectory.with(prefix: "observation-migration") { directory in
            let url = directory.appending(path: "History.store")
            let snapshot = TestData.snapshot(items: [TestData.item()])
            let event = ChangeEvent(kind: .added, before: nil, after: .autostartItem(TestData.item()), detectedAt: TestData.date)
            try Self.writeVersion1Store(at: url, snapshot: snapshot, event: event)

            let store = try SwiftDataSnapshotStore.openRecovering(url: url)
            #expect(try await store.latestSnapshot() == snapshot)
            #expect(try await store.events(limit: 10).map(\.event) == [event])
            try await store.startObservation(observation())
            #expect(try await store.activeObservation()?.name == "Cursor")
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(!leftovers.contains { $0.contains(".defekt-") })
        }
    }

    /// Legt eine Ablage nur mit Schema V1 an, wie sie ältere Grantry-Versionen schreiben.
    private static func writeVersion1Store(at url: URL, snapshot: Snapshot, event: ChangeEvent) throws {
        let container = try ModelContainer(
            for: Schema(versionedSchema: HistorySchemaV1.self), configurations: [ModelConfiguration(url: url)]
        )
        let context = ModelContext(container)
        context.insert(StoredSnapshot(
            takenAt: snapshot.takenAt, checkedAt: snapshot.takenAt, payload: try JSONEncoder().encode(snapshot)
        ))
        context.insert(StoredEvent(
            id: UUID(), sequence: 1, detectedAt: event.detectedAt, kind: event.kind.rawValue,
            subjectID: event.subject.recordID, isRead: false, payload: try JSONEncoder().encode(event)
        ))
        try context.save()
    }
}
