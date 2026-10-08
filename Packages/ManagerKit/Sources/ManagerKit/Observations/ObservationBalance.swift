import Foundation

/// Bilanz einer Beobachtung (#127): alle Änderungen zwischen Ausgangs- und Endstand, nach Art gruppiert. Reine Funktion
/// über `SnapshotDiffer` – dessen Baseline-Regeln gelten unverändert (eine erst während der Beobachtung liefernde Quelle
/// erzeugt keine „neu“-Einträge, siehe `firstDeliveredSources`). Neue Quellen (weitere `ChangeSubject`-Fälle) sind
/// automatisch enthalten; was keiner bekannten Art angehört, steht unter `.other`.
public struct ObservationBalance: Hashable, Sendable {
    /// Abschnitte der Bilanz in Anzeigereihenfolge.
    public enum Group: Int, Hashable, Sendable, CaseIterable, Comparable {
        case newGrants, newAutostartItems, newApps, newOther, modified, securityChanges, removed

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let events: [ChangeEvent]
    /// Quellen, die beim Start oder beim Ende nicht lesbar waren.
    public let failedSources: Set<SourceID>
    /// Quellen, die erst während der Beobachtung zum ersten Mal geliefert haben – ihre Einträge zählen zum Ausgangsstand.
    public let firstDeliveredSources: Set<SourceID>
    /// Einschränkungen beim Start oder beim Ende (`Snapshot.sourceLimitations`), etwa nicht auswertbare Plists (#139):
    /// Die Quelle hat geliefert, aber nicht alles – was dort passiert ist, fehlt in der Bilanz. Ohne Dubletten, in der
    /// Reihenfolge des Auftretens.
    public let limitations: [SourceLimitation]

    public init(baseline: Snapshot, final: Snapshot, differ: SnapshotDiffer = SnapshotDiffer()) {
        events = differ.diff(from: baseline, to: final)
        failedSources = baseline.failedSources.union(final.failedSources)
        firstDeliveredSources = final.baselineSources.subtracting(baseline.baselineSources)
        var seen = Set<SourceLimitation>()
        limitations = (baseline.sourceLimitations + final.sourceLimitations).filter { seen.insert($0).inserted }
    }

    /// `true`, wenn Start und Ende alle Quellen vollständig gelesen haben. Sonst ist eine leere Bilanz keine Entwarnung.
    public var isComplete: Bool { failedSources.isEmpty && limitations.isEmpty }

    /// Ereignisse je Abschnitt; leere Abschnitte fehlen.
    public var groups: [Group: [ChangeEvent]] {
        Dictionary(grouping: events, by: Self.group)
    }

    /// Neu hinzugekommene Einträge – die Kandidaten fürs Aufräumen.
    public var added: [ChangeEvent] { events.filter { $0.kind == .added } }
    public var addedCount: Int { added.count }

    /// Neu installierte Apps – Grundlage der Zuordnung (`ObservationAttribution`).
    public var newApps: [InstalledApp] {
        added.compactMap { event in
            if case .installedApp(let app) = event.subject { app } else { nil }
        }
    }

    /// Abschnitt eines Ereignisses. Geänderte Sicherheitsprüfungen stehen immer für sich (deutlicher Hinweis).
    public static func group(of event: ChangeEvent) -> Group {
        if case .securityCheck = event.subject { return .securityChanges }
        switch event.kind {
        case .removed: return .removed
        case .modified: return .modified
        case .added: return addedGroup(of: event.subject)
        }
    }

    /// Gegenstände künftiger Quellen (#128, #129) fallen unter `.newOther` statt die Bilanz zu brechen – deshalb keine
    /// erschöpfende `switch`-Anweisung.
    private static func addedGroup(of subject: ChangeSubject) -> Group {
        if case .grant = subject { return .newGrants }
        if case .autostartItem = subject { return .newAutostartItems }
        if case .installedApp = subject { return .newApps }
        return .newOther
    }
}
