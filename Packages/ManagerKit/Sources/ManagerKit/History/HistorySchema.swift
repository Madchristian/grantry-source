import Foundation
import SwiftData

/// Version 1 des Verlaufs-Schemas. Künftige Versionen kommen als eigene `VersionedSchema` mit Migrationsstufe
/// in `HistoryMigrationPlan` hinzu.
enum HistorySchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [StoredSnapshot.self, StoredEvent.self] }

    /// Der zuletzt gespeicherte Snapshot (Invariante: höchstens ein Datensatz).
    @Model
    final class StoredSnapshot {
        var takenAt: Date
        var checkedAt: Date
        @Attribute(.externalStorage) var payload: Data

        init(takenAt: Date, checkedAt: Date, payload: Data) {
            self.takenAt = takenAt
            self.checkedAt = checkedAt
            self.payload = payload
        }
    }

    /// Ein gespeichertes `ChangeEvent`; `payload` ist dessen JSON, `subjectID` die ID des Gegenstands (für Filter),
    /// `sequence` eine streng steigende Einfügenummer als eindeutiger Gleichstandsbrecher beim Sortieren und Paging.
    @Model
    final class StoredEvent {
        #Index<StoredEvent>([\.detectedAt, \.sequence], [\.isRead])

        @Attribute(.unique) var id: UUID
        var sequence: Int
        var detectedAt: Date
        var kind: String
        var subjectID: String
        var isRead: Bool
        var payload: Data

        init(id: UUID, sequence: Int, detectedAt: Date, kind: String, subjectID: String, isRead: Bool, payload: Data) {
            self.id = id
            self.sequence = sequence
            self.detectedAt = detectedAt
            self.kind = kind
            self.subjectID = subjectID
            self.isRead = isRead
            self.payload = payload
        }
    }
}

/// Version 2: zusätzlich die Beobachtungen von Installationen (#127). Snapshot und Events bleiben unverändert.
enum HistorySchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [HistorySchemaV1.StoredSnapshot.self, HistorySchemaV1.StoredEvent.self, StoredObservation.self]
    }

    /// Eine Beobachtung; `baseline` und `final` sind Snapshot-JSON, `cleanups` das JSON der Aufräum-Protokolle.
    /// `addedCount` hält die Zahl neuer Einträge für die Liste fest, ohne die Snapshots zu lesen.
    @Model
    final class StoredObservation {
        #Index<StoredObservation>([\.startedAt], [\.finishedAt])

        @Attribute(.unique) var id: UUID
        var name: String
        var note: String?
        var startedAt: Date
        var finishedAt: Date?
        var addedCount: Int?
        var cleanupCount: Int
        @Attribute(.externalStorage) var baseline: Data
        @Attribute(.externalStorage) var final: Data?
        var cleanups: Data

        init(id: UUID, name: String, note: String?, startedAt: Date, baseline: Data, cleanups: Data) {
            self.id = id
            self.name = name
            self.note = note
            self.startedAt = startedAt
            finishedAt = nil
            addedCount = nil
            cleanupCount = 0
            self.baseline = baseline
            final = nil
            self.cleanups = cleanups
        }
    }
}

/// Migrationsplan des Verlaufs: V1 → V2 fügt nur eine Entität hinzu (leichte Migration).
enum HistoryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [HistorySchemaV1.self, HistorySchemaV2.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: HistorySchemaV1.self, toVersion: HistorySchemaV2.self)]
    }
}

/// Aktuelle Schema-Version.
typealias HistorySchema = HistorySchemaV2
typealias StoredSnapshot = HistorySchemaV1.StoredSnapshot
typealias StoredEvent = HistorySchemaV1.StoredEvent
typealias StoredObservation = HistorySchemaV2.StoredObservation
