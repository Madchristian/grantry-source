import Foundation

/// Beendet die Prozesse eines Lauschers; in der App `ProcessTerminator`.
public protocol ProcessTerminating: Sendable {
    /// Sendet SIGTERM (mit `force` SIGKILL) an alle Prozesse von `request` – nacheinander – und wartet, bis sie enden.
    func terminate(_ request: ProcessTerminationRequest, force: Bool) async -> ProcessTerminationReport
}

/// Beendet eine Liste von Prozessen ohne Lauscher-Bezug (verwaiste Agenten-Bäume, #221); in der App
/// `ProcessTerminator`.
public protocol ProcessListTerminating: Sendable {
    /// Sendet SIGTERM (mit `force` SIGKILL) an `processes` – nacheinander in dieser Reihenfolge – und wartet, bis sie
    /// enden.
    func terminate(_ processes: [RunningProcess], force: Bool) async -> ProcessTerminationReport
}

/// Eigene Prozesse (uid = `currentUID`) beendet die App über `OwnProcessSignaling`, fremde der Helper
/// (`PrivilegedProcessTerminating`), nacheinander in der Reihenfolge des Requests. Danach prüft er alle
/// `pollInterval`, höchstens `gracePeriod` lang (Spec: 250 ms, 5 s), ob die Prozesse enden. Beendet ist ein Prozess
/// erst, wenn seine PID fehlt oder neu vergeben ist (andere Startzeit, `ProcessEndWaiter`); läuft unter PID und Startzeit noch
/// etwas – auch mit anderem Programm oder Benutzer (exec, setuid) oder mit gerade nicht bestätigter Identität –, läuft
/// er weiter (#153, Befund 3 und Codex-Runde 3). Diese Prüfung gilt für zugestellte wie für ungewiss zugestellte
/// Signale gleichermaßen.
///
/// Scheitert ein Signal, kommt es auf den Fehler an (`mayHaveSignalled(after:)`):
/// - Nachweisliche Ablehnung **vor** dem Signal (`helperRequired`, Prüfung der App, Ablehnung durch den Helper): sofort
///   ein Fehler, ohne Wartezeit.
/// - Sonst (Helper nicht erreichbar bzw. Frist abgelaufen, das Signal kann verspätet ankommen,
///   `PrivilegedProcessTerminating`) prüft er den Prozess in der Wartezeit mit; ist er danach nicht beendet, bleibt
///   es ein Fehler.
///
/// Erst wenn **alle** Prozesse eines nicht leeren Requests beendet sind, vermerkt er den Lauscher im
/// `ListenerTerminationLedger`, damit er sofort aus der Liste fällt; bei Überlebenden oder Fehlern bleibt er stehen.
/// Ohne Lauscher (`terminate(_:force:)` mit Prozessliste, #221) wird nichts vermerkt.
public struct ProcessTerminator: ProcessTerminating, ProcessListTerminating {
    public static let defaultGracePeriod: Duration = .seconds(5)
    public static let defaultPollInterval: Duration = .milliseconds(250)

    private let own: any OwnProcessSignaling
    private let privileged: (any PrivilegedProcessTerminating)?
    private let ledger: ListenerTerminationLedger?
    private let currentUID: UInt32
    private let endWaiter: ProcessEndWaiter
    private let now: @Sendable () -> Date

    public init(
        own: any OwnProcessSignaling = OwnProcessSignaler(),
        privileged: (any PrivilegedProcessTerminating)?,
        inspector: any ProcessInspecting = LibprocProcessInspector(),
        ledger: ListenerTerminationLedger?,
        currentUID: UInt32 = getuid(),
        clock: any Clock<Duration> = ContinuousClock(),
        gracePeriod: Duration = defaultGracePeriod,
        pollInterval: Duration = defaultPollInterval,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.own = own
        self.privileged = privileged
        self.ledger = ledger
        self.currentUID = currentUID
        self.endWaiter = ProcessEndWaiter(inspector: inspector, clock: clock, gracePeriod: gracePeriod,
                                          pollInterval: pollInterval)
        self.now = now
    }

    public func terminate(_ request: ProcessTerminationRequest, force: Bool) async -> ProcessTerminationReport {
        let report = await terminate(request.processes, force: force)
        if report.allEnded, !request.processes.isEmpty { ledger?.record(request.listener.id, at: now()) }
        return report
    }

    public func terminate(_ processes: [RunningProcess], force: Bool) async -> ProcessTerminationReport {
        var signalled: [RunningProcess] = []
        var failures: [ProcessTerminationFailure] = []
        // Gescheitert, das Signal kann aber angekommen sein.
        var uncertain: [RunningProcess] = []
        for process in processes {
            do {
                try await send(to: process, force: force)
                signalled.append(process)
            } catch {
                failures.append(ProcessTerminationFailure(process: process, message: error.readableDescription))
                if Self.mayHaveSignalled(after: error) { uncertain.append(process) }
            }
        }
        let running = Set(await endWaiter.stillRunning(signalled + uncertain))
        let stillRunning = signalled.filter(running.contains)
        // Ein ungewiss zugestelltes Signal hat gewirkt, wenn der Prozess danach beendet ist.
        let remainingFailures = failures.filter { !uncertain.contains($0.process) || running.contains($0.process) }
        let unfinished = Set(stillRunning + remainingFailures.map(\.process))
        return ProcessTerminationReport(
            ended: processes.filter { !unfinished.contains($0) },
            stillRunning: stillRunning,
            failures: remainingFailures
        )
    }

    private func send(to process: RunningProcess, force: Bool) async throws {
        if process.uid == currentUID { return try own.signal(process, TerminationSignal(force: force)) }
        guard let privileged else { throw ProcessTerminationError.helperRequired }
        try await privileged.terminateProcess(
            pid: process.pid, executablePath: process.executablePath, startTime: process.startTime, force: force
        )
    }

    /// `false` bei nachweislicher Ablehnung vor dem Signal: Prüfung der App (`ProcessTerminationViolation`), kein Helper
    /// (`ProcessTerminationError`), Ablehnung oder veralteter Helper (`HelperClientError.rejected`/`.outdated`). Sonst –
    /// Helper nicht erreichbar oder Frist abgelaufen (`.unavailable`), unbekannte Fehler – `true`. Eine nicht angelegte
    /// Admin-Bestätigung (`ActionAuthorizationError`, TM9) scheitert vor dem Senden.
    static func mayHaveSignalled(after error: any Error) -> Bool {
        switch error {
        case is ProcessTerminationViolation, is ProcessTerminationError, is ActionAuthorizationError: false
        case let error as HelperClientError:
            if case .unavailable = error { true } else { false }
        default: true
        }
    }
}
