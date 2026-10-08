import Foundation
import SwiftData

extension SwiftDataSnapshotStore: ObservationStore {
    /// Ein unlesbarer Datensatz gilt als nicht vorhanden (wie `latestSnapshot()`); er bleibt aber liegen, blockiert neue
    /// Starts und lässt sich in der Detailansicht löschen.
    public func activeObservation() throws -> InstallationObservation? {
        try storedActiveObservation().flatMap(Self.decodeLogging)
    }

    public func observationSummaries() throws -> [ObservationSummary] {
        let descriptor = FetchDescriptor<StoredObservation>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        return try modelContext.fetch(descriptor).map { stored in
            ObservationSummary(
                id: stored.id, name: stored.name, note: stored.note, startedAt: stored.startedAt,
                finishedAt: stored.finishedAt, addedCount: stored.addedCount, cleanupCount: stored.cleanupCount
            )
        }
    }

    public func observation(id: UUID) throws -> InstallationObservation? {
        try storedObservation(id: id).map(Self.decode)
    }

    public func startObservation(_ observation: InstallationObservation) throws {
        try transaction {
            if let active = try storedActiveObservation() { throw ObservationStoreError.alreadyActive(name: active.name) }
            modelContext.insert(StoredObservation(
                id: observation.id, name: observation.name, note: observation.note, startedAt: observation.startedAt,
                baseline: try Self.encode(observation.baseline), cleanups: try Self.encode(observation.cleanups)
            ))
        }
    }

    public func finishObservation(id: UUID, final: Snapshot, at date: Date) throws -> InstallationObservation {
        try transaction {
            guard let stored = try storedObservation(id: id) else { throw ObservationStoreError.notFound }
            guard stored.finishedAt == nil else { throw ObservationStoreError.alreadyFinished }
            var observation = try Self.decode(stored)
            observation.finishedAt = date
            observation.final = final
            stored.finishedAt = date
            stored.final = try Self.encode(final)
            stored.addedCount = observation.balance?.addedCount
            return observation
        }
    }

    public func appendCleanup(_ record: ObservationCleanupRecord, toObservation id: UUID) throws {
        try transaction {
            guard let stored = try storedObservation(id: id) else { throw ObservationStoreError.notFound }
            let cleanups = try Self.decode([ObservationCleanupRecord].self, from: stored.cleanups) + [record]
            stored.cleanups = try Self.encode(cleanups)
            stored.cleanupCount = cleanups.count
        }
    }

    public func deleteObservation(id: UUID) throws {
        try transaction {
            try modelContext.delete(model: StoredObservation.self, where: #Predicate { $0.id == id })
        }
    }

    private func storedActiveObservation() throws -> StoredObservation? {
        var descriptor = FetchDescriptor<StoredObservation>(predicate: #Predicate { $0.finishedAt == nil })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func storedObservation(id: UUID) throws -> StoredObservation? {
        var descriptor = FetchDescriptor<StoredObservation>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private static func decode(_ stored: StoredObservation) throws -> InstallationObservation {
        InstallationObservation(
            id: stored.id, name: stored.name, note: stored.note, startedAt: stored.startedAt,
            baseline: try decode(Snapshot.self, from: stored.baseline), finishedAt: stored.finishedAt,
            final: try stored.final.map { try decode(Snapshot.self, from: $0) },
            cleanups: try decode([ObservationCleanupRecord].self, from: stored.cleanups)
        )
    }

    private static func decodeLogging(_ stored: StoredObservation) -> InstallationObservation? {
        do {
            return try decode(stored)
        } catch {
            logger.error("Beobachtung nicht lesbar: \(error.readableDescription, privacy: .public)")
            return nil
        }
    }
}
