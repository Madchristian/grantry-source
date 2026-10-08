import Foundation

/// Baseline für Lauscher anderer Benutzer, wenn der Helper erst später liefert.
///
/// `SnapshotDiffer` kennt die Baseline nur je Quelle. Die Lauscher-Quelle liefert aber auch ohne Helper – dann nur
/// eigene Prozesse, mit einer `SourceLimitation` (`NetworkListenerSource`). War der Helper beim ersten Scan nach dem
/// Update nicht verfügbar (Registrierung wartet auf Genehmigung, nie eingerichtet, erste Abfrage gescheitert), wird
/// dieser Ausschnitt zur Baseline. Liefert der Helper danach erstmals vollständig, erschienen sonst alle Lauscher von
/// root und anderen Benutzern als „Neuer Netzwerkdienst“ – eine Flut in Verlauf und Benachrichtigungen.
///
/// Deshalb gilt: Die **erste** vollständige Lieferung überhaupt ist Baseline für fremde Benutzer. Ihre `.added`-Events
/// entfallen; eigene Lauscher, Entfernungen und Änderungen bleiben unberührt. Ob es die erste ist, hält der Snapshot
/// dauerhaft fest (`Snapshot.hasCompleteListenerBaseline`, vom `ScanCoordinator` gesetzt und über eingeschränkte wie
/// gescheiterte Scans fortgeschrieben): Nach einem späteren Helper-Ausfall kennt der Vorgänger alle fremden Lauscher
/// bereits (fortgeschrieben), und ein in der Lücke entstandener Dienst wird als neu gemeldet – statt bei jedem Ausfall
/// erneut still übernommen zu werden.
///
/// Bewusste Grenze: Ein fremder Dienst, der genau während der allerersten Helper-Lücke neu entstand, wird still
/// übernommen – er ist danach in der Liste sichtbar, aber nicht als neu gemeldet.
enum NetworkListenerBaseline {
    /// - Parameters:
    ///   - events: Ergebnis von `SnapshotDiffer.diff(from: previous, to: current)`.
    ///   - currentUID: Benutzer der App; Lauscher mit anderer `uid` gelten als fremd.
    /// - Returns: `events` ohne `.added` fremder Lauscher, wenn `current` die erste vollständige Lieferung ist
    ///   (`previous` ohne, `current` mit vollständiger Baseline); sonst unverändert.
    static func filtering(
        _ events: [ChangeEvent], previous: Snapshot?, current: Snapshot, currentUID: UInt32 = getuid()
    ) -> [ChangeEvent] {
        guard let previous, !previous.hasCompleteListenerBaseline, current.hasCompleteListenerBaseline else {
            return events
        }
        return events.filter { event in
            guard event.kind == .added, case .networkListener(let listener)? = event.after else { return true }
            return listener.uid == currentUID
        }
    }
}
