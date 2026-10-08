import Foundation

/// Beleg einer Entfernung; genügt zum Wiederherstellen. `Codable`, damit der Verlauf (Plan 3) ihn speichern kann.
///
/// Der Beleg bestimmt nicht, wo und wie wiederhergestellt wird: Zielort und launchctl-Domain leiten `PlistBackupStore`
/// bzw. Helper und `AutostartActions` aus dem Backup-Pfad und dem wiederhergestellten Pfad selbst ab.
public struct RemovalReceipt: Codable, Hashable, Sendable {
    /// Nur zur Anzeige: Der Helper liest das Label selbst aus der Plist, die App nutzt es beim Wiederherstellen nicht.
    public let label: String
    public let backupPath: String
    /// `true`: Das Backup liegt im System-Speicher des Helpers (`/Library/Launch*`); sonst im Benutzer-Speicher.
    public let isPrivileged: Bool
    /// Zustand vor dem Entfernen; nur ein zuvor aktivierter **und** geladener Eintrag wird wieder geladen.
    public let wasEnabled: Bool
    public let wasLoaded: Bool

    public init(label: String, backupPath: String, isPrivileged: Bool, wasEnabled: Bool, wasLoaded: Bool) {
        self.label = label
        self.backupPath = backupPath
        self.isPrivileged = isPrivileged
        self.wasEnabled = wasEnabled
        self.wasLoaded = wasLoaded
    }
}

/// Aktionen für launchd-Autostart-Einträge (Spec §5).
///
/// Aufteilung (Plan 2, „Aufteilung root vs. Benutzer“):
/// - launchctl für LaunchDaemons (`/Library/LaunchDaemons`, Domain `system`) führt der Helper aus – gebunden an den
///   Plist-Pfad, das Label liest er selbst. LaunchAgents – auch die aus `/Library/LaunchAgents` – steuert die App
///   direkt in `gui/<uid>`.
/// - Dateioperationen für `domain == .system` (`/Library/LaunchAgents`, `/Library/LaunchDaemons`) führt der Helper
///   aus, für `domain == .user` (`~/Library/LaunchAgents`) die App mit dem Benutzer-`PlistBackupStore`.
///
/// Bindung an den Plist-Pfad: launchd führt Dienste nach Label, und eine fremde Plist kann das Label eines anderen
/// Dienstes tragen (etwa `com.apple.Dock.agent` in `~/Library/LaunchAgents` oder eine Kopie von `org.cups.cupsd` in
/// `/Library/LaunchDaemons`). Vor jeder Aktion – in `gui/<uid>` wie in `system` – prüft `LaunchdServiceProbe` daher
/// lesend bei launchd, ob unter dem Label genau diese Plist geladen ist; der Ladezustand kommt dabei frisch von
/// launchd. `AutostartItem.isLoaded` aus dem Scan ist nur ein Hinweis für die Oberfläche und entscheidet hier nichts.
/// Ist ein Dienst aus einer anderen Plist geladen, lehnt `setEnabled` ab (`ActionError.notAllowed(.conflictingService)`),
/// und `remove` sichert und löscht nur die Datei – ohne `bootout`. Entladen erhält den Plist-Pfad als Argument
/// (`bootout <domain> <plist>`); maßgeblich bleibt aber die Abfrage davor, denn ob launchd die Herkunft des
/// geladenen Dienstes dabei selbst prüft, ist nicht belegt. Der Override (`enable`/`disable`) ist in launchd stets
/// an das Label gebunden.
///
/// Für LaunchDaemons ist diese Prüfung in der App nur Vorprüfung mit verständlicher Meldung: Maßgeblich prüft der
/// Helper (als root) dieselbe Zuordnung erneut, lehnt Konflikte ab und verweigert den Override zusätzlich, wenn eine
/// weitere Plist der Domain `system` dasselbe Label trägt (#99); seine Meldung kommt als `ActionError.commandFailed` an.
/// Für LaunchAgents verweigert die App den Override ebenso, wenn eine weitere Plist in `gui/<uid>` – in
/// `~/Library/LaunchAgents` oder `/Library/LaunchAgents` – dasselbe Label trägt (#138,
/// `ActionError.notAllowed(.ambiguousLabel)`): Die Aktion meint genau die bestätigte Datei, der Override träfe alle.
/// Entfernen ist davon nicht betroffen – es wirkt über den Plist-Pfad, nie über das Label.
///
/// Fehler: `ActionError.notAllowed`, wenn die `ActionPolicy` den Eintrag sperrt oder das Label kollidiert;
/// `ActionError.commandFailed` für
/// gescheiterte launchctl-Aufrufe (auch die Ladezustandsprüfung) und für jeden `HelperClientError`; `PolicyViolation` für ungültige Labels
/// oder Pfade (geprüft, bevor ein Befehl läuft); `BackupError` bzw. Dateisystemfehler aus dem Benutzer-Speicher.
/// `CancellationError` wird unverändert weitergereicht.
///
/// - Important: Scheitert ein Helper-Aufruf **nach** dem Senden (Abbruch, Zeitüberschreitung, Verbindungsabbruch),
///   ist das Ergebnis unbekannt – der Helper kann die Operation trotzdem ausgeführt haben. Auch bei mehrstufigen
///   Aktionen (z. B. deaktivieren, dann entladen) kann ein Fehler im zweiten Schritt einen Teilzustand hinterlassen.
///   Aufrufer sollten nach jedem Fehler neu scannen, statt einen unveränderten Zustand anzunehmen.
///
/// - Note: Agents, die per `LimitLoadToSessionType` auf andere Sessions als Aqua beschränkt sind, erscheinen in
///   `gui/<uid>` nie als geladen (`isLoaded == false`). Aktivieren versucht dann ein `bootstrap`, das scheitern kann,
///   obwohl die Aktivierung selbst bereits gespeichert ist. Die Oberfläche (Plan 3) muss das berücksichtigen.
public struct AutostartActions: Sendable {
    static let launchctl = "/bin/launchctl"
    static let systemDomain = PrivilegedOperationPolicy.systemLaunchctlDomain

    private let runner: any CommandRunning
    private let privileged: any PrivilegedAutostartControlling
    private let userBackups: PlistBackupStore
    private let policy: ActionPolicy
    private let operationPolicy = PrivilegedOperationPolicy()
    private let uid: uid_t
    /// Verzeichnisse, deren Plists Labels in `gui/<uid>` belegen (Prüfung auf doppelte Labels vor dem Override).
    private let launchAgentDirectories: [String]

    /// - Parameter launchAgentDirectories: Verzeichnisse der LaunchAgents in `gui/<uid>`; Vorgabe sind die von
    ///   `userBackups` verwalteten (`~/Library/LaunchAgents`) und `/Library/LaunchAgents`.
    public init(
        runner: any CommandRunning = ProcessCommandRunner(),
        privileged: any PrivilegedAutostartControlling,
        userBackups: PlistBackupStore = .user(),
        policy: ActionPolicy = ActionPolicy(),
        uid: uid_t = getuid(),
        launchAgentDirectories: [String]? = nil
    ) {
        self.runner = runner
        self.privileged = privileged
        self.userBackups = userBackups
        self.policy = policy
        self.uid = uid
        self.launchAgentDirectories = launchAgentDirectories
            ?? userBackups.managedDirectories + [PrivilegedOperationPolicy.systemLaunchAgentsDirectory]
    }

    /// Aktiviert/deaktiviert dauerhaft (launchctl-Override) und wendet es sofort an: Deaktivieren entlädt einen
    /// geladenen Eintrag (`bootout`), Aktivieren lädt einen nicht geladenen (`bootstrap`). Lehnt ab, bevor etwas
    /// geändert wird, wenn unter dem Label ein Dienst aus einer anderen Plist geladen ist oder – bei LaunchAgents – eine
    /// weitere Plist in `gui/<uid>` dasselbe Label trägt (bei LaunchDaemons prüft das der Helper).
    public func setEnabled(_ item: AutostartItem, _ enabled: Bool) async throws {
        let target = try target(for: item)
        if !target.isSystem { try ensureLabelIsUnique(target) }
        let binding = try await binding(of: target)
        guard binding != .loadedFromElsewhere else { throw ActionError.notAllowed(.conflictingService) }
        try await setOverride(target, enabled: enabled)
        if !enabled, binding == .loadedFromPlist { try await bootout(target) }
        if enabled, binding == .notLoaded { try await bootstrap(target.plistPath, domain: target.domain) }
    }

    /// Entlädt den Eintrag (falls aus dieser Plist geladen), sichert die Plist und löscht sie. Ist unter dem Label ein
    /// Dienst aus einer anderen Plist geladen, bleibt er unberührt; der Beleg vermerkt den Eintrag dann als nicht geladen.
    ///
    /// Die Plist muss die aus dem Scan sein (`AutostartItem.plistFingerprint`, #156): Hat ein Updater sie ersetzt oder
    /// umgeschrieben, ist der Eintrag ein anderer (`ActionError.notAllowed(.plistChanged)`). Geprüft wird dreifach:
    /// 1. vorab am Pfad, bevor launchd befragt oder etwas entladen wird;
    /// 2. **nach** der launchd-Abfrage und unmittelbar vor dem `bootout` (#166) – an der tatsächlich geöffneten
    ///    Sicherungsquelle (`PlistBackupStore.backupForRemoval(_:expecting:)`): Gesichert werden nur genau die Bytes
    ///    mit dem Fingerabdruck aus dem Scan. Ein Austausch während der Abfrage fällt hier auf, bevor etwas entladen,
    ///    gesichert oder gelöscht wird; Systemagenten (`/Library/LaunchAgents`, gesichert vom Helper erst nach dem
    ///    `bootout` in `gui/<uid>`) liest die App an dieser Stelle über ihr gebundenes Verzeichnis
    ///    (`BoundPlistContents`) und prüft sie gegen den Scan-Fingerabdruck;
    /// 3. unmittelbar vor dem Löschen Identität **und** Inhalt (`PendingPlistRemoval.remove()`): Wurde die Datei nach
    ///    der Sicherung – etwa während des `bootout` – ersetzt oder in-place umgeschrieben, wird nichts gelöscht.
    /// Schritte 2 und 3 gelten auch ohne gespeicherten Fingerabdruck (dann gegen den Stand beim Sichern).
    ///
    /// Scheitert das Entfernen erst **nach** dem `bootout` (#166), wäre der Dienst sonst gestoppt, obwohl seine Plist
    /// bleibt: Dann wird er wieder geladen – aber nur, wenn am Pfad noch **genau die Bytes** liegen, die vor dem
    /// `bootout` geprüft wurden (Rollback, `ServiceReload`; Erfolg erst nach Bestätigung durch launchd). Eine
    /// Ersatzkonfiguration lädt die App nie, das ist Sache des Updaters. Gemeldet wird `UnloadedRemovalFailure` – mit dem
    /// Grund und, falls nicht wieder geladen wurde, warum. Ist der Ausgang eines Helper-Aufrufs unbekannt
    /// (Zeitüberschreitung, Verbindungsabbruch: `HelperClientError.unavailable`), wird nichts wieder geladen – der
    /// Auftrag kann im Helper noch laufen –, sondern `UnloadedRemovalOutcomeUnknown` gemeldet („bitte neu scannen“).
    ///
    /// Kein verändernder Schritt vor allen Vorbedingungen: Bevor die App einen Systemagenten entlädt, stellt sie fest,
    /// dass der Helper das anschließende Sichern und Löschen beherrscht (`ensureHelperCanRemove()`); ein veralteter
    /// oder unerreichbarer Helper bricht ohne `bootout` ab.
    ///
    /// LaunchDaemons entlädt, sichert und löscht der Helper in **einem** eingereihten Ablauf (`unloadAndRemovePlist`)
    /// mit denselben Prüfungen 2 und 3 und demselben Rollback; die App fragt dafür launchd nicht selbst. Im
    /// Benutzer-Speicher sichert die App nach der launchd-Abfrage, entlädt dann und löscht danach – gebunden an genau
    /// das gesicherte Dateiobjekt im gebundenen Verzeichnis, sodass auch ein während des Entladens getauschtes
    /// Verzeichnis nie etwas anderes trifft. Systemagenten entlädt die App in `gui/<uid>`, der Helper sichert und löscht.
    /// Scheitert ein Schritt, bleibt die Plist erhalten (höchstens ein überzähliges Backup).
    public func remove(_ item: AutostartItem) async throws -> RemovalReceipt {
        let target = try target(for: item)
        try Self.ensurePlistUnchanged(item)
        let backupPath: String
        let wasLoaded: Bool
        switch item.domain {
        case .system where target.isSystem:
            let removal = try await ActionError.translatingHelperErrors { try await removePrivileged(target, of: item) }
            (backupPath, wasLoaded) = (removal.backupPath, removal.wasUnloaded)
        case .system:
            try await ensureHelperCanRemove()
            wasLoaded = try await binding(of: target) == .loadedFromPlist
            // Unmittelbar vor dem `bootout`: Bytes über das gebundene Verzeichnis lesen und gegen den Scan prüfen.
            let unloaded = try wasLoaded ? Self.boundContents(of: item, at: target.plistPath) : nil
            if wasLoaded { try await bootout(target) }
            backupPath = try await ActionError.translatingHelperErrors {
                try await rollingBack(target, unloadedUnlessChanged: unloaded.map { contents in { try contents.isUnchanged() } }) {
                    try await removePrivileged(target, of: item).backupPath
                }
            }
        case .user:
            let plist = try operationPolicy.validatePlistPath(target.plistPath, managedDirectories: userBackups.managedDirectories)
            wasLoaded = try await binding(of: target) == .loadedFromPlist
            let removal = try Self.backupForRemoval(plist, of: item, in: userBackups)
            backupPath = removal.backupPath
            if wasLoaded { try await bootout(target) }
            try await rollingBack(target, unloadedUnlessChanged: wasLoaded ? { try removal.hasBackedUpContents(at: target.plistPath) } : nil) {
                try removal.remove()
            }
        }
        return RemovalReceipt(
            label: target.label, backupPath: backupPath, isPrivileged: item.domain == .system,
            wasEnabled: item.isEnabled, wasLoaded: wasLoaded
        )
    }

    /// Stellt die Plist aus dem Backup wieder her und lädt den Eintrag, wenn er vor dem Entfernen aktiviert und
    /// geladen war.
    ///
    /// „Wiederhergestellt, aber nicht geladen“ ist ein gültiges Ergebnis: Ein deaktivierter Eintrag behält seinen
    /// launchd-Override (`remove` hebt ihn nicht auf) und kommt deaktiviert zurück – launchd würde ihn ohnehin nicht
    /// laden. Die Domain folgt aus dem wiederhergestellten Pfad (`LaunchDaemons` → `system`, sonst `gui/<uid>`), nie
    /// aus dem Beleg.
    public func restore(_ receipt: RemovalReceipt) async throws {
        let path = receipt.isPrivileged
            ? try await ActionError.translatingHelperErrors {
                try await privileged.restorePlist(backupPath: receipt.backupPath)
            }
            : try userBackups.restore(receipt.backupPath)
        guard receipt.wasEnabled, receipt.wasLoaded else { return }
        try await bootstrap(path, domain: launchctlDomain(forPlistAt: path))
    }

    // MARK: - Entfernen

    /// `PrivilegedAutostartControlling.unloadAndRemovePlist(path:expectedFingerprint:)` mit dem Fingerabdruck aus dem Scan.
    /// Wirft `HelperClientError` unübersetzt, damit `rollingBack` bestätigte Ablehnungen von unbekanntem Ausgang
    /// unterscheiden kann; die Aufrufer übersetzen.
    private func removePrivileged(_ target: Target, of item: AutostartItem) async throws -> PrivilegedPlistRemoval {
        try await privileged.unloadAndRemovePlist(path: target.plistPath, expectedFingerprint: item.plistFingerprint)
    }

    /// Bytes der Plist eines Systemagenten, gelesen über ihr gebundenes Verzeichnis; eine seit dem Scan geänderte meldet
    /// sich wie in der Vorprüfung (`ActionError.notAllowed(.plistChanged)`).
    private static func boundContents(of item: AutostartItem, at path: String) throws -> BoundPlistContents {
        do {
            return try BoundPlistContents(path: path, expecting: item.plistFingerprint)
        } catch BackupError.changedSinceScan {
            throw ActionError.notAllowed(.plistChanged)
        }
    }

    /// Vorbedingung vor dem ersten verändernden Schritt: Der erreichbare Helper kennt `unloadAndRemovePlist`; sonst
    /// `ActionError.commandFailed` („Helper veraltet …“ bzw. nicht erreichbar).
    private func ensureHelperCanRemove() async throws {
        try await ActionError.translatingHelperErrors {
            guard try await privileged.protocolVersion() >= HelperXPC.unloadAndRemovePlistMinimumVersion else {
                throw HelperClientError.outdated
            }
        }
    }

    /// Führt `removal` aus. Hat die App den Eintrag davor entladen (`isUnchanged` gesetzt: prüft, ob am Pfad noch genau
    /// die entladenen Bytes liegen) und scheitert `removal` **bestätigt**, lädt sie ihn wieder (`reload(_:isUnchanged:)`)
    /// und wirft `UnloadedRemovalFailure` (#166). Unbekannter Ausgang wird nicht kompensiert: `CancellationError` wird
    /// unverändert weitergereicht, `HelperClientError.unavailable` (Zeitüberschreitung, Verbindungsabbruch – der
    /// Helper-Auftrag kann noch laufen) als `UnloadedRemovalOutcomeUnknown`.
    @discardableResult
    private func rollingBack<Value>(
        _ target: Target, unloadedUnlessChanged isUnchanged: (() throws -> Bool)?, _ removal: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await removal()
        } catch {
            guard let isUnchanged, !(error is CancellationError) else { throw error }
            if case HelperClientError.unavailable = error {
                throw UnloadedRemovalOutcomeUnknown(path: target.plistPath, reason: error.readableDescription)
            }
            throw await UnloadedRemovalFailure.rollingBack(target.plistPath, after: error) {
                try await reload(target, isUnchanged: isUnchanged)
            }
        }
    }

    /// Rollback (`ServiceReload`): lädt die Plist am Pfad nur, wenn dort noch genau die entladenen Bytes liegen, und
    /// verlangt danach die Bestätigung durch launchd.
    private func reload(_ target: Target, isUnchanged: () throws -> Bool) async throws {
        try await ServiceReload.reload(
            label: target.label,
            isUnchanged: isUnchanged,
            binding: { try await binding(of: target) },
            bootstrap: { try await bootstrap(target.plistPath, domain: target.domain) }
        )
    }

    // MARK: - launchctl

    /// Geprüfter Eintrag mit seiner launchctl-Domain.
    private struct Target {
        let label: String
        let domain: String
        /// Plist-Pfad wie gemeldet – bewusst nicht aufgelöst, damit Helper und `validatePlistPath` Symlinks erkennen
        /// und ablehnen.
        let plistPath: String
        var isSystem: Bool { domain == AutostartActions.systemDomain }
    }

    /// Prüft Policy und Plist; für `gui`-Einträge zusätzlich die Syntax des Labels, weil es als Befehlsargument dient.
    /// Ob ein `com.apple.`-Label echt ist, hat die `ActionPolicy` bereits anhand der Herkunft entschieden – ein als
    /// Apple getarnter Agent soll sich entfernen lassen.
    private func target(for item: AutostartItem) throws -> Target {
        if case .readOnly(let reason) = policy.availability(for: item) { throw ActionError.notAllowed(reason) }
        guard let plist = item.plistPath else { throw ActionError.notAllowed(.noPlist) }
        let domain = item.kind == .launchDaemon ? Self.systemDomain : guiDomain
        let target = Target(label: item.label, domain: domain, plistPath: plist)
        if !target.isSystem { try operationPolicy.validateLabelSyntax(item.label) }
        return target
    }

    /// Keine weitere Plist in `launchAgentDirectories` trägt das Label (#138); sonst
    /// `ActionError.notAllowed(.ambiguousLabel)`. Ein nicht lesbares Verzeichnis oder eine nicht auswertbare weitere
    /// Plist lässt die Frage offen und lehnt ebenfalls ab (`PolicyViolation.unreadableDirectory` bzw.
    /// `.unverifiableLabel`, fail-closed).
    private func ensureLabelIsUnique(_ target: Target) throws {
        do {
            try operationPolicy.ensureLabelIsUnique(target.label, ofPlistAt: target.plistPath, in: launchAgentDirectories)
        } catch .ambiguousLabel {
            throw ActionError.notAllowed(.ambiguousLabel)
        }
    }

    /// Die Plist unter `item.plistPath` trägt noch den Fingerabdruck aus dem Scan; ohne gespeicherten Fingerabdruck
    /// (ältere Snapshots, andere Quellen) entfällt die Prüfung. Gelesen wird derselbe, nicht aufgelöste Pfad wie in
    /// `LaunchdSource`, damit die Fingerabdrücke vergleichbar sind.
    private static func ensurePlistUnchanged(_ item: AutostartItem) throws {
        guard let expected = item.plistFingerprint, let path = item.plistPath else { return }
        guard let current = FileFingerprint(of: path), expected.matches(current) else {
            throw ActionError.notAllowed(.plistChanged)
        }
    }

    /// `PlistBackupStore.backupForRemoval(_:expecting:)` mit dem Fingerabdruck aus dem Scan; eine inzwischen geänderte
    /// Plist meldet sich wie in der Vorprüfung (`ActionError.notAllowed(.plistChanged)`).
    private static func backupForRemoval(
        _ plist: String, of item: AutostartItem, in store: PlistBackupStore
    ) throws -> PendingPlistRemoval {
        do {
            return try store.backupForRemoval(plist, expecting: item.plistFingerprint)
        } catch BackupError.changedSinceScan {
            throw ActionError.notAllowed(.plistChanged)
        }
    }

    /// Domain eines wiederhergestellten Plist-Pfads: Plists in einem `LaunchDaemons`-Verzeichnis gehören zu `system`.
    private func launchctlDomain(forPlistAt path: String) -> String {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        return directory == URL(fileURLWithPath: PrivilegedOperationPolicy.systemLaunchDaemonsDirectory).lastPathComponent
            ? Self.systemDomain : guiDomain
    }

    private var guiDomain: String { "gui/\(uid)" }

    /// Ob unter dem Label genau diese Plist geladen ist – frisch von launchd (`launchctl print <domain>/<label>`,
    /// lesend, auch für `system`), nie aus dem Scan.
    private func binding(of target: Target) async throws -> LaunchdServiceBinding {
        do {
            return try await LaunchdServiceProbe(runner: runner)
                .binding(ofLabel: target.label, in: target.domain, toPlistAt: target.plistPath)
        } catch let error as LaunchdSourceError {
            throw ActionError.commandFailed(error.readableDescription)
        }
    }

    private func setOverride(_ target: Target, enabled: Bool) async throws {
        if target.isSystem {
            try await ActionError.translatingHelperErrors {
                try await privileged.setEnabled(plistPath: target.plistPath, enabled: enabled)
            }
        } else {
            try await runLaunchctl([enabled ? "enable" : "disable", "\(target.domain)/\(target.label)"])
        }
    }

    private func bootout(_ target: Target) async throws {
        if target.isSystem {
            // Der Helper prüft die Zuordnung erneut und entlädt mit dem Plist-Pfad (`bootout system <plist>`).
            try await ActionError.translatingHelperErrors { try await privileged.bootout(plistPath: target.plistPath) }
        } else {
            // Mit Plist-Pfad statt `bootout gui/<uid>/<label>`; die Abfrage davor (`binding(of:)`) hat eine
            // Label-Kollision bereits ausgeschlossen.
            try await runLaunchctl(["bootout", target.domain, target.plistPath])
        }
    }

    private func bootstrap(_ plistPath: String, domain: String) async throws {
        if domain == Self.systemDomain {
            try await ActionError.translatingHelperErrors { try await privileged.bootstrap(plistPath: plistPath) }
        } else {
            try await runLaunchctl(["bootstrap", domain, plistPath])
        }
    }

    private func runLaunchctl(_ arguments: [String]) async throws {
        try await runner.runChecked(Self.launchctl, arguments)
    }
}
