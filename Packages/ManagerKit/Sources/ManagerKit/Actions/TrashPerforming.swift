import Foundation

/// Ob Grantry den Finder steuern darf (Automation).
public enum TrashPermission: Hashable, Sendable {
    case granted
    /// `errAEEventNotPermitted`: in Datenschutz & Sicherheit → Automation nicht erlaubt.
    case denied
    /// Nicht prüfbar (Finder läuft nicht, anderer Fehler); lesbarer Grund.
    case unavailable(String)

    /// Datenschutz & Sicherheit → Automation: dort erteilt der Nutzer die fehlende Freigabe (Spec v3 §4).
    public static let settingsURL = PermissionCatalog.service(for: PermissionCatalog.automationServiceID).settingsURL
}

/// Ergebnis je Pfad nach dem Apple Event.
public enum TrashItemOutcome: Hashable, Sendable {
    /// Der Pfad existiert nicht mehr – das Original liegt im Papierkorb (nachgewiesen, soweit sein Ort ermittelbar ist;
    /// `FinderTrash`, #104).
    case trashed
    /// Das Original liegt im Papierkorb (nachgewiesen wie bei `.trashed`), am Pfad liegt aber inzwischen ein neu
    /// angelegter Eintrag (anderes Objekt).
    case recreated
    /// Nicht im Papierkorb: Der Pfad existiert noch (dasselbe Objekt; Fehler des Events oder „noch vorhanden“), oder
    /// das Original liegt nachweislich anderswo bzw. nirgends mehr (#104). Grund als Text.
    case remaining(String)
    /// Nicht an den Finder gegangen: Die letzte Prüfung unmittelbar vor dem Event schlug fehl (Grund).
    case blocked(String)
}

public struct TrashReport: Hashable, Sendable {
    public var outcomes: [String: TrashItemOutcome]
    /// Fehler des Apple Events als Text; `nil` bei Erfolg.
    public var failure: String?

    public init(outcomes: [String: TrashItemOutcome], failure: String?) {
        self.outcomes = outcomes
        self.failure = failure
    }
}

/// Legt Dateien in den Papierkorb (Spec v3 §4); in der App `FinderTrash`.
public protocol TrashPerforming: Sendable {
    /// Prüft – und erfragt bei Bedarf über macOS – die Automation-Freigabe für den Finder.
    func requestPermission() async -> TrashPermission
    /// Legt alle `candidates` mit **einem** Apple Event in den Papierkorb. `verify` prüft jeden Kandidaten unmittelbar
    /// vor dem Senden (im selben Ablauf, der das Event sendet – Review N2); abgelehnte gehen nicht mit (`.blocked`).
    /// Danach wird je Pfad geprüft, ob er noch existiert und ob es noch das Original ist (`TrashItemOutcome`).
    func moveToTrash(
        _ candidates: [LeftoverCandidate], verifying verify: @escaping @Sendable (LeftoverCandidate) -> RemovalVerdict
    ) async -> TrashReport
    /// Abgleich ohne Auftrag (#143): `.trashed` bzw. `.recreated`, wenn das bestätigte Original (`candidate.identity`)
    /// nachweislich schon im Papierkorb liegt – etwa weil ein Finder-Auftrag nach seiner Zeitüberschreitung doch noch
    /// endete; sonst `nil` (offen). Ein Ersatzobjekt am Pfad bleibt unangetastet.
    func settledOutcome(of candidate: LeftoverCandidate) -> TrashItemOutcome?
    /// Merkt sich die Originale, solange die App sie noch erreicht (#143) – damit `settledOutcome` sie auch dann im
    /// Papierkorb findet, wenn die App ihn später nicht mehr lesen darf (`TrackedFileLocator`).
    func track(_ candidates: [LeftoverCandidate])
}

extension TrashPerforming {
    /// Ohne Nachweis gilt nichts als schon entsorgt.
    public func settledOutcome(of candidate: LeftoverCandidate) -> TrashItemOutcome? { nil }
    public func track(_ candidates: [LeftoverCandidate]) {}
}

/// Vorgabe des `ActionCoordinator`: löscht nie (Tests, fehlende Anbindung).
public struct UnavailableTrash: TrashPerforming {
    public static let reason = "Papierkorb ist nicht angebunden."

    public init() {}

    public func requestPermission() async -> TrashPermission { .unavailable(Self.reason) }

    public func moveToTrash(
        _ candidates: [LeftoverCandidate], verifying verify: @escaping @Sendable (LeftoverCandidate) -> RemovalVerdict
    ) async -> TrashReport {
        TrashReport(outcomes: Dictionary(candidates.map { ($0.path, .remaining(Self.reason)) }) { first, _ in first },
                    failure: Self.reason)
    }
}
