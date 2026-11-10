import Darwin
import Foundation
import GrantryShared
import os

/// Starten oder Stoppen im Tab „Dienste“.
public enum ServiceControlAction: String, Hashable, Sendable {
    case start, stop
}

/// Auftrag für einen Dienst; der Autostart-Eintrag stammt aus dem letzten Scan.
public struct ServiceControlRequest: Hashable, Sendable, Identifiable {
    public let action: ServiceControlAction
    public let item: AutostartItem

    public init(action: ServiceControlAction, item: AutostartItem) {
        self.action = action
        self.item = item
    }

    /// Auch `ActionRunner.runningRecordID`.
    public var id: String { "service:\(action.rawValue):\(item.id)" }

    public var confirmation: ActionConfirmation {
        switch action {
        case .start: .startService(item)
        case .stop: .stopService(item)
        }
    }

    var successMessage: String {
        switch action {
        case .start: "„\(item.label)“ wurde gestartet."
        case .stop: "„\(item.label)“ wurde gestoppt."
        }
    }

    /// Eintrag für den Verlauf (TM-9.5): Label und Benutzer, ohne PID, Pfad und Argumente.
    func record(userName: String, outcome: ActionOutcome) -> TaskActionRecord {
        TaskActionRecord(action: action == .start ? .startService : .stopService, processName: item.label, pid: nil,
                         userName: userName, outcome: outcome.failureMessage.map { .failed($0) } ?? .done)
    }
}

/// Startet (`launchctl kickstart`) und stoppt (`launchctl kill SIGTERM`) eigene LaunchAgents in `gui/<uid>` (Spec
/// 2026-11-06 §6, Stufe 4), ohne die Konfiguration zu ändern: Dauerhaft an- und abschalten bleibt Sache des Bereichs
/// „Autostart“ (`AutostartActions`). Erlaubt ist nur, was `ActionPolicy.serviceControlAvailability(for:)` freigibt;
/// vor dem Befehl prüft `LaunchdServiceProbe` frisch bei launchd, ob unter dem Label genau diese Plist geladen ist –
/// launchd führt Dienste nach Label, ein gleichnamiger fremder Dienst bliebe sonst nicht unberührt (wie in
/// `AutostartActions`). Jede ausgeführte Aktion steht im System-Protokoll (Kategorie `services`). System-Dienste
/// steuert erst der Helper (TM9).
///
/// An `launchctl` gehen nur feste Wörter (`print`, `kickstart`, `kill`, `SIGTERM`) und ein Ziel aus der festen Domäne
/// `gui/<uid>` und dem Label, dessen Syntax `PrivilegedOperationPolicy` vorher prüft (alphanumerischer Anfang, nur
/// `A-Za-z0-9._@+-`): keine Optionen, keine Pfade, kein Leerraum, keine Umgebung.
///
/// `launchctl kill` bestätigt nur die Zustellung des Signals. „Gestoppt“ meldet ein Stopp erst, wenn der vorher
/// geprüfte Prozess innerhalb von `gracePeriod` nachweislich endet (`ProcessEndWaiter`, wie „Task beenden“); läuft er
/// weiter oder ist sein Zustand unklar, ist das Ergebnis ein Fehler (`stillRunningAfterSignal`).
public struct ServiceControl: Sendable {
    static let notLoaded = "Der Dienst ist nicht geladen – erst im Bereich „Autostart“ aktivieren."
    static let notRunning = "Der Dienst läuft nicht."
    static let processNotVerifiable = "Der Prozess des Dienstes ließ sich nicht prüfen – nichts gestoppt."
    static let stillRunningAfterSignal = "Stoppsignal gesendet, der Dienst läuft aber noch."
    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "services")

    private let runner: any CommandRunning
    private let policy: ActionPolicy
    private let inspector: any ProcessInspecting
    private let uid: uid_t
    private let volumes: @Sendable () -> [MountedVolume]
    private let endWaiter: ProcessEndWaiter

    public init(runner: any CommandRunning = ProcessCommandRunner(), policy: ActionPolicy = ActionPolicy(),
                inspector: any ProcessInspecting = LibprocProcessInspector(allowingUnreadableExecutablePath: true),
                uid: uid_t = getuid(), gracePeriod: Duration = ProcessTerminator.defaultGracePeriod) {
        self.init(runner: runner, policy: policy, inspector: inspector, uid: uid, volumes: MountedVolume.current,
                  gracePeriod: gracePeriod)
    }

    init(runner: any CommandRunning, policy: ActionPolicy, inspector: any ProcessInspecting, uid: uid_t,
         volumes: @escaping @Sendable () -> [MountedVolume],
         gracePeriod: Duration = ProcessTerminator.defaultGracePeriod) {
        self.runner = runner
        self.policy = policy
        self.inspector = inspector
        self.uid = uid
        self.volumes = volumes
        endWaiter = ProcessEndWaiter(inspector: inspector, clock: ContinuousClock(), gracePeriod: gracePeriod,
                                     pollInterval: ProcessTerminator.defaultPollInterval)
    }

    /// - Throws: `ActionError.notAllowed` (Policy, Label-Kollision), `ActionError.commandFailed` (nicht geladen,
    ///   launchctl gescheitert), `PolicyViolation` für ungültige Labels – jeweils bevor ein verändernder Befehl läuft;
    ///   nach einem Stoppsignal `ActionError.commandFailed(stillRunningAfterSignal)`, wenn der Prozess nicht endet.
    public func perform(_ request: ServiceControlRequest) async throws {
        let item = request.item
        let mounts = volumes()
        if case .readOnly(let reason) = policy.serviceControlAvailability(for: item, volumes: mounts) {
            throw ActionError.notAllowed(reason)
        }
        guard let plist = item.plistPath else { throw ActionError.notAllowed(.noPlist) }
        try PrivilegedOperationPolicy().validateLabelSyntax(item.label)
        let domain = LaunchdServiceDomain.user(uid).name
        let state: LaunchdServiceState
        do {
            state = try await LaunchdServiceProbe(runner: runner).state(ofLabel: item.label, in: domain,
                                                                        toPlistAt: plist)
        } catch let error as LaunchdSourceError {
            throw ActionError.commandFailed(error.readableDescription)
        }
        switch state.binding {
        case .loadedFromPlist: break
        case .loadedFromElsewhere: throw ActionError.notAllowed(.conflictingService)
        case .notLoaded: throw ActionError.commandFailed(Self.notLoaded)
        }
        let target = "\(domain)/\(item.label)"
        switch request.action {
        case .start:
            try await launchctl(["kickstart", target], action: request.action, target: target)
        case .stop:
            let process = try checkProcessBeforeSignal(pid: state.pid, volumes: mounts)
            try await launchctl(["kill", "SIGTERM", target], action: request.action, target: target)
            guard await endWaiter.stillRunning([process]).isEmpty else {
                throw ActionError.commandFailed(Self.stillRunningAfterSignal)
            }
        }
    }

    private func launchctl(_ arguments: [String], action: ServiceControlAction, target: String) async throws {
        try await runner.runChecked(LaunchdSource.launchctl, arguments)
        Self.logger.notice("Dienst \(target, privacy: .public): \(action.rawValue, privacy: .public)")
    }

    /// Vor `kill SIGTERM`: Der Prozess, den launchd gerade unter dem Label führt (`pid` aus derselben `launchctl print`-
    /// Abfrage wie die Plist-Zuordnung), wird frisch gelesen und gegen die Schutzliste von „Task beenden“
    /// (`ProtectedProcesses.system`) geprüft. Die Policy kennt nur das Programm aus der Plist; ein Skript, das per `exec`
    /// ein anderes Programm startet, oder ein Dienst, der sich neu gestartet hat, zeigt hier sein tatsächliches Programm.
    /// Läuft kein Prozess, lässt sich seine Identität nicht bestätigen oder liegt sein Programm nicht sicher lokal (ein
    /// Pfadvergleich löste es sonst auf und träfe ein hängendes Netzlaufwerk), geht kein Signal hinaus. Liefert den
    /// geprüften Prozess, dessen Ende der Stopp danach nachweist.
    private func checkProcessBeforeSignal(pid: Int32?, volumes: [MountedVolume]) throws -> RunningProcess {
        guard let pid else { throw ActionError.commandFailed(Self.notRunning) }
        guard let process = inspector.process(pid) else { throw ActionError.commandFailed(Self.processNotVerifiable) }
        switch ProtectedProcesses.system.check(pid: process.pid, executablePath: process.executablePath, volumes: volumes) {
        case .protected: throw ActionError.notAllowed(.protectedProgram)
        case .unverifiable: throw ActionError.commandFailed(Self.processNotVerifiable)
        case .unprotected: return process
        }
    }

    /// Ergebnis für den `ActionRunner`: Fehler als lesbare Meldung.
    func outcome(of request: ServiceControlRequest) async -> ActionOutcome {
        do {
            try await perform(request)
            return .done
        } catch {
            return .failed(error.readableDescription)
        }
    }
}

extension ActionRunner {
    /// Starten bzw. Stoppen (nach Bestätigung) wie jede Aktion höchstens eine zur Zeit und nie während einer
    /// Helper-Installation; das Ergebnis erscheint im Kontext `.taskManager`. `nil`, wenn die Aktion nicht begonnen hat.
    @discardableResult
    public func control(_ request: ServiceControlRequest, using control: ServiceControl,
                        context: ActionContext = .taskManager) async -> ActionOutcome? {
        var finished: ActionOutcome?
        await run(recordID: request.id, context: context) { _ in
            await control.outcome(of: request)
        } present: { outcome in
            finished = outcome
            return ActionOutcomePresentation(outcome, successMessage: request.successMessage)
        }
        return finished
    }
}
