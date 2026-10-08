import Foundation

/// Ein gespeichertes Änderungsereignis (Wertetyp für UI und Benachrichtigungen).
public struct HistoryEvent: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let event: ChangeEvent
    public var isRead: Bool

    public init(id: UUID, event: ChangeEvent, isRead: Bool) {
        self.id = id
        self.event = event
        self.isRead = isRead
    }
}

/// Dauerhafte Ablage von Snapshots und Änderungen.
public protocol SnapshotStore: Sendable {
    func latestSnapshot() async throws -> Snapshot?
    /// Speichert den Snapshot (ersetzt den bisherigen „letzten“) und hängt die Events an.
    /// - Parameter checkedAt: neuer Prüfzeitpunkt; `nil` (Teilscan) behält den bisherigen, ohne bisherigen gilt
    ///   `takenAt`.
    func record(_ snapshot: Snapshot, events: [ChangeEvent], checkedAt: Date?) async throws -> [HistoryEvent]
    /// Äquivalenter Scan: ersetzt den gespeicherten Snapshot durch `snapshot` (gleicher Inhalt, aufgefrischte
    /// Sichtungszeiten der Lauscher), ohne Events; mit `checkedAt` auch den Prüfzeitpunkt. Ohne gespeicherten Snapshot
    /// geschieht nichts.
    func touch(_ snapshot: Snapshot, checkedAt: Date?) async throws
    func lastCheckedAt() async throws -> Date?
    /// Events, neueste zuerst (`detectedAt` absteigend, bei Gleichstand zuletzt gespeicherte zuerst). Mit `cursor`
    /// (dem letzten Event der vorigen Seite) folgt die nächste Seite lückenlos und ohne Dubletten; `limit <= 0` ergibt `[]`.
    func events(limit: Int, after cursor: HistoryEvent?) async throws -> [HistoryEvent]
    func unreadCount() async throws -> Int
    func markAllRead() async throws
    /// Löscht Events älter als `date`.
    func pruneEvents(olderThan date: Date) async throws
}

extension SnapshotStore {
    /// Speichert den Snapshot eines Vollscans; sein `takenAt` wird Prüfzeitpunkt.
    public func record(_ snapshot: Snapshot, events: [ChangeEvent]) async throws -> [HistoryEvent] {
        try await record(snapshot, events: events, checkedAt: snapshot.takenAt)
    }

    /// Erste Seite der Events (neueste zuerst).
    public func events(limit: Int) async throws -> [HistoryEvent] {
        try await events(limit: limit, after: nil)
    }
}

/// Fehler der Verlaufsablage.
public enum SnapshotStoreError: LocalizedError, Equatable {
    case storeUnavailable(path: String, underlying: String)
    case encodingFailed(underlying: String)
    case decodingFailed(underlying: String)

    public var errorDescription: String? {
        switch self {
        case .storeUnavailable(let path, let underlying):
            "Der Verlauf unter „\(path)“ konnte nicht geöffnet werden: \(underlying)"
        case .encodingFailed(let underlying):
            "Der Verlauf konnte nicht gespeichert werden: \(underlying)"
        case .decodingFailed(let underlying):
            "Der gespeicherte Verlauf ist nicht lesbar: \(underlying)"
        }
    }
}
