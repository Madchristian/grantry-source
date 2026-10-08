import Foundation

/// Eine benannte Beobachtung einer Installation (#127): Ausgangsstand beim Start, Endstand beim Beenden und was daraus
/// später aufgeräumt wurde. Die Bilanz ergibt sich jederzeit aus beiden Ständen (`ObservationBalance`).
public struct InstallationObservation: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var note: String?
    public var startedAt: Date
    /// Eingefrorener Ausgangsstand – das Ergebnis des Scans beim Start.
    public var baseline: Snapshot
    /// `nil`, solange die Beobachtung läuft.
    public var finishedAt: Date?
    /// Endstand – das Ergebnis des abschließenden Scans; `nil`, solange die Beobachtung läuft.
    public var final: Snapshot?
    /// Aufräum-Durchgänge aus dieser Beobachtung, ältester zuerst.
    public var cleanups: [ObservationCleanupRecord]

    public init(
        id: UUID = UUID(), name: String, note: String? = nil, startedAt: Date, baseline: Snapshot, finishedAt: Date? = nil,
        final: Snapshot? = nil, cleanups: [ObservationCleanupRecord] = []
    ) {
        self.id = id
        self.name = name
        self.note = note
        self.startedAt = startedAt
        self.baseline = baseline
        self.finishedAt = finishedAt
        self.final = final
        self.cleanups = cleanups
    }

    public var isActive: Bool { finishedAt == nil }

    /// Bilanz zwischen Ausgangs- und Endstand; `nil`, solange die Beobachtung läuft.
    public var balance: ObservationBalance? {
        final.map { ObservationBalance(baseline: baseline, final: $0) }
    }
}

/// Listeneintrag einer gespeicherten Beobachtung – ohne die Snapshots.
public struct ObservationSummary: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let note: String?
    public let startedAt: Date
    public let finishedAt: Date?
    /// Zahl der neuen Einträge der Bilanz; `nil`, solange die Beobachtung läuft.
    public let addedCount: Int?
    /// Zahl der Aufräum-Durchgänge.
    public let cleanupCount: Int

    public init(
        id: UUID, name: String, note: String?, startedAt: Date, finishedAt: Date?, addedCount: Int?, cleanupCount: Int
    ) {
        self.id = id
        self.name = name
        self.note = note
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.addedCount = addedCount
        self.cleanupCount = cleanupCount
    }

    public var isActive: Bool { finishedAt == nil }
}

/// Ergebnis eines Aufräum-Durchgangs aus einer Beobachtung – als Protokoll gespeichert (`RemovalReport` selbst ist nicht
/// kodierbar und hält ganze Kandidaten).
public struct ObservationCleanupRecord: Hashable, Sendable, Codable {
    public struct Entry: Hashable, Sendable, Codable {
        /// „Bedienungshilfen-Berechtigung von Cursor“, „„com.example.agent““ bzw. Pfad mit `~`.
        public let title: String
        public let isDone: Bool
        /// Grund bzw. Warnung; `nil` bei vollem Erfolg.
        public let reason: String?

        public init(title: String, isDone: Bool, reason: String?) {
            self.title = title
            self.isDone = isDone
            self.reason = reason
        }
    }

    public let performedAt: Date
    public let entries: [Entry]

    public init(performedAt: Date, entries: [Entry]) {
        self.performedAt = performedAt
        self.entries = entries
    }

    /// Protokoll eines Berichts; Titel wie in der Ergebnismeldung (`RemovalReport.Subject.displayName`).
    public init(_ report: RemovalReport, performedAt: Date, home: String = NSHomeDirectory()) {
        self.init(performedAt: performedAt, entries: report.entries.map { entry in
            Entry(title: entry.subject.displayName(home: home), isDone: entry.result.isDone, reason: entry.result.reason)
        })
    }

    public var doneCount: Int { entries.count(where: \.isDone) }
}
