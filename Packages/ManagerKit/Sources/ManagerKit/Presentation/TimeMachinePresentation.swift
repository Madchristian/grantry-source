import Foundation

/// Texte der Time-Machine-Vorschläge im Segment „Speicher“ (#227): Status je Ordner und Kategorie, Sammeldialog und
/// Hinweis auf lokale Snapshots nach dem Aufräumen.
public enum TimeMachinePresentation {
    /// Kopierbarer Befehl samt Erklärung; Grantry führt ihn nie selbst aus (Snapshots: nur Bericht).
    public struct SnapshotNote: Hashable, Sendable {
        public let text: String
        public let command: String
    }

    public static func stateText(_ state: TimeMachineBackupState) -> String {
        switch state {
        case .included: "von Time Machine gesichert"
        case .excluded: "aus Time Machine ausgenommen"
        case .unknown: "Time-Machine-Status unbekannt"
        }
    }

    /// Merkmal einer Speicher-Kategorie: „Time Machine: gesichert“, „… ausgenommen“ oder „… teilweise gesichert“;
    /// `nil` ohne Vorschlag mit bekanntem Status.
    public static func categoryNote(_ categoryID: String, in suggestions: [TimeMachineSuggestion]) -> String? {
        let states = Set(suggestions.filter { $0.candidate.categoryID == categoryID && $0.state != .unknown }.map(\.state))
        guard !states.isEmpty else { return nil }
        if states.count > 1 { return "Time Machine: teilweise gesichert" }
        return states.contains(.excluded) ? "Time Machine: ausgenommen" : "Time Machine: gesichert"
    }

    /// Gewählte Vorschläge, die `change` tatsächlich ändert (ausnehmen: noch gesicherte, wieder sichern: ausgenommene).
    public static func targets(of change: TimeMachineChange, in suggestions: [TimeMachineSuggestion],
                               selection: Set<String>) -> [TimeMachineSuggestion] {
        let current: TimeMachineBackupState = change == .exclude ? .included : .excluded
        return suggestions.filter { selection.contains($0.id) && $0.state == current }
    }

    public static func confirmation(_ change: TimeMachineChange, targets: [TimeMachineSuggestion]) -> ActionConfirmation {
        let folders = targets.count == 1 ? "1 Ordner" : "\(targets.count) Ordner"
        let lines = targets.map { suggestion in
            "\(suggestion.candidate.title): \((suggestion.candidate.path as NSString).abbreviatingWithTildeInPath) – "
                + suggestion.sizeText
        }
        return switch change {
        case .exclude:
            ActionConfirmation(
                title: "\(folders) aus Time Machine ausnehmen?", message: lines.joined(separator: "\n"),
                note: """
                    Time Machine sichert diese Ordner danach nicht mehr; vorhandene Backups bleiben erhalten. \
                    „Wieder sichern“ hebt den Ausschluss auf.
                    """,
                confirmTitle: "Ausnehmen", isDestructive: false)
        case .include:
            ActionConfirmation(
                title: "\(folders) wieder sichern?", message: lines.joined(separator: "\n"),
                note: "Die nächste Sicherung nimmt diese Ordner wieder vollständig auf.",
                confirmTitle: "Wieder sichern", isDestructive: false)
        }
    }

    /// Nach dem Aufräumen: Gibt es lokale Snapshots (`TimeMachineSnapshotsProvider`), halten sie den endgültig
    /// freigegebenen Platz fest, bis macOS sie ausdünnt. Genannt wird diese Menge als Obergrenze – was davon schon vor
    /// dem letzten Snapshot bestand, ist ohne Administratorrechte nicht messbar. Papierkorb-Einträge zählen nicht, ihr
    /// Platz ist ohnehin noch belegt. `nil` ohne Snapshots oder ohne bekannte freigegebene Größe.
    public static func snapshotNote(after outcomes: [StorageCleanOutcome],
                                    reports: [StorageCategoryReport]) -> SnapshotNote? {
        let snapshots = reports.first { $0.id == TimeMachineSnapshotsProvider.categoryID }?.items.count ?? 0
        let freed = outcomes.filter { $0.result == .removed && ($0.method == .delete || $0.method == .command) }
            .compactMap(\.freedBytes).reduce(0, +)
        guard snapshots > 0, freed > 0 else { return nil }
        let holders = snapshots == 1 ? "1 lokaler Snapshot hält" : "\(snapshots) lokale Snapshots halten"
        return SnapshotNote(
            text: """
                \(holders) gelöschten Platz fest: bis zu \(AppTexts.formattedSize(freed)) werden erst frei, wenn macOS \
                Snapshots ausdünnt. Sofort freigeben im Terminal:
                """,
            command: "sudo tmutil thinlocalsnapshots / \(freed) 4")
    }
}
