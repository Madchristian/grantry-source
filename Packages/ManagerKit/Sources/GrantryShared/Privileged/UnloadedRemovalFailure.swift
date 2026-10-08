import Foundation

/// Entfernen einer launchd-Plist ist gescheitert, **nachdem** ihr Dienst bereits entladen war (#166) – etwa weil ein
/// Updater die Plist während des `bootout` ersetzt hat. Gelöscht wurde nichts; die Plist am Pfad blieb unberührt, die
/// Sicherung der vorgefundenen Fassung bleibt als Beleg. Als Rollback wurde der Dienst wieder geladen (`ServiceReload`,
/// nur wenn am Pfad noch genau die entladenen Bytes liegen) – oder nicht (`reloadFailure`, etwa weil die Plist ersetzt
/// wurde), dann bleibt er gestoppt.
///
/// Helper (LaunchDaemons) und App (LaunchAgents in `gui/<uid>`) melden denselben Fall mit derselben Meldung.
public struct UnloadedRemovalFailure: LocalizedError, Equatable, Sendable {
    /// Plist, deren Entfernen gescheitert ist.
    public let path: String
    /// Grund, aus dem das Entfernen gescheitert ist (lesbare Meldung).
    public let reason: String
    /// `nil`: Dienst wieder geladen (oder bereits wieder geladen vorgefunden); sonst der Grund, warum nicht.
    public let reloadFailure: String?

    public init(path: String, reason: String, reloadFailure: String?) {
        self.path = path
        self.reason = reason
        self.reloadFailure = reloadFailure
    }

    public var errorDescription: String? {
        guard let reloadFailure else {
            return "Entfernen abgebrochen, der Dienst wurde wieder geladen – \(reason)"
        }
        return "Entfernen abgebrochen, der Dienst ist entladen und ließ sich nicht wieder laden (\(reloadFailure)) – "
            + "bitte neu scannen und den Dienst prüfen. \(reason)"
    }

    /// Rollback nach einem gescheiterten Entfernen: führt `reload` aus und liefert den passenden Fehler – mit
    /// `reloadFailure`, wenn auch das Laden scheitert. `CancellationError` aus `reload` zählt als gescheitertes Laden.
    public static func rollingBack(
        _ path: String, after failure: any Error, reload: () async throws -> Void
    ) async -> UnloadedRemovalFailure {
        do {
            try await reload()
            return UnloadedRemovalFailure(path: path, reason: failure.readableDescription, reloadFailure: nil)
        } catch {
            return UnloadedRemovalFailure(path: path, reason: failure.readableDescription, reloadFailure: error.readableDescription)
        }
    }
}

/// Entfernen nach einem `bootout` mit **unbekanntem** Ausgang (#166): Der Helper-Auftrag kann trotz Zeitüberschreitung
/// oder Verbindungsabbruch noch laufen und die Plist später löschen. Dann wird nichts wieder geladen – ein Rollback
/// liefe gegen einen womöglich noch arbeitenden Auftrag.
public struct UnloadedRemovalOutcomeUnknown: LocalizedError, Equatable, Sendable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }

    public var errorDescription: String? {
        "Der Dienst wurde entladen, das Ergebnis des Entfernens ist unbekannt (\(reason)) – nichts wieder geladen, "
            + "bitte neu scannen: \(path)"
    }
}

/// Warum ein entladener Dienst beim Rollback (#166) nicht wieder geladen wurde.
public enum ServiceReloadError: LocalizedError, Equatable, Sendable {
    /// Am Pfad liegen nicht mehr genau die Bytes der entladenen Konfiguration; geladen wird nichts.
    case plistReplaced
    /// Unter dem Label ist inzwischen ein Dienst aus einer anderen Plist geladen.
    case conflictingService(String)
    /// Nach dem `bootstrap` meldet launchd den Dienst nicht als aus dieser Plist geladen.
    case notReloaded(String)

    public var errorDescription: String? {
        switch self {
        case .plistReplaced: "die Plist wurde inzwischen ersetzt und wird nicht geladen"
        case .conflictingService(let label): "unter \(label) ist inzwischen ein Dienst aus einer anderen Plist geladen"
        case .notReloaded(let label): "launchd meldet \(label) danach nicht als aus dieser Plist geladen"
        }
    }
}

/// Rollback eines entladenen Dienstes (#166) – gemeinsam für Helper (`system`) und App (`gui/<uid>`).
///
/// Wieder geladen wird **nur genau die entladene Konfiguration**: Die Bytes am Pfad müssen exakt die vor dem `bootout`
/// geprüften (gescannten bzw. gesicherten) sein – geprüft vor der launchd-Abfrage, unmittelbar vor dem `bootstrap` und
/// danach, jeweils über den Pfad, den `bootstrap` erhält (dasselbe Verzeichnisobjekt, keine Symlinks, siehe
/// `BoundPlistContents.isUnchanged()`). Eine Ersatzkonfiguration – auch mit gleichem Label – lädt der Rollback nie; sie zu laden ist Sache des
/// Updaters (`ServiceReloadError.plistReplaced`, „bitte neu scannen“). Erfolg zählt erst, wenn launchd den Dienst danach
/// unter seinem Label als aus dieser Plist geladen meldet.
///
/// - Note: `launchctl bootstrap` nimmt nur einen Pfad, keinen Deskriptor. Zwischen der letzten Prüfung und dem Lesen
///   durch launchd bleibt deshalb ein Fenster von einem Prozessstart; schreibt in genau diesem Moment jemand die Plist
///   um (bei `system` und `/Library/LaunchAgents` nur root, bei `~/Library/LaunchAgents` der Benutzer selbst), fällt das
///   der Prüfung nach dem `bootstrap` auf und wird als `plistReplaced` gemeldet – geladen ist es dann allerdings.
public enum ServiceReload {
    /// - Parameters:
    ///   - label: Label des entladenen Dienstes.
    ///   - isUnchanged: ob am Pfad noch genau die Bytes der entladenen Konfiguration liegen.
    ///   - binding: fragt launchd, ob unter `label` genau diese Plist geladen ist.
    ///   - bootstrap: lädt die Plist am Pfad.
    public static func reload(
        label: String,
        isUnchanged: () throws -> Bool,
        binding: () async throws -> LaunchdServiceBinding,
        bootstrap: () async throws -> Void
    ) async throws {
        func ensureUnchanged() throws { guard try isUnchanged() else { throw ServiceReloadError.plistReplaced } }
        try ensureUnchanged()
        switch try await binding() {
        case .loadedFromPlist: return
        case .loadedFromElsewhere: throw ServiceReloadError.conflictingService(label)
        case .notLoaded: break
        }
        try ensureUnchanged()
        try await bootstrap()
        try ensureUnchanged()
        guard try await binding() == .loadedFromPlist else { throw ServiceReloadError.notReloaded(label) }
    }
}
