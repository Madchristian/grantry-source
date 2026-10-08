import Foundation

/// App-Bundles, die „App entfernen“ in den Papierkorb gelegt hat, bis ein danach begonnener Scan sie bestätigt.
///
/// Der Scan nach dem Entfernen kann dauern (Signaturprüfungen, ein nicht erreichbarer Helper); so lange verschwinden die
/// Apps schon aus der Anzeige (`applied(to:)`, über `PresentationInput`). Ein Snapshot, dessen Scan nach der Entfernung
/// begann (`Snapshot.takenAt`), gilt unverändert – auch, wenn die App inzwischen wieder installiert ist – und beendet
/// den Vermerk (`prune(confirmedBy:)`).
public struct TrashedApps: Equatable, Sendable {
    /// Zeitpunkt der Entfernung je Bundle-Pfad.
    private var removedAt: [String: Date] = [:]

    public init() {}

    public var isEmpty: Bool { removedAt.isEmpty }

    /// Vermerkt die erfolgreich in den Papierkorb gelegten App-Bundles des Berichts (auch mit Warnung).
    public mutating func record(_ report: RemovalReport, at date: Date) {
        for entry in report.entries where entry.result.isDone {
            guard case .file(let file) = entry.subject, file.kind == .appBundle else { continue }
            removedAt[file.path] = date
        }
    }

    /// Vergisst Entfernungen, die `snapshot` bereits berücksichtigt (sein Scan begann danach).
    public mutating func prune(confirmedBy snapshot: Snapshot) {
        removedAt = removedAt.filter { $0.value > snapshot.takenAt }
    }

    /// `snapshot` ohne die Apps, die nach dem Beginn seines Scans entfernt wurden.
    public func applied(to snapshot: Snapshot) -> Snapshot {
        guard !isEmpty else { return snapshot }
        var shown = snapshot
        shown.installedApps.removeAll { app in removedAt[app.path].map { $0 > snapshot.takenAt } ?? false }
        return shown
    }
}
