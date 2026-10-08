import Foundation

/// Aktion im Bereich „Sicherheit“ – ausschließlich absichernd (Spec v2 §3), daher ohne Bestätigungsdialog.
public enum SecurityAction: String, Hashable, Sendable, CaseIterable {
    case enableFirewall, enableStealthMode, enableGatekeeper, enableAutomaticUpdates, updateXProtect, checkForUpdates

    /// Prüfung, an der die Wirkung zu sehen ist.
    public var checkKind: SecurityCheckKind {
        switch self {
        case .enableFirewall, .enableStealthMode: .firewall
        case .enableGatekeeper: .gatekeeper
        case .enableAutomaticUpdates: .automaticUpdates
        case .updateXProtect: .xprotect
        case .checkForUpdates: .pendingUpdates
        }
    }

    /// Helper-Operation; `nil` für „Jetzt suchen“, das als Nutzer läuft.
    public var hardening: SecurityHardening? {
        switch self {
        case .enableFirewall: .enableFirewall
        case .enableStealthMode: .enableStealthMode
        case .enableGatekeeper: .enableGatekeeper
        case .enableAutomaticUpdates: .enableAutomaticUpdates
        case .updateXProtect: .updateXProtect
        case .checkForUpdates: nil
        }
    }

    /// Ob die Aktion den Helper braucht (die Oberfläche sperrt sie, solange er nicht bereit ist).
    public var requiresHelper: Bool { hardening != nil }

    /// Ob die Aktion beim Beenden der App abgebrochen werden darf: nur die lesende Suche – ein abgebrochener Eingriff
    /// wäre schlechter als ein verspätetes Ende (`ActionCoordinator.drain()`).
    public var isCancellableWhenQuitting: Bool { self == .checkForUpdates }

    /// Seite der Systemeinstellungen, auf der sich die Wirkung prüfen oder von Hand nachholen lässt.
    public var settingsURL: URL? {
        switch self {
        case .enableFirewall, .enableStealthMode: SecuritySettingsLinks.firewall
        case .enableGatekeeper: SecuritySettingsLinks.privacyAndSecurity
        case .enableAutomaticUpdates, .checkForUpdates: SecuritySettingsLinks.softwareUpdate
        case .updateXProtect: nil
        }
    }
}

/// Führt Sicherheitsaktionen aus; in der App `SecurityActions`.
public protocol SecurityControlling: Sendable {
    func perform(_ action: SecurityAction) async throws
}

/// Seiten der Systemeinstellungen zum Sicherheitsstatus (Deeplinks in der Abnahme prüfen).
public enum SecuritySettingsLinks {
    public static let privacyAndSecurity = URL(string: "x-apple.systempreferences:com.apple.preference.security")
    public static let fileVault = URL(string: "x-apple.systempreferences:com.apple.preference.security?FileVault")
    public static let softwareUpdate = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")
    public static let firewall = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall")
}

/// Helper-Aktionen über `PrivilegedSecurityControlling`, „Jetzt suchen“ per `softwareupdate --list` als Nutzer
/// (braucht laut `man softwareupdate` als einziger Befehl keine Admin-Rechte).
///
/// Auch die Suche belegt über den `ActionRunner` den `HelperActivityLock`, obwohl sie den Helper nicht braucht. Das
/// bleibt so: Alle Aktionen laufen ohnehin nacheinander im `ActionCoordinator`, die Oberfläche kennt damit genau eine
/// laufende Aktion und ein Ergebnis, und eine Helper-Neuinstallation muss höchstens die Suche abwarten (bis
/// `searchTimeout`). Beim Beenden bricht `ActionCoordinator.drain()` die Suche ab (`isCancellableWhenQuitting`).
public struct SecurityActions: SecurityControlling {
    static let searchTimeout: Duration = .seconds(180)
    static let searchFailed = "Suche fehlgeschlagen – keine Verbindung"
    static let outdatedHelper = HelperClientError.outdatedMessage

    private let privileged: any PrivilegedSecurityControlling
    private let runner: any CommandRunning

    public init(privileged: any PrivilegedSecurityControlling, runner: any CommandRunning = ProcessCommandRunner()) {
        self.privileged = privileged
        self.runner = runner
    }

    /// Helper-Aktionen prüfen vorab die Protokollversion: Ein veralteter Helper kennt die Operation nicht und ließe den
    /// Aufruf bis zur Frist (bis zu einigen Minuten) hängen – stattdessen sofort `outdatedHelper`.
    ///
    /// - Throws: `ActionError.commandFailed` für Helper- und Suchfehler (Exit ≠ 0) und einen veralteten Helper,
    ///   `CancellationError` und Fehler beim Starten des Befehls unverändert.
    public func perform(_ action: SecurityAction) async throws {
        if let hardening = action.hardening {
            try await ActionError.translatingHelperErrors {
                guard try await privileged.protocolVersion() == HelperXPC.protocolVersion else {
                    throw ActionError.commandFailed(Self.outdatedHelper)
                }
                try await privileged.perform(hardening)
            }
        } else {
            try await checkForUpdates()
        }
    }

    /// Keine Antwort binnen `searchTimeout` wird wie fehlende Verbindung gemeldet, ohne Pfad des Befehls.
    private func checkForUpdates() async throws {
        let result: CommandResult
        do {
            result = try await runner.run(SecurityTools.softwareupdate, ["--list"], timeout: Self.searchTimeout)
        } catch CommandError.timedOut {
            throw ActionError.commandFailed(Self.searchFailed + " (keine Antwort nach \(Int(Self.searchTimeout.seconds) / 60) min)")
        }
        guard result.succeeded else {
            let detail = result.failureDetail
            throw ActionError.commandFailed(Self.searchFailed + (detail.isEmpty ? "" : " (\(detail))"))
        }
    }
}

/// Wirkungsprüfung der Sicherheitsaktionen am neuen Snapshot.
public enum SecurityActionVerification {
    static let notVisibleYet = "Die Änderung ist im neuen Scan noch nicht zu sehen."
    static let searchHappenedDespiteFailure = "Fehler gemeldet, die Suche ist aber erfolgt."

    /// Zielzustand erreicht? Eine fehlende oder nicht lesbare Prüfung (`unknown`, Fakten nur fortgeschrieben)
    /// bestätigt nichts.
    public static func isConfirmed(_ action: SecurityAction, in snapshot: Snapshot, startedAt: Date) -> Bool {
        reachesTarget(action, in: snapshot, startedAt: startedAt, acceptingUnchangedCurrentState: true)
    }

    /// Nach einem gemeldeten Fehler: Hat die Aktion trotzdem gewirkt? Strenger als `isConfirmed` – ein ohnehin
    /// aktuelles XProtect (grüne Ampel ohne neue Installation) ist keine Wirkung der gescheiterten Aktualisierung.
    public static func isEffectiveDespiteFailure(_ action: SecurityAction, in snapshot: Snapshot, startedAt: Date) -> Bool {
        reachesTarget(action, in: snapshot, startedAt: startedAt, acceptingUnchangedCurrentState: false)
    }

    /// Ergebnis, wenn ein Fehler gemeldet wurde, die Wirkung aber zu sehen ist.
    static func effectiveDespiteFailure(_ action: SecurityAction) -> String {
        action == .checkForUpdates ? searchHappenedDespiteFailure : ActionCoordinator.effectiveDespiteFailure
    }

    /// - Parameter acceptingUnchangedCurrentState: ob bei XProtect auch ein bereits aktuelles, nicht neu installiertes
    ///   Bundle zählt.
    private static func reachesTarget(
        _ action: SecurityAction, in snapshot: Snapshot, startedAt: Date, acceptingUnchangedCurrentState: Bool
    ) -> Bool {
        guard let check = snapshot.securityChecks.first(where: { $0.kind == action.checkKind }),
              check.state != .unknown, let facts = check.facts else { return false }
        switch (action, facts) {
        case (.enableFirewall, .firewall(let enabled, _)): return enabled
        case (.enableStealthMode, .firewall(_, let stealthMode)): return stealthMode
        case (.enableGatekeeper, .gatekeeper(let enabled)): return enabled
        case (.enableAutomaticUpdates, .automaticUpdates(let disabled)): return disabled.isEmpty
        // Neu installiert – oder es gab nichts Neueres und das vorhandene ist aktuell.
        case (.updateXProtect, .xprotect(_, let installedAt)):
            return installedAt >= startedAt || (acceptingUnchangedCurrentState && check.state == .good)
        case (.checkForUpdates, .pendingUpdates(_, let lastCheck)): return lastCheck.map { $0 >= startedAt } ?? false
        default: return false
        }
    }

    /// Ergebnis, wenn die Aktion lief, die Wirkung aber nicht zu sehen ist.
    public static func unconfirmed(_ action: SecurityAction) -> ActionOutcome {
        let reason = switch action {
        case .checkForUpdates: "Die Suche ist beendet, das Datum der letzten Suche hat sich aber nicht geändert."
        case .updateXProtect: "Es wurde keine neuere XProtect-Version installiert."
        case .enableFirewall, .enableStealthMode, .enableGatekeeper, .enableAutomaticUpdates: notVisibleYet
        }
        return .doneButUnverified(reason, settingsURL: action.settingsURL)
    }
}
