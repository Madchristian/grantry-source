import Foundation
import GrantryShared
import os

/// Implementierung der Helper-Operationen. Läuft als root; prüft jede Eingabe mit `PrivilegedOperationPolicy`.
///
/// launchctl wirkt ausschließlich in der Domain `system` auf Plists direkt in `launchDaemonsDirectory`; das
/// Label liest der Helper selbst aus der Datei. Plists werden nur gelöscht, wenn Pfad **und** gelesenes
/// Label gültig sind (nie `com.apple.*`).
///
/// Bindung an die Plist statt ans Label (#99): launchd führt Dienste je Domain nach Label, und eine zweite Plist kann
/// das Label eines anderen Daemons tragen (etwa eine Kopie von `org.cups.cupsd` neben Apples Original). Vor jeder
/// launchctl-Operation fragt der Helper deshalb launchd (`launchctl print system/<label>`,
/// `LaunchdServiceBinding`), ob unter dem Label genau diese Plist geladen ist; ist ein Dienst aus einer anderen
/// Plist geladen, lehnt er ab (`PolicyViolation.conflictingService`). Entladen und Laden erhalten den Plist-Pfad als
/// Argument (`bootout|bootstrap system <plist>`); ob launchd bei `bootout` die Herkunft des geladenen Dienstes selbst
/// prüft, ist nicht belegt – maßgeblich ist die Abfrage unmittelbar davor in derselben eingereihten Operation, sie
/// darf deshalb für keine Operation entfallen. Der Override (`enable`/`disable`) ist in launchd zwingend
/// labelgebunden und wird zusätzlich abgelehnt, wenn eine weitere Plist in `daemonDirectories` dasselbe Label trägt
/// (`PolicyViolation.ambiguousLabel`) – auch eine gerade nicht geladene würde sonst mit umgeschaltet. Was die App
/// aus ihrem Scan über den Ladezustand weiß, zählt hier nicht; maßgeblich ist allein launchd zum Zeitpunkt der
/// Operation. Ein Angreifer, der zwischen Abfrage und Befehl die Domain `system` oder `/Library/LaunchDaemons`
/// verändert, bräuchte dafür bereits root.
///
/// launchctl- und Datei-Operationen laufen samt Prüfung nacheinander (`SerialOperationQueue`), damit sich
/// gleichzeitige Anfragen auf dieselbe Plist nicht überschneiden; `dumpBTM` liest nur und läuft parallel,
/// ebenso `listListeningSockets`.
/// Die absichernden Operationen (`SecurityHardening`, parameterlos, feste Kommandozeilen) laufen ebenfalls in
/// `queue`. `terminateProcess` prüft mit `ProcessTerminationPolicy.helper()` und läuft in einer eigenen Warteschlange
/// (`terminationQueue`), damit kein langer Befehl (etwa `xprotect update`, 120 s) einen Beenden-Auftrag aufhält; die
/// Aufrufer-PID liest es vorher synchron im XPC-Aufruf. Das Admin-Gate liegt für alle Methoden am
/// `HelperListenerDelegate`. Jede Operation antwortet genau einmal und zählt, solange sie läuft, als Aktivität von
/// `idleMonitor`.
public final class HelperService: NSObject, GrantryHelperXPC, Sendable {
    static let launchctl = "/bin/launchctl"
    static let sfltool = "/usr/bin/sfltool"
    /// Einzige launchctl-Domain des Helpers.
    static let systemDomain = PrivilegedOperationPolicy.systemLaunchctlDomain
    private static let logger = Logger(subsystem: GrantryIdentity.logSubsystem, category: "helper")

    private let runner: any CommandRunning
    private let backups: PlistBackupStore
    private let launchDaemonsDirectory: String
    /// Alle Verzeichnisse, deren Plists Labels der Domain `system` belegen: `launchDaemonsDirectory` voran.
    private let daemonDirectories: [String]
    private let policy = PrivilegedOperationPolicy()
    private let queue: SerialOperationQueue
    private let terminationQueue: SerialOperationQueue
    private let socketEnumerator: any ListeningSocketEnumerating
    private let terminationPolicy: ProcessTerminationPolicy
    private let processSignaler: any ProcessSignaling
    /// PID des Aufrufers der laufenden XPC-Nachricht; nur synchron im Aufruf gültig.
    private let callerPID: @Sendable () -> pid_t?
    /// Startet eine Stoppuhr auf der Uhr des Helpers; das Ergebnis liefert die seither vergangene Zeit.
    private let startStopwatch: @Sendable () -> @Sendable () -> Duration
    private let idleMonitor: IdleMonitor?

    /// Aufrufer laut `NSXPCConnection.current()` – das Audit-Token ist keine öffentliche API. Liefert nur im Kontext
    /// eines Aufrufs am exportierten Objekt einen Wert, sonst `nil`.
    public static let currentCallerPID: @Sendable () -> pid_t? = { NSXPCConnection.current()?.processIdentifier }

    /// - Parameter launchDaemonsDirectory: Verzeichnis, auf dessen Plists launchctl-Operationen erlaubt sind;
    ///   nur in Tests abweichend vom Systemverzeichnis.
    /// - Parameter additionalDaemonDirectories: weitere Verzeichnisse, deren Plists Labels der Domain `system`
    ///   belegen (Apples LaunchDaemons-Verzeichnisse); ihre Plists werden nur gelesen, um doppelte Labels abzulehnen.
    /// - Parameter socketEnumerator: liest die lauschenden Sockets für `listListeningSockets`.
    /// - Parameter terminationPolicy: Prüfregeln für `terminateProcess`.
    /// - Parameter processSignaler: stellt das Signal von `terminateProcess` zu; in Tests ein Fake.
    /// - Parameter callerPID: liest die PID des Aufrufers, synchron im XPC-Aufruf.
    /// - Parameter clock: Uhr für die Ablauffrist von `terminateProcess` (`terminationRequestLifetime`); nur in Tests
    ///   abweichend.
    /// - Parameter idleMonitor: erfährt Beginn und Ende jeder Operation (Idle-Exit des Helpers).
    public init(
        runner: any CommandRunning = ProcessCommandRunner(),
        backups: PlistBackupStore = .system,
        launchDaemonsDirectory: String = PrivilegedOperationPolicy.systemLaunchDaemonsDirectory,
        additionalDaemonDirectories: [String] = PrivilegedOperationPolicy.appleLaunchDaemonsDirectories,
        socketEnumerator: any ListeningSocketEnumerating = LibprocSocketEnumerator(),
        terminationPolicy: ProcessTerminationPolicy = .helper(),
        processSignaler: any ProcessSignaling = PosixProcessSignaler(),
        callerPID: @escaping @Sendable () -> pid_t? = HelperService.currentCallerPID,
        clock: some Clock<Duration> = ContinuousClock(),
        idleMonitor: IdleMonitor? = nil
    ) {
        self.runner = runner
        self.backups = backups
        self.launchDaemonsDirectory = launchDaemonsDirectory
        daemonDirectories = [launchDaemonsDirectory] + additionalDaemonDirectories.filter { $0 != launchDaemonsDirectory }
        self.socketEnumerator = socketEnumerator
        self.terminationPolicy = terminationPolicy
        self.processSignaler = processSignaler
        self.callerPID = callerPID
        startStopwatch = {
            let start = clock.now
            return { start.duration(to: clock.now) }
        }
        self.idleMonitor = idleMonitor
        queue = SerialOperationQueue(idleMonitor: idleMonitor)
        terminationQueue = SerialOperationQueue(idleMonitor: idleMonitor)
    }

    public func protocolVersion(reply: @escaping @Sendable (Int) -> Void) {
        reply(HelperXPC.protocolVersion)
    }

    public func dumpBTM(reply: @escaping @Sendable (String?, String?) -> Void) {
        Self.logger.notice("sfltool dumpbtm angefordert")
        let activity = idleMonitor?.beginActivity()
        Task {
            defer { activity?.end() }
            do {
                let result = try await runner.run(Self.sfltool, ["dumpbtm"], timeout: .seconds(60))
                guard result.succeeded else {
                    return reply(nil, Self.failure("sfltool dumpbtm", result))
                }
                reply(result.stdout, nil)
            } catch {
                reply(nil, error.readableDescription)
            }
        }
    }

    /// Läuft synchron im Aufruf, weil ein Durchlauf über alle Prozesse nur wenige Millisekunden braucht.
    public func listListeningSockets(reply: @escaping @Sendable (Data?, String?) -> Void) {
        let activity = idleMonitor?.beginActivity()
        defer { activity?.end() }
        do {
            reply(try JSONEncoder().encode(try socketEnumerator.listeningSockets()), nil)
        } catch {
            Self.logger.error("Sockets nicht lesbar: \(error.readableDescription, privacy: .public)")
            reply(nil, error.readableDescription)
        }
    }

    public func setEnabled(plistPath: String, enabled: Bool, reply: @escaping @Sendable (String?) -> Void) {
        perform(enabled ? .enable : .disable, plistPath: plistPath, reply: reply)
    }

    public func bootout(plistPath: String, reply: @escaping @Sendable (String?) -> Void) {
        perform(.bootout, plistPath: plistPath, reply: reply)
    }

    public func bootstrap(plistPath: String, reply: @escaping @Sendable (String?) -> Void) {
        perform(.bootstrap, plistPath: plistPath, reply: reply)
    }

    /// Ein Ablauf in `queue` (#166): Zwischen Prüfung, `bootout` und Löschen läuft keine andere Operation des Helpers.
    ///
    /// Reihenfolge für LaunchDaemons: Label lesen, launchd fragen, **dann** sichern – die Sicherung prüft das geöffnete
    /// Dateiobjekt gegen den Fingerabdruck aus dem Scan (`expectedFingerprint`, #156) und ist damit die Prüfung
    /// unmittelbar vor dem `bootout`. Ein Austausch bis dahin wird abgelehnt, ohne dass etwas entladen wird. Erst
    /// danach fällt ein Austausch beim Löschen auf (`PendingPlistRemoval.remove()`); dann lädt `reload(_:from:)` den Dienst
    /// nur dann wieder, wenn am Pfad noch genau die gesicherten Bytes liegen (`ServiceReload`), und meldet
    /// `UnloadedRemovalFailure`. Gelöscht wird nur, was die Sicherung enthält.
    public func unloadAndRemovePlist(
        path: String, expectedFingerprint: Data?, reply: @escaping @Sendable (String?, Bool, String?) -> Void
    ) {
        queue.enqueue { [self] in
            do {
                let expected = try Self.decodeFingerprint(expectedFingerprint)
                let validated = try policy.label(forPlistAt: path, managedDirectories: backups.managedDirectories).path
                let (removal, unloaded) = try await backupUnloading(validated, expecting: expected)
                do {
                    try removal.remove()
                } catch {
                    guard let unloaded else { throw error }
                    throw await UnloadedRemovalFailure.rollingBack(validated, after: error) { try await reload(unloaded, from: removal) }
                }
                Self.logger.notice("Plist entfernt: \(validated, privacy: .public), Backup: \(removal.backupPath, privacy: .public), entladen: \(unloaded != nil, privacy: .public)")
                reply(removal.backupPath, unloaded != nil, nil)
            } catch {
                Self.logger.error("Plist entfernen abgelehnt/fehlgeschlagen: \(path, privacy: .public): \(error.readableDescription, privacy: .public)")
                reply(nil, false, error.readableDescription)
            }
        }
    }

    /// Sichert die Plist unter dem kanonischen Pfad `validated` gebunden an `expected`; liegt sie direkt in
    /// `launchDaemonsDirectory`, wird zuvor launchd gefragt und danach ein aus genau dieser Plist geladener Dienst
    /// entladen. Liefert die ausstehende Löschung und den entladenen Daemon (Pfad und das Label, unter dem launchd ihn
    /// aus dieser Plist geladen hatte), sonst `nil`.
    ///
    /// Ein aus einer anderen Plist geladener Dienst (#99) bleibt unberührt; wie in der App wird dann nur die Datei
    /// gesichert und gelöscht.
    private func backupUnloading(
        _ validated: String, expecting expected: FileFingerprint?
    ) async throws -> (removal: PendingPlistRemoval, unloaded: (path: String, label: String)?) {
        guard isLaunchDaemon(validated) else { return (try backups.backupForRemoval(validated, expecting: expected), nil) }
        let daemon = try policy.launchDaemonLabel(forPlistAt: validated, launchDaemonsDirectory: launchDaemonsDirectory)
        let binding = try await Self.binding(of: daemon, on: runner)
        // Unmittelbar vor dem `bootout`: Gesichert (und später gelöscht) wird nur die Datei mit dem Scan-Fingerabdruck.
        let removal = try backups.backupForRemoval(validated, expecting: expected)
        guard binding == .loadedFromPlist else { return (removal, nil) }
        try await execute(.bootout, on: daemon, binding: binding)
        return (removal, daemon)
    }

    /// Rollback nach einem `bootout`, dessen Plist sich nicht löschen ließ (`ServiceReload`): lädt die Plist am Pfad nur,
    /// wenn dort noch genau die vor dem `bootout` gesicherten Bytes liegen (`removal`, gelesen über das gebundene
    /// Verzeichnis), und verlangt danach, dass launchd den Daemon unter seinem Label aus dieser Plist geladen meldet.
    /// Eine Ersatzkonfiguration lädt der Helper nie.
    private func reload(_ daemon: (path: String, label: String), from removal: PendingPlistRemoval) async throws {
        try await ServiceReload.reload(
            label: daemon.label,
            isUnchanged: { try removal.hasBackedUpContents(at: daemon.path) },
            binding: { try await Self.binding(of: daemon, on: runner) },
            bootstrap: { try await execute(.bootstrap, on: daemon, binding: .notLoaded) }
        )
    }

    /// Ob der kanonische Pfad `path` direkt in `launchDaemonsDirectory` liegt (Vergleich wie in
    /// `PrivilegedOperationPolicy.validatePlistPath(_:managedDirectories:)`).
    private func isLaunchDaemon(_ path: String) -> Bool {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
            == URL(fileURLWithPath: launchDaemonsDirectory).resolvingSymlinksInPath().path
    }

    /// JSON-kodierter `FileFingerprint` aus der App; Unlesbares ist `PolicyViolation.invalidFingerprint`.
    private static func decodeFingerprint(_ data: Data?) throws -> FileFingerprint? {
        try data.map { data in
            do { return try JSONDecoder().decode(FileFingerprint.self, from: data) } catch {
                throw PolicyViolation.invalidFingerprint
            }
        }
    }

    public func restorePlist(backupPath: String, reply: @escaping @Sendable (String?, String?) -> Void) {
        queue.enqueue { [backups] in
            do {
                let restored = try backups.restore(backupPath)
                Self.logger.notice("Plist wiederhergestellt: \(restored, privacy: .public)")
                reply(restored, nil)
            } catch {
                Self.logger.error("Wiederherstellen abgelehnt/fehlgeschlagen: \(backupPath, privacy: .public): \(error.readableDescription, privacy: .public)")
                reply(nil, error.readableDescription)
            }
        }
    }

    // MARK: - Prozess beenden (#128)

    /// Längstes Warten eines Beenden-Auftrags zwischen Eingang und Signal. Deutlich unter der Frist des Clients
    /// (`HelperClient.callTimeout`, 60 s): Hat der Client aufgegeben, sendet der Helper sicher nicht mehr (#153,
    /// Befund 4). Geprüft wird vor der Identitätsprüfung und erneut unmittelbar vor dem Signal: Auch eine Prüfung, die
    /// selbst länger blockiert (Pfad-, Signatur- oder Socketprüfung auf einem gestörten Volume), lässt die Frist nicht
    /// aus.
    static let terminationRequestLifetime: Duration = .seconds(10)

    /// Prüfung und Signal laufen eingereiht in `terminationQueue`; die Aufrufer-PID wird vorher synchron gelesen, weil
    /// `NSXPCConnection.current()` nur hier gilt. Ohne Aufrufer-PID lehnt der Helper ab (`callerUnknown`, fail-closed).
    ///
    /// Log und Meldungen nennen nur die PID und das Programm laut Inspektor
    /// (`ProcessTerminationPolicy.displayName(of:)`), nie den vom Aufrufer übergebenen Pfadtext.
    ///
    /// **Spätes Signal:** Ein Auftrag, der bis zum Signal länger als `terminationRequestLifetime` gebraucht hat – in
    /// der Warteschlange oder in der Prüfung –, wird ohne Signal abgelehnt (`requestExpired`): Der Client könnte ihn
    /// wegen Zeitüberschreitung schon als gescheitert gemeldet haben. Innerhalb der Frist trifft das Signal nur den
    /// bestätigten Prozess: Pfad und Startzeit werden erst in der eingereihten Operation unmittelbar vor dem Signal
    /// geprüft, und das Signal geht an die bestätigte Prozessgeneration (`ProcessAuditToken`), nie an eine inzwischen
    /// neu vergebene PID.
    public func terminateProcess(
        pid: Int32, executablePath: String, startTime: UInt64, force: Bool, reply: @escaping @Sendable (String?) -> Void
    ) {
        let callerPID = callerPID()
        let waited = startStopwatch()
        terminationQueue.enqueue { [terminationPolicy, processSignaler] in
            let signal = TerminationSignal(force: force)
            let subject = "\(signal.rawValue) an PID \(pid)"
            func ensureWithinLifetime() throws(ProcessTerminationViolation) {
                guard waited() <= Self.terminationRequestLifetime else { throw .requestExpired(pid) }
            }
            do {
                guard let callerPID else { throw ProcessTerminationViolation.callerUnknown }
                try ensureWithinLifetime()
                let target = try terminationPolicy.validate(
                    pid: pid, executablePath: executablePath, startTime: startTime, callerPID: callerPID, force: force
                )
                guard case .running(let process) = target else {
                    Self.logger.notice("\(subject, privacy: .public) unnötig, bereits beendet")
                    return reply(nil)
                }
                let name = ProcessTerminationPolicy.displayName(of: process.executablePath)
                // Erneut unmittelbar vor dem Signal: Die Prüfung selbst kann länger als die Frist gedauert haben.
                try ensureWithinLifetime()
                let delivery = try processSignaler.send(signal, to: process)
                Self.logger.notice("\(subject, privacy: .public) (\(name, privacy: .public)): \(delivery == .delivered ? "gesendet" : "bereits beendet", privacy: .public)")
                reply(nil)
            } catch {
                Self.logger.error("\(subject, privacy: .public) abgelehnt/fehlgeschlagen: \(error.readableDescription, privacy: .public)")
                reply(error.readableDescription)
            }
        }
    }

    // MARK: - Absichern (Spec v2)

    public func enableFirewall(reply: @escaping @Sendable (String?) -> Void) { harden(.enableFirewall, reply: reply) }
    public func enableStealthMode(reply: @escaping @Sendable (String?) -> Void) { harden(.enableStealthMode, reply: reply) }
    public func enableGatekeeper(reply: @escaping @Sendable (String?) -> Void) { harden(.enableGatekeeper, reply: reply) }
    public func enableAutomaticUpdates(reply: @escaping @Sendable (String?) -> Void) { harden(.enableAutomaticUpdates, reply: reply) }
    public func updateXProtect(reply: @escaping @Sendable (String?) -> Void) { harden(.updateXProtect, reply: reply) }

    /// Führt die festen Befehle von `operation` nacheinander aus – eingereiht in `queue`, protokolliert. Hat die
    /// Operation eine `stateQuery`, wird zuerst gelesen: Ist das Ziel schon erreicht, wird nichts gesetzt (so schwächt
    /// „Firewall einschalten“ nie „Alle eingehenden blockieren“ ab); ist die Ausgabe unbekannt, bricht der Helper ab
    /// (`isTargetReached(_:timeout:on:)`).
    /// Der erste gescheiterte Befehl beendet die Operation mit seiner Meldung (samt stderr).
    private func harden(_ operation: SecurityHardening, reply: @escaping @Sendable (String?) -> Void) {
        queue.enqueue { [runner] in
            Self.logger.notice("Absichern: \(operation.rawValue, privacy: .public)")
            do {
                if let query = operation.stateQuery,
                   try await Self.isTargetReached(query, timeout: operation.timeout, on: runner) {
                    Self.logger.notice("Absichern unnötig, bereits erreicht: \(operation.rawValue, privacy: .public)")
                    return reply(nil)
                }
                for invocation in operation.invocations {
                    try await Self.run(invocation, timeout: operation.timeout, on: runner)
                }
            } catch {
                Self.logger.error("Absichern \(operation.rawValue, privacy: .public) gescheitert: \(error.readableDescription, privacy: .public)")
                return reply(error.readableDescription)
            }
            Self.logger.notice("Absichern erledigt: \(operation.rawValue, privacy: .public)")
            reply(nil)
        }
    }

    /// Führt die Zustandsabfrage aus und wertet stdout aus. Bei Exit ≠ 0 gilt nur „Ziel nicht erreicht“ als gültiger
    /// Zustand – `spctl --status` endet bei „assessments disabled“ mit Exit 1 (wie die App, `CommandSecurityProbe`).
    /// „Bereits erreicht“ trotz Exit ≠ 0 ist zweifelhaft und übersprünge das Setzen; dann wie bei unbekannter Ausgabe
    /// `CommandFailure`: bei Exit ≠ 0 mit Befehl und stderr, sonst mit der Ausgabe.
    private static func isTargetReached(
        _ query: SecurityHardening.StateQuery, timeout: Duration, on runner: any CommandRunning
    ) async throws -> Bool {
        let invocation = query.invocation
        let result = try await runner.run(invocation.executable, invocation.arguments, timeout: timeout)
        let reached = query.isTargetReached(in: result.stdout)
        if let reached, result.succeeded || !reached { return reached }
        guard result.succeeded else { throw CommandFailure(message: failure(invocation.commandLine, result)) }
        throw CommandFailure(message: unrecognizedState(invocation.commandLine, result.stdout))
    }

    /// Führt `invocation` aus; Exit ≠ 0 wirft `CommandFailure` mit Befehl und stderr.
    private static func run(
        _ invocation: SecurityHardening.Invocation, timeout: Duration, on runner: any CommandRunning
    ) async throws {
        try await run(invocation.executable, invocation.arguments, timeout: timeout, on: runner, commandLine: invocation.commandLine)
    }

    /// Führt `executable arguments` aus; Exit ≠ 0 wirft `CommandFailure` mit `commandLine` und stderr.
    private static func run(
        _ executable: String, _ arguments: [String], timeout: Duration, on runner: any CommandRunning, commandLine: String
    ) async throws {
        let result = try await runner.run(executable, arguments, timeout: timeout)
        guard result.succeeded else { throw CommandFailure(message: failure(commandLine, result)) }
    }

    private static func unrecognizedState(_ command: String, _ output: String) -> String {
        let excerpt = shortened(output.trimmingCharacters(in: .whitespacesAndNewlines))
        return "\(command): Zustand nicht erkannt – nichts geändert" + (excerpt.isEmpty ? "" : ": \(excerpt)")
    }

    /// Gescheiterter Befehl einer Operation; die Meldung geht unverändert an die App.
    private struct CommandFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - launchctl

    /// Frist für verändernde `launchctl`-Befehle. Zusammen mit `probeTimeout` und je einer Gnadenfrist
    /// (`ProcessCommandRunner.defaultTerminationGracePeriod`) ergibt sich die längste Dauer einer Operation; die Frist
    /// des `HelperClient` (`callTimeout`) liegt darüber, damit die Meldung des Helpers Vorrang hat.
    static let launchctlTimeout: Duration = .seconds(30)

    /// Frist für die lesende Abfrage `launchctl print system/<label>`; sie antwortet normalerweise sofort.
    static let probeTimeout: Duration = .seconds(10)

    /// launchctl-Operation auf einem LaunchDaemon in der Domain `system`.
    private enum DaemonOperation: String {
        case enable, disable, bootout, bootstrap

        /// Der Override gilt in launchd je Label (`system/<label>`), nicht je Plist.
        var changesLabelOverride: Bool { self == .enable || self == .disable }

        /// Argumente für `launchctl`, sofern bei `binding` etwas zu tun ist; `nil`, wenn das Ziel schon erreicht ist
        /// (nicht geladener Dienst beim `bootout`, aus dieser Plist geladener beim `bootstrap`).
        func arguments(for daemon: (path: String, label: String), binding: LaunchdServiceBinding) -> [String]? {
            switch self {
            case .enable, .disable: [rawValue, "\(HelperService.systemDomain)/\(daemon.label)"]
            case .bootout: binding == .notLoaded ? nil : [rawValue, HelperService.systemDomain, daemon.path]
            case .bootstrap: binding == .loadedFromPlist ? nil : [rawValue, HelperService.systemDomain, daemon.path]
            }
        }
    }

    /// Validiert `plistPath` als LaunchDaemon, liest dessen Label, klärt bei launchd die Zuordnung des Dienstes zur
    /// Plist und führt dann `launchctl` aus – alles eingereiht in `queue`. Abgelehnt wird vor jedem verändernden
    /// Befehl: ungültige Plist, Dienst aus anderer Plist geladen (`conflictingService`), beim Override zusätzlich
    /// ein zweites Vorkommen des Labels in `daemonDirectories` (`ambiguousLabel`); ist der Ladezustand nicht
    /// feststellbar, endet die Operation mit der Meldung von `launchctl print`.
    private func perform(_ operation: DaemonOperation, plistPath: String, reply: @escaping @Sendable (String?) -> Void) {
        queue.enqueue { [self] in
            do {
                let daemon = try policy.launchDaemonLabel(forPlistAt: plistPath, launchDaemonsDirectory: launchDaemonsDirectory)
                let binding = try await Self.binding(of: daemon, on: runner)
                guard binding != .loadedFromElsewhere else { throw PolicyViolation.conflictingService(daemon.label) }
                if operation.changesLabelOverride {
                    try policy.ensureLabelIsUnique(daemon.label, ofPlistAt: daemon.path, in: daemonDirectories)
                }
                try await execute(operation, on: daemon, binding: binding)
                reply(nil)
            } catch {
                Self.logger.error("launchctl \(operation.rawValue, privacy: .public) abgelehnt/fehlgeschlagen: \(plistPath, privacy: .public): \(error.readableDescription, privacy: .public)")
                reply(error.readableDescription)
            }
        }
    }

    /// Führt `operation` für `daemon` aus, sofern bei `binding` (unmittelbar zuvor von launchd erfragt) etwas zu tun
    /// ist. Die Prüfungen davor (Zuordnung, eindeutiges Label) obliegen dem Aufrufer.
    private func execute(
        _ operation: DaemonOperation, on daemon: (path: String, label: String), binding: LaunchdServiceBinding
    ) async throws {
        let verb = operation.rawValue
        guard let arguments = operation.arguments(for: daemon, binding: binding) else {
            Self.logger.notice("launchctl \(verb, privacy: .public) \(daemon.label, privacy: .public) unnötig, Ziel bereits erreicht")
            return
        }
        Self.logger.notice("launchctl \(verb, privacy: .public) \(daemon.label, privacy: .public) (\(daemon.path, privacy: .public))")
        try await Self.run(
            Self.launchctl, arguments, timeout: Self.launchctlTimeout, on: runner, commandLine: Self.launchctlCommandLine(arguments)
        )
    }

    /// Fragt launchd (`launchctl print system/<label>`), ob und aus welcher Plist der Dienst geladen ist.
    /// Ein gescheiterter Aufruf wirft `CommandFailure` mit Befehl, Exit-Code und stderr.
    private static func binding(
        of daemon: (path: String, label: String), on runner: any CommandRunning
    ) async throws -> LaunchdServiceBinding {
        let arguments = LaunchdServiceBinding.printArguments(domain: systemDomain, label: daemon.label)
        let result = try await runner.run(launchctl, arguments, timeout: probeTimeout)
        guard let binding = LaunchdServiceBinding(printResult: result, plistPath: daemon.path) else {
            throw CommandFailure(message: failure(launchctlCommandLine(arguments), result))
        }
        return binding
    }

    /// `launchctl`-Befehlszeile für Meldungen (ohne Pfad des Programms, wie in der App).
    private static func launchctlCommandLine(_ arguments: [String]) -> String {
        (["launchctl"] + arguments).joined(separator: " ")
    }

    /// Höchstlänge einer Befehlsausgabe in Fehlermeldungen, damit sie in der App lesbar bleiben.
    static let maximumDetailLength = 1_024

    private static func failure(_ command: String, _ result: CommandResult) -> String {
        let detail = shortened(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        return "\(command) fehlgeschlagen (Exit \(result.exitCode))" + (detail.isEmpty ? "" : ": \(detail)")
    }

    /// `text`, auf `maximumDetailLength` Zeichen gekürzt (dann mit „…“ am Ende).
    private static func shortened(_ text: String) -> String {
        text.count > maximumDetailLength ? text.prefix(maximumDetailLength) + "…" : text
    }
}
