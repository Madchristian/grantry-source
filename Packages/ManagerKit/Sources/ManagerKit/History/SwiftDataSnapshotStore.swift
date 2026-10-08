import CoreData
import Foundation
import GrantryShared
import OSLog
import SwiftData

/// `SnapshotStore` auf Basis von SwiftData. `@Model`-Objekte verlassen den Actor nie; nach außen gehen nur Wertetypen.
@ModelActor
public actor SwiftDataSnapshotStore: SnapshotStore {
    static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "history")

    /// Öffnet (oder erstellt) die Ablage in der Datei `url`.
    public init(url: URL) throws {
        self.init(modelContainer: try Self.makeContainer(url: url))
    }

    /// Flüchtige Ablage im Speicher (Tests, Vorschauen).
    public static func inMemory() throws -> SwiftDataSnapshotStore {
        do {
            return SwiftDataSnapshotStore(modelContainer: try container(ModelConfiguration(isStoredInMemoryOnly: true)))
        } catch {
            throw unavailable(path: ":memory:", error)
        }
    }

    /// Ablage der App in `location` (Standard: `~/Library/Application Support/Grantry/History.store`); eine
    /// unlesbare Datei wird beiseitegelegt und durch eine frische ersetzt (siehe `openRecovering(url:)`).
    ///
    /// Privat (#141): Der Ablageort wird privat geöffnet und vorhandene Dateien gehärtet (`StorageLocation.openPrivately`),
    /// bevor SwiftData etwas öffnet; eine neue Datenbank entsteht vorab leer mit `0600`, `-wal`/`-shm` erben das von
    /// SQLite. Nach dem Öffnen wird nur noch der Ordner externer Daten verschärft – die SQLite-Dateien selbst nicht mehr,
    /// das Schließen eines eigenen Deskriptors gäbe SQLites Sperren frei (siehe `PrivateDirectory`). Später entstehende
    /// Dateien liegen im `0700`-Ordner.
    public static func live(in location: StorageLocation = .standard) throws -> SwiftDataSnapshotStore {
        let url = location.historyStoreURL
        let storage: PrivateDirectory
        do {
            storage = try location.openPrivately()
        } catch {
            throw SnapshotStoreError.storeUnavailable(path: location.directory.path, underlying: error.readableDescription)
        }
        let store = try openRecovering(url: url) {
            do {
                try storage.createFileIfMissing(url.lastPathComponent)
            } catch {
                throw SnapshotStoreError.storeUnavailable(path: url.path, underlying: error.readableDescription)
            }
        }
        storage.harden([supportDirectoryName(of: url)])
        return store
    }

    /// Namen aller Dateien der Ablage `url` in ihrem Ordner: Datenbank, `-wal`, `-shm` und der Ordner externer Daten.
    static func storeFileNames(of url: URL) -> [String] {
        let name = url.lastPathComponent
        return [name, "\(name)-wal", "\(name)-shm", supportDirectoryName(of: url)]
    }

    /// Ordner, in dem SwiftData externe Daten (`@Attribute(.externalStorage)`) neben `url` ablegt.
    static func supportDirectoryName(of url: URL) -> String {
        ".\(url.deletingPathExtension().lastPathComponent)_SUPPORT"
    }

    /// Öffnet die Ablage in `url`. Zeigt der Fehler eine unbrauchbare Datei an (kein SQLite-Format, beschädigt,
    /// inkompatibles Schema, gescheiterte Migration – siehe `StoreOpenFailure`), werden die Store-Dateien mit
    /// Zeitstempel-Suffix beiseitegelegt und eine frische Ablage angelegt: Der Verlauf beginnt dann mit einer neuen
    /// Baseline. Andere Fehler (Rechte, Platz, Sperre, fehlendes Verzeichnis) werden weitergereicht, die Datei bleibt
    /// unangetastet. Lässt sich der Fehler nicht einordnen, gilt die Datei als unbrauchbar.
    ///
    /// `prepare` läuft vor jedem Öffnen, auch vor dem der frischen Ablage (`live(in:)` legt damit die Datei privat an).
    static func openRecovering(url: URL, preparing prepare: () throws -> Void = {}) throws -> SwiftDataSnapshotStore {
        do {
            try prepare()
            return SwiftDataSnapshotStore(modelContainer: try container(ModelConfiguration(url: url)))
        } catch let error as SnapshotStoreError {
            throw error
        } catch {
            let failure = StoreOpenFailure(error)
            guard failure != .environmental else { throw unavailable(path: url.path, error) }
            logger.error("Verlauf nicht lesbar, wird neu angelegt: \(Self.description(of: error), privacy: .public)")
            try moveStoreFilesAside(of: url)
            try prepare()
            return try SwiftDataSnapshotStore(url: url)
        }
    }

    static func makeContainer(url: URL) throws -> ModelContainer {
        do {
            return try container(ModelConfiguration(url: url))
        } catch {
            throw unavailable(path: url.path, error)
        }
    }

    /// Fehler kommen unverpackt von SwiftData, damit `StoreOpenFailure` sie einordnen kann.
    private static func container(_ configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: HistorySchema.self),
            migrationPlan: HistoryMigrationPlan.self,
            configurations: [configuration]
        )
    }

    private static func unavailable(path: String, _ error: any Error) -> SnapshotStoreError {
        .storeUnavailable(path: path, underlying: description(of: error))
    }

    /// Beschreibung des CoreData-Fehlers hinter einem `SwiftDataError`, der selbst nur „error 1“ sagt.
    private static func description(of error: any Error) -> String {
        (StoreOpenFailure.cocoaError(in: error) ?? error).readableDescription
    }

    /// Verschiebt `History.store`, `-wal`, `-shm` und das Verzeichnis für externe Daten nach `<Name>.defekt-<Zeitstempel>`.
    private static func moveStoreFilesAside(of url: URL) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        let suffix = ".defekt-\(Int(Date.now.timeIntervalSince1970))"
        for fileName in storeFileNames(of: url) {
            let file = directory.appending(path: fileName)
            guard fileManager.fileExists(atPath: file.path) else { continue }
            do {
                try fileManager.moveItem(at: file, to: directory.appending(path: fileName + suffix))
            } catch {
                throw SnapshotStoreError.storeUnavailable(path: url.path, underlying: error.readableDescription)
            }
        }
    }

    // MARK: SnapshotStore

    /// Ein unlesbarer Snapshot gilt als nicht vorhanden: Der nächste Scan wird dann Baseline, ohne Events.
    public func latestSnapshot() throws -> Snapshot? {
        guard let stored = try snapshotsNewestFirst().first else { return nil }
        do {
            return try Self.decode(Snapshot.self, from: stored.payload)
        } catch {
            Self.logger.error("Letzter Snapshot nicht lesbar, wird verworfen: \(error.readableDescription, privacy: .public)")
            return nil
        }
    }

    public func record(_ snapshot: Snapshot, events: [ChangeEvent], checkedAt: Date?) throws -> [HistoryEvent] {
        try transaction {
            let payload = try Self.encode(snapshot)
            let rows = try snapshotsNewestFirst()
            if let newest = rows.first {
                newest.takenAt = snapshot.takenAt
                newest.checkedAt = checkedAt ?? newest.checkedAt
                newest.payload = payload
                rows.dropFirst().forEach(modelContext.delete)
            } else {
                modelContext.insert(StoredSnapshot(takenAt: snapshot.takenAt, checkedAt: checkedAt ?? snapshot.takenAt,
                                                   payload: payload))
            }
            let recorded = events.map { HistoryEvent(id: UUID(), event: $0, isRead: false) }
            let firstSequence = try nextSequence()
            for (offset, historyEvent) in recorded.enumerated() {
                modelContext.insert(try Self.storedEvent(from: historyEvent, sequence: firstSequence + offset))
            }
            return recorded
        }
    }

    public func touch(_ snapshot: Snapshot, checkedAt: Date?) throws {
        try transaction {
            guard let newest = try snapshotsNewestFirst().first else { return }
            newest.payload = try Self.encode(snapshot)
            newest.takenAt = snapshot.takenAt
            if let checkedAt { newest.checkedAt = checkedAt }
        }
    }

    public func lastCheckedAt() throws -> Date? {
        try snapshotsNewestFirst().first?.checkedAt
    }

    public func events(limit: Int, after cursor: HistoryEvent?) throws -> [HistoryEvent] {
        guard limit > 0 else { return [] }
        var descriptor = FetchDescriptor<StoredEvent>(sortBy: [
            SortDescriptor(\.detectedAt, order: .reverse), SortDescriptor(\.sequence, order: .reverse),
        ])
        if let cursor {
            let (date, sequence) = try position(of: cursor)
            descriptor.predicate = #Predicate {
                $0.detectedAt < date || ($0.detectedAt == date && $0.sequence < sequence)
            }
        }
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map { stored in
            HistoryEvent(id: stored.id, event: try Self.decode(ChangeEvent.self, from: stored.payload), isRead: stored.isRead)
        }
    }

    public func unreadCount() throws -> Int {
        try modelContext.fetchCount(Self.unreadEvents)
    }

    public func markAllRead() throws {
        try transaction {
            for stored in try modelContext.fetch(Self.unreadEvents) {
                stored.isRead = true
            }
        }
    }

    public func pruneEvents(olderThan date: Date) throws {
        try transaction {
            try modelContext.delete(model: StoredEvent.self, where: #Predicate { $0.detectedAt < date })
        }
    }

    // MARK: Intern

    /// Anzahl der Snapshot-Datensätze (Invariante: höchstens einer).
    func storedSnapshotCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<StoredSnapshot>())
    }

    /// Führt `body` aus und speichert; bei jedem Fehler werden die ungespeicherten Änderungen verworfen.
    func transaction<Result>(_ body: () throws -> Result) throws -> Result {
        do {
            let result = try body()
            try modelContext.save()
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func snapshotsNewestFirst() throws -> [StoredSnapshot] {
        try modelContext.fetch(FetchDescriptor<StoredSnapshot>(sortBy: [SortDescriptor(\.takenAt, order: .reverse)]))
    }

    private func nextSequence() throws -> Int {
        var descriptor = FetchDescriptor<StoredEvent>(sortBy: [SortDescriptor(\.sequence, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try modelContext.fetch(descriptor).first?.sequence ?? 0) + 1
    }

    /// Sortierposition des Cursors. Ist das Event inzwischen gelöscht, geht es mit echt älteren Events weiter.
    private func position(of cursor: HistoryEvent) throws -> (Date, Int) {
        let id = cursor.id
        var descriptor = FetchDescriptor<StoredEvent>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let stored = try modelContext.fetch(descriptor).first else { return (cursor.event.detectedAt, Int.min) }
        return (stored.detectedAt, stored.sequence)
    }

    private static var unreadEvents: FetchDescriptor<StoredEvent> {
        FetchDescriptor(predicate: #Predicate { !$0.isRead })
    }

    private static func storedEvent(from historyEvent: HistoryEvent, sequence: Int) throws -> StoredEvent {
        let event = historyEvent.event
        return StoredEvent(
            id: historyEvent.id, sequence: sequence, detectedAt: event.detectedAt, kind: event.kind.rawValue,
            subjectID: event.subject.recordID, isRead: historyEvent.isRead, payload: try encode(event)
        )
    }

    // Standard-Strategien (Datum als Sekunden-Double) statt ISO 8601: verlustfrei, auch für Sekundenbruchteile.
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw SnapshotStoreError.encodingFailed(underlying: error.readableDescription)
        }
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw SnapshotStoreError.decodingFailed(underlying: error.readableDescription)
        }
    }
}

/// Einordnung eines Fehlers beim Öffnen der Ablage: Nur bei `.corruptOrIncompatible` darf `openRecovering(url:)`
/// die Datei beiseitelegen.
///
/// SwiftData verpackt den CoreData-Fehler in `SwiftDataError`, ohne ihn öffentlich zugänglich zu machen (auch die
/// `NSError`-Brücke sagt nur „error 1“); er wird deshalb per Reflexion aus dem Feld `_underlyingCocoaError` gelesen.
/// Fehlt das Feld (künftiges SDK), ist der Fehler `.unclassifiable`.
enum StoreOpenFailure: Equatable {
    /// Kein SQLite-Format, beschädigt, inkompatibles Schema oder gescheiterte Migration.
    case corruptOrIncompatible
    /// Rechte, Platz, Sperre, fehlendes Verzeichnis – die Datei selbst ist womöglich in Ordnung.
    case environmental
    case unclassifiable

    /// CoreData-Codes, die eine unbrauchbare Datei anzeigen.
    private static let corruptionCodes: Set<CocoaError.Code> = [
        .fileReadCorruptFile, .persistentStoreInvalidType, .persistentStoreTypeMismatch,
        .persistentStoreIncompatibleSchema, .persistentStoreIncompatibleVersionHash, .migration,
        CocoaError.Code(rawValue: NSMigrationConstraintViolationError), .migrationCancelled,
        .migrationMissingSourceModel, .migrationMissingMappingModel, .migrationManagerSourceStore,
        .migrationManagerDestinationStore, .entityMigrationPolicy, .inferredMappingModel,
    ]

    /// SQLite-Ergebniscodes (`NSSQLiteErrorDomain` im `userInfo`), die eine unbrauchbare Datei anzeigen:
    /// `SQLITE_CORRUPT` (11) und `SQLITE_NOTADB` (26).
    private static let corruptSQLiteCodes: Set<Int> = [11, 26]

    init(_ error: any Error) {
        guard let cocoa = Self.cocoaError(in: error) else {
            self = .unclassifiable
            return
        }
        let sqliteCode = cocoa.userInfo["NSSQLiteErrorDomain"] as? Int
        if Self.corruptionCodes.contains(cocoa.code) || sqliteCode.map(Self.corruptSQLiteCodes.contains) == true {
            self = .corruptOrIncompatible
        } else {
            self = .environmental
        }
    }

    /// Der `CocoaError` selbst oder der hinter einem `SwiftDataError`; `nil`, wenn keiner erreichbar ist.
    static func cocoaError(in error: any Error) -> CocoaError? {
        if let cocoa = error as? CocoaError { return cocoa }
        return Mirror(reflecting: error).children
            .first { $0.label == "_underlyingCocoaError" }
            .flatMap { $0.value as? CocoaError }
    }
}
