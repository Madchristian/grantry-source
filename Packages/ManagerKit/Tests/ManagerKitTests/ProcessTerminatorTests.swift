import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

/// Echte Signale nur an einen selbst gestarteten `/bin/sleep 30` (Leitplanke 5); sonst Fakes. Die Wartezeit läuft
/// über `InstantClock` – ohne echtes Warten.
@Suite struct ProcessTerminatorTests {
    /// Prozessliste, aus der Signale Prozesse entfernen können.
    /// Prozessliste, aus der Signale Prozesse entfernen können. `unconfirm` bildet einen laufenden Prozess nach, dessen
    /// Identität nicht bestätigt werden kann (`process(_:)` liefert `nil`, `liveness(of:)` meldet ihn laufend).
    private final class LiveTable: ProcessInspecting {
        private let processes: Mutex<[pid_t: RunningProcess]>
        private let unconfirmed = Mutex<Set<pid_t>>([])
        init(_ processes: [RunningProcess]) {
            self.processes = Mutex(Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first }))
        }
        func process(_ pid: pid_t) -> RunningProcess? {
            unconfirmed.withLock { $0.contains(pid) } ? nil : processes.withLock { $0[pid] }
        }
        func liveness(of pid: pid_t) -> ProcessLiveness {
            FixedProcessInspector.liveness(of: processes.withLock { $0[pid] })
        }
        func end(_ pid: pid_t) { _ = processes.withLock { $0.removeValue(forKey: pid) } }
        func replace(with process: RunningProcess) { processes.withLock { $0[process.pid] = process } }
        func unconfirm(_ pid: pid_t) { _ = unconfirmed.withLock { $0.insert(pid) } }
    }

    private final class OwnSignals: OwnProcessSignaling {
        let log = Mutex<[String]>([])
        let table: LiveTable
        let ignoring: Set<pid_t>
        let failure: (any Error)?
        init(table: LiveTable, ignoring: Set<pid_t> = [], failure: (any Error)? = nil) {
            self.table = table
            self.ignoring = ignoring
            self.failure = failure
        }
        func signal(_ process: RunningProcess, _ signal: TerminationSignal) throws {
            log.withLock { $0.append("\(signal.rawValue) \(process.pid)") }
            if let failure { throw failure }
            if !ignoring.contains(process.pid) { table.end(process.pid) }
        }
    }

    private final class HelperSignals: PrivilegedProcessTerminating {
        /// Was der Aufruf an der Prozessliste bewirkt.
        enum Effect {
            case end, none
            /// Unter der PID steht danach ein anderer Prozess.
            case replace(RunningProcess)
        }

        let log = Mutex<[String]>([])
        let table: LiveTable
        let failure: (any Error)?
        let effect: Effect
        init(table: LiveTable, failure: (any Error)? = nil, effect: Effect = .end) {
            self.table = table
            self.failure = failure
            self.effect = effect
        }
        func terminateProcess(pid: Int32, executablePath: String, startTime: UInt64, force: Bool) async throws {
            log.withLock { $0.append("\(force ? "SIGKILL" : "SIGTERM") \(pid) \(startTime)") }
            switch effect {
            case .end: table.end(pid)
            case .none: break
            case .replace(let process): table.replace(with: process)
            }
            if let failure { throw failure }
        }
    }

    /// Uhr ohne echtes Warten: Jeder Schlaf kehrt sofort zurück und wird protokolliert; `afterSleep` erhält die Zahl
    /// der bisherigen Schläfe (etwa, um einen Prozess nach dem dritten Prüfen enden zu lassen).
    private final class InstantClock: Clock, Sendable {
        private let state = Mutex((now: TestClock.Instant.start, sleeps: [Duration]()))
        private let afterSleep: @Sendable (Int) -> Void

        init(afterSleep: @escaping @Sendable (Int) -> Void = { _ in }) { self.afterSleep = afterSleep }

        var now: TestClock.Instant { state.withLock { $0.now } }
        var minimumResolution: Duration { .zero }
        var sleeps: [Duration] { state.withLock { $0.sleeps } }

        func sleep(until deadline: TestClock.Instant, tolerance: Duration?) async throws {
            let count = state.withLock { state in
                state.sleeps.append(state.now.duration(to: deadline))
                state.now = deadline
                return state.sleeps.count
            }
            afterSleep(count)
        }
    }

    private static let own = RunningProcess(pid: 10, uid: 501, executablePath: "/opt/homebrew/bin/node", startTime: 1)
    private static let root = RunningProcess(pid: 20, uid: 0, executablePath: "/opt/homebrew/bin/node", startTime: 1)
    private let ledger = ListenerTerminationLedger(retention: 600)

    private func terminator(
        own: OwnSignals, helper: HelperSignals?, table: LiveTable, clock: InstantClock = InstantClock()
    ) -> ProcessTerminator {
        ProcessTerminator(own: own, privileged: helper, inspector: table, ledger: ledger, currentUID: 501,
                          clock: clock, now: { TestData.date })
    }

    private func request(_ processes: [RunningProcess]) -> ProcessTerminationRequest {
        ProcessTerminationRequest(listener: TestData.listener(), processes: processes)
    }

    private var recordedIDs: Set<String> { ledger.settleEndedIDs(at: TestData.date, seen: []) }

    @Test func ownByAppForeignByHelperInRequestOrder() async {
        let table = LiveTable([Self.own, Self.root])
        let own = OwnSignals(table: table)
        let helper = HelperSignals(table: table)
        let report = await terminator(own: own, helper: helper, table: table).terminate(request([Self.own, Self.root]), force: false)
        #expect(report == ProcessTerminationReport(ended: [Self.own, Self.root]))
        #expect(own.log.withLock { $0 } == ["SIGTERM 10"])
        #expect(helper.log.withLock { $0 } == ["SIGTERM 20 1"])
        #expect(recordedIDs == [TestData.listener().id])
    }

    @Test func endedProcessesNeedNoWait() async {
        let table = LiveTable([Self.own])
        let clock = InstantClock()
        _ = await terminator(own: OwnSignals(table: table), helper: nil, table: table, clock: clock)
            .terminate(request([Self.own]), force: false)
        #expect(clock.sleeps.isEmpty)
    }

    /// Prüft alle 250 ms und hört auf, sobald alle Prozesse beendet sind.
    @Test func pollsUntilTheProcessEnds() async {
        let table = LiveTable([Self.own])
        let clock = InstantClock { count in if count == 3 { table.end(Self.own.pid) } }
        let report = await terminator(own: OwnSignals(table: table, ignoring: [10]), helper: nil, table: table, clock: clock)
            .terminate(request([Self.own]), force: false)
        #expect(report == ProcessTerminationReport(ended: [Self.own]))
        #expect(clock.sleeps == Array(repeating: .milliseconds(250), count: 3))
        #expect(recordedIDs == [TestData.listener().id])
    }

    /// Höchstens 5 s (20 × 250 ms); danach meldet der Bericht den Überlebenden, und nichts wird vermerkt.
    @Test func survivorIsReportedAfterFiveSecondsAndNotRecorded() async {
        let table = LiveTable([Self.own])
        let clock = InstantClock()
        let report = await terminator(own: OwnSignals(table: table, ignoring: [10]), helper: nil, table: table, clock: clock)
            .terminate(request([Self.own]), force: false)
        #expect(report == ProcessTerminationReport(stillRunning: [Self.own]))
        #expect(clock.sleeps == Array(repeating: .milliseconds(250), count: 20))
        #expect(recordedIDs.isEmpty)
    }

    @Test func partialEndIsNotRecorded() async {
        let table = LiveTable([Self.own, Self.root])
        let report = await terminator(own: OwnSignals(table: table), helper: nil, table: table)
            .terminate(request([Self.own, Self.root]), force: false)
        #expect(report.ended == [Self.own] && report.failures.map(\.process) == [Self.root])
        #expect(recordedIDs.isEmpty)
    }

    /// Eine neu vergebene PID (andere Startzeit) zählt als beendet.
    @Test func reusedPIDCountsAsEnded() async {
        let table = LiveTable([Self.own])
        let clock = InstantClock { _ in
            table.replace(with: RunningProcess(pid: 10, uid: 501, executablePath: "/opt/homebrew/bin/node", startTime: 2))
        }
        let report = await terminator(own: OwnSignals(table: table, ignoring: [10]), helper: nil, table: table, clock: clock)
            .terminate(request([Self.own]), force: false)
        #expect(report == ProcessTerminationReport(ended: [Self.own]))
    }

    @Test func forceSendsSIGKILL() async {
        let table = LiveTable([Self.own, Self.root])
        let own = OwnSignals(table: table)
        let helper = HelperSignals(table: table)
        _ = await terminator(own: own, helper: helper, table: table).terminate(request([Self.own, Self.root]), force: true)
        #expect(own.log.withLock { $0 } == ["SIGKILL 10"])
        #expect(helper.log.withLock { $0 } == ["SIGKILL 20 1"])
    }

    @Test func failuresAreCollectedPerProcess() async {
        let table = LiveTable([Self.own, Self.root])
        let own = OwnSignals(table: table, failure: ProcessTerminationViolation.processChanged(10))
        let report = await terminator(own: own, helper: nil, table: table).terminate(request([Self.own, Self.root]), force: false)
        #expect(report.failures == [
            ProcessTerminationFailure(process: Self.own, message: "Prozess 10 hat sich geändert – Aktion abgebrochen"),
            ProcessTerminationFailure(process: Self.root, message: ProcessTerminationError.helperRequired.errorDescription ?? ""),
        ])
        #expect(report.ended.isEmpty && report.stillRunning.isEmpty)
        #expect(recordedIDs.isEmpty)
    }

    /// Ein Helper-Aufruf kann nach dem Senden scheitern (etwa Frist abgelaufen) und trotzdem gewirkt haben: Ist der
    /// Prozess danach weg, zählt er als beendet (Abgleich nach Task 3).
    @Test func failedCallWhoseProcessIsGoneCountsAsEnded() async {
        let table = LiveTable([Self.root])
        let helper = HelperSignals(table: table, failure: HelperClientError.unavailable("Frist abgelaufen"))
        let report = await terminator(own: OwnSignals(table: table), helper: helper, table: table)
            .terminate(request([Self.root]), force: false)
        #expect(report == ProcessTerminationReport(ended: [Self.root]))
        #expect(recordedIDs == [TestData.listener().id])
    }

    /// Nachweisliche Ablehnungen vor dem Signal (`helperRequired`, Prüfung der App) sind sofort Fehler: Die Uhr rückt
    /// nicht vor.
    @Test func rejectionsBeforeTheSignalNeedNoWait() async {
        let table = LiveTable([Self.own, Self.root])
        let clock = InstantClock()
        let own = OwnSignals(table: table, failure: ProcessTerminationViolation.notPermitted(10))
        let report = await terminator(own: own, helper: nil, table: table, clock: clock)
            .terminate(request([Self.own, Self.root]), force: false)
        #expect(report.failures.map(\.process) == [Self.own, Self.root])
        #expect(clock.sleeps.isEmpty)
        #expect(recordedIDs.isEmpty)
    }

    /// Lehnt der Helper ab (`rejected`, `outdated`), ging kein Signal: sofort Fehler, auch wenn der Prozess fehlt.
    @Test(arguments: [HelperClientError.rejected("Apple-Programme beendet der Helper nicht: node"), .outdated])
    func helperRejectionNeedsNoWait(_ error: HelperClientError) async {
        let table = LiveTable([Self.root])
        let clock = InstantClock()
        let helper = HelperSignals(table: table, failure: error, effect: .none)
        let report = await terminator(own: OwnSignals(table: table), helper: helper, table: table, clock: clock)
            .terminate(request([Self.root]), force: false)
        #expect(report.failures == [ProcessTerminationFailure(process: Self.root, message: error.readableDescription)])
        #expect(clock.sleeps.isEmpty)
    }

    /// Gescheitert, und unter der PID läuft ein neuer Prozess (andere Startzeit): Der alte ist weg.
    @Test func failedCallWithReusedPIDCountsAsEnded() async {
        let table = LiveTable([Self.root])
        let reused = RunningProcess(pid: 20, uid: 0, executablePath: "/opt/homebrew/bin/node", startTime: 2)
        let helper = HelperSignals(table: table, failure: HelperClientError.unavailable("Frist abgelaufen"), effect: .replace(reused))
        let report = await terminator(own: OwnSignals(table: table), helper: helper, table: table)
            .terminate(request([Self.root]), force: false)
        #expect(report == ProcessTerminationReport(ended: [Self.root]))
    }

    /// #153, Befund 3: Nach einem **zugestellten** SIGTERM wechselt der Prozess sein Programm (exec) oder seinen
    /// Benutzer – PID und Startzeit bleiben. Er läuft weiter: kein Erfolg, SIGKILL-Angebot, kein Vermerk.
    @Test(arguments: [
        RunningProcess(pid: 20, uid: 0, executablePath: "/usr/local/bin/other", startTime: 1),
        RunningProcess(pid: 20, uid: 65534, executablePath: "/opt/homebrew/bin/node", startTime: 1),
    ])
    func changedProgramOrUserAfterDeliveredSignalIsStillRunning(_ changed: RunningProcess) async {
        let table = LiveTable([Self.root])
        let clock = InstantClock()
        let helper = HelperSignals(table: table, effect: .replace(changed))
        let report = await terminator(own: OwnSignals(table: table), helper: helper, table: table, clock: clock)
            .terminate(request([Self.root]), force: false)
        #expect(report == ProcessTerminationReport(stillRunning: [Self.root]))
        #expect(clock.sleeps.count == 20)
        #expect(recordedIDs.isEmpty)
    }

    /// #153, Codex-Runde 3: Der Dienst führt nach SIGTERM ein `exec` aus, das zwischen die beiden Token-Lesungen des
    /// Inspektors fällt – `process(_:)` liefert `nil`, PID und Startzeit bestehen aber. Das ist kein Exitnachweis: Er
    /// wird bis zum Ende der Wartezeit weiter geprüft, gilt als laufend (SIGKILL-Angebot), und nichts wird vermerkt.
    @Test func execBetweenTokenReadsIsNotAnExit() async {
        let table = LiveTable([Self.own, Self.root])
        let clock = InstantClock()
        let own = OwnSignals(table: table, ignoring: [10])
        let helper = HelperSignals(table: table, effect: .none)
        table.unconfirm(Self.own.pid)
        table.unconfirm(Self.root.pid)
        let report = await terminator(own: own, helper: helper, table: table, clock: clock)
            .terminate(request([Self.own, Self.root]), force: false)
        #expect(report == ProcessTerminationReport(stillRunning: [Self.own, Self.root]))
        #expect(clock.sleeps.count == 20)
        #expect(recordedIDs.isEmpty)
    }

    /// Ungewisse Messungen werden weiter gepollt: Endet der Prozess später wirklich, zählt er als beendet.
    @Test func unconfirmedProcessIsPolledUntilItReallyEnds() async {
        let table = LiveTable([Self.own])
        table.unconfirm(Self.own.pid)
        let clock = InstantClock { count in if count == 4 { table.end(Self.own.pid) } }
        let report = await terminator(own: OwnSignals(table: table, ignoring: [10]), helper: nil, table: table, clock: clock)
            .terminate(request([Self.own]), force: false)
        #expect(report == ProcessTerminationReport(ended: [Self.own]))
        #expect(clock.sleeps.count == 4)
        #expect(recordedIDs == [TestData.listener().id])
    }

    /// Gleiche PID und Startzeit, nur ein anderes Programm (exec): Der Prozess ist nicht weg – das gescheiterte Signal
    /// bleibt ein Fehler, und nichts wird vermerkt.
    @Test func failedCallAfterExecStaysAFailure() async {
        let table = LiveTable([Self.root])
        let execed = RunningProcess(pid: 20, uid: 0, executablePath: "/usr/local/bin/other", startTime: 1)
        let helper = HelperSignals(table: table, failure: HelperClientError.unavailable("Frist abgelaufen"), effect: .replace(execed))
        let report = await terminator(own: OwnSignals(table: table), helper: helper, table: table)
            .terminate(request([Self.root]), force: false)
        #expect(report.failures.map(\.process) == [Self.root])
        #expect(report.ended.isEmpty && report.stillRunning.isEmpty)
        #expect(recordedIDs.isEmpty)
    }

    /// Ein verspätet ankommendes Helper-Signal wird innerhalb der Wartezeit erkannt.
    @Test func lateHelperSignalWithinGracePeriodCountsAsEnded() async {
        let table = LiveTable([Self.root])
        let clock = InstantClock { count in if count == 2 { table.end(Self.root.pid) } }
        let helper = HelperSignals(table: table, failure: HelperClientError.unavailable("Frist abgelaufen"), effect: .none)
        let report = await terminator(own: OwnSignals(table: table), helper: helper, table: table, clock: clock)
            .terminate(request([Self.root]), force: false)
        #expect(report == ProcessTerminationReport(ended: [Self.root]))
        #expect(clock.sleeps.count == 2)
        #expect(recordedIDs == [TestData.listener().id])
    }

    @Test func emptyRequestRecordsNothing() async {
        let table = LiveTable([])
        let report = await terminator(own: OwnSignals(table: table), helper: nil, table: table).terminate(request([]), force: false)
        #expect(report == ProcessTerminationReport())
        #expect(recordedIDs.isEmpty)
    }

    /// Vorgabe des `ActionCoordinator` ohne Verdrahtung: kein Signal, je Prozess ein Fehler.
    @Test func unavailableTerminationFailsEveryProcess() async {
        let report = await UnavailableProcessTermination().terminate(request([Self.own, Self.root]), force: false)
        #expect(report == ProcessTerminationReport(failures: [
            ProcessTerminationFailure(process: Self.own, message: UnavailableProcessTermination.reason),
            ProcessTerminationFailure(process: Self.root, message: UnavailableProcessTermination.reason),
        ]))
    }

    /// Integration (Leitplanke 5): eigener Kindprozess, echte Prüfung, echtes `kill`, echte Lebendprüfung. Nur der
    /// Lauscher ist vorgegeben – `/bin/sleep` lauscht nicht.
    @Test(.timeLimit(.minutes(1))) func endsOwnChildForReal() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let process = try #require(LibprocProcessInspector().process(child.processIdentifier))
        let listening = ListeningRequirement(checker: FixedListeningPIDs([process.pid]))
        let own = OwnProcessSignaler(policy: .app(listening: listening))
        let report = await ProcessTerminator(own: own, privileged: nil, ledger: ledger, pollInterval: .milliseconds(50))
            .terminate(request([process]), force: false)
        #expect(report == ProcessTerminationReport(ended: [process]))
    }
}
