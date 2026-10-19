import Foundation
import GrantryShared

/// Ausgang je Posten des Segments „Prozesse“ (#221); `logEntry` ist die Zeile im `CleanupLog`.
public struct ProcessCleanupOutcome: Hashable, Sendable {
    public enum Target: Hashable, Sendable {
        case tree(AgentProcessTree)
        case simulator(BootedSimulator)
    }

    public let target: Target
    public let result: StorageCleanOutcome.Result
    /// Nach SIGTERM noch laufende Prozesse: Angebot „Sofort beenden (SIGKILL) …“; nach SIGKILL immer leer.
    public let survivors: [RunningProcess]

    init(_ target: Target, _ result: StorageCleanOutcome.Result, survivors: [RunningProcess] = []) {
        self.target = target
        self.result = result
        self.survivors = survivors
    }

    /// Lesbarer Posten ohne Befehlszeile (sie kann Geheimnisse tragen).
    public var title: String {
        switch target {
        case .tree(let tree): tree.title
        case .simulator(let simulator): "Simulator \(simulator.title)"
        }
    }

    /// Speicher laut Scan; `nil`, wenn unbekannt. Kein Festplattenplatz, deshalb nie als `freedBytes` protokolliert.
    public var memoryBytes: UInt64? {
        switch target {
        case .tree(let tree): tree.memoryBytes
        case .simulator(let simulator): simulator.memoryBytes
        }
    }

    public var logEntry: StorageCleanOutcome {
        switch target {
        case .tree: StorageCleanOutcome(categoryID: ProcessCleaner.treeCategoryID, target: title, method: .signal,
                                        freedBytes: nil, result: result)
        case .simulator(let simulator):
            StorageCleanOutcome(categoryID: ProcessCleaner.simulatorCategoryID, target: simulator.shutdownCommand.commandLine,
                                method: .command, freedBytes: nil, result: result)
        }
    }
}

/// Führt die bestätigte Auswahl des Segments „Prozesse“ aus (#221). Automatisch beendet er nie etwas.
///
/// **Agenten-Bäume:** Unmittelbar vor dem Signal liest er die Prozesstabelle neu und sucht den Baum (PID und Startzeit
/// der Wurzel) erneut mit dem `OrphanAgentTreeDetector`. Nur wenn er dort noch als verwaist gilt, gehen Signale an
/// seine **aktuellen** Mitglieder – Wurzel zuerst, dann der Unterbaum. So trifft das Beenden keinen Codex-Broker, den
/// inzwischen eine neue Sitzung übernommen hat. Das Signal selbst geht über `OwnProcessSignaler` mit
/// `ProcessTerminationPolicy.orphanedAgentProcess()`: nur eigene Prozesse, Pfad, Benutzer und Startzeit unverändert,
/// Grantry und Helper geschützt, Zustellung an die geprüfte Prozessgeneration (#153). SIGKILL nur über
/// `forceTerminate(_:)` nach eigener Bestätigung, und nur an die Überlebenden des SIGTERM.
///
/// **Simulatoren:** `xcrun simctl shutdown <udid>`.
public struct ProcessCleaner: Sendable {
    static let treeCategoryID = "agentTree"
    static let simulatorCategoryID = "simulator"
    static let goneReason = "Läuft nicht mehr"
    static let inUseReason = "Gehört inzwischen zu einer laufenden Sitzung"

    private let table: any ProcessTableReading
    private let detector: OrphanAgentTreeDetector
    private let terminator: any ProcessListTerminating
    private let runner: any CommandRunning

    init(table: any ProcessTableReading, detector: OrphanAgentTreeDetector, terminator: any ProcessListTerminating,
         runner: any CommandRunning) {
        self.table = table
        self.detector = detector
        self.terminator = terminator
        self.runner = runner
    }

    /// Mit den echten Abhängigkeiten der App; ohne Helper (nur eigene Prozesse).
    public init() {
        self.init(
            table: LibprocProcessTable(), detector: OrphanAgentTreeDetector(),
            terminator: ProcessTerminator(own: OwnProcessSignaler(policy: .orphanedAgentProcess()), privileged: nil,
                                          ledger: nil),
            runner: ProcessCommandRunner()
        )
    }

    /// SIGTERM an den neu bestätigten Baum.
    public func terminate(_ tree: AgentProcessTree) async -> ProcessCleanupOutcome {
        let entries: [ProcessEntry], scan: AgentTreeScan
        do {
            (entries, scan) = try await ProcessOverviewScanner.queue.runThrowing { [table, detector] in
                let entries = try table.entries()
                return (entries, detector.scan(entries))
            }
        } catch {
            return ProcessCleanupOutcome(.tree(tree), .failed(error.readableDescription))
        }
        guard let current = scan.orphans.first(where: { $0.id == tree.id }) else {
            let rootRuns = entries.contains { $0.pid == tree.root.pid && $0.startTime == tree.root.startTime }
            return ProcessCleanupOutcome(.tree(tree), .skipped(rootRuns ? Self.inUseReason : Self.goneReason))
        }
        return await signal(current.members.map(\.runningProcess), of: .tree(current), force: false)
    }

    /// SIGKILL an die Überlebenden eines vorherigen SIGTERM; ihre Identität (Pfad, Benutzer, Startzeit) prüft die Policy.
    public func forceTerminate(_ outcome: ProcessCleanupOutcome) async -> ProcessCleanupOutcome {
        guard !outcome.survivors.isEmpty else { return outcome }
        return await signal(outcome.survivors, of: outcome.target, force: true)
    }

    public func shutdown(_ simulator: BootedSimulator) async -> ProcessCleanupOutcome {
        let command = simulator.shutdownCommand
        do {
            let result = try await runner.run(command.executable, command.arguments, timeout: BootedSimulatorReader.timeout)
            guard result.succeeded else {
                return ProcessCleanupOutcome(.simulator(simulator),
                                             .failed(BootedSimulatorError(message: result.stderr).readableDescription))
            }
            return ProcessCleanupOutcome(.simulator(simulator), .removed)
        } catch {
            return ProcessCleanupOutcome(.simulator(simulator), .failed(error.readableDescription))
        }
    }

    private func signal(_ processes: [RunningProcess], of target: ProcessCleanupOutcome.Target,
                        force: Bool) async -> ProcessCleanupOutcome {
        let report = await terminator.terminate(processes, force: force)
        do {
            guard let warning = try ActionCoordinator.warning(after: report, force: force) else {
                return ProcessCleanupOutcome(target, .removed)
            }
            return ProcessCleanupOutcome(target, .failed(warning), survivors: force ? [] : report.stillRunning)
        } catch {
            return ProcessCleanupOutcome(target, .failed(error.readableDescription))
        }
    }
}
