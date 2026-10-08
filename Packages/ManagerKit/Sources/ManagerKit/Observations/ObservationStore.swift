import Foundation

/// Dauerhafte Ablage der Beobachtungen (#127). Invariante: höchstens eine laufende Beobachtung.
public protocol ObservationStore: Sendable {
    /// Die laufende Beobachtung; `nil`, wenn keine läuft.
    func activeObservation() async throws -> InstallationObservation?
    /// Alle Beobachtungen ohne Snapshots, neueste zuerst.
    func observationSummaries() async throws -> [ObservationSummary]
    func observation(id: UUID) async throws -> InstallationObservation?
    /// Speichert eine neue, laufende Beobachtung; scheitert mit `.alreadyActive`, wenn schon eine läuft.
    func startObservation(_ observation: InstallationObservation) async throws
    /// Beendet die laufende Beobachtung `id` mit dem Endstand `final` und liefert sie zurück.
    func finishObservation(id: UUID, final: Snapshot, at date: Date) async throws -> InstallationObservation
    /// Hängt ein Aufräum-Protokoll an.
    func appendCleanup(_ record: ObservationCleanupRecord, toObservation id: UUID) async throws
    func deleteObservation(id: UUID) async throws
}

/// Fehler der Beobachtungsablage, die nicht von der Datei herrühren.
public enum ObservationStoreError: LocalizedError, Equatable {
    case alreadyActive(name: String)
    case notFound
    case alreadyFinished

    public var errorDescription: String? {
        switch self {
        case .alreadyActive(let name): "Die Beobachtung „\(name)“ läuft bereits – es kann nur eine gleichzeitig laufen."
        case .notFound: "Die Beobachtung gibt es nicht mehr."
        case .alreadyFinished: "Die Beobachtung ist bereits beendet."
        }
    }
}
