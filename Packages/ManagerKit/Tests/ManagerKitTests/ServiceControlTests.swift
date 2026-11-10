import Foundation
import GrantryShared
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct ServiceControlTests {
    static let plist = "/Users/mara/Library/LaunchAgents/com.example.agent.plist"
    static let item = AutostartItem(kind: .launchAgent, domain: .user, label: "com.example.agent",
                                    program: "/usr/local/bin/agent", programPresence: .present, isEnabled: true,
                                    isLoaded: true, plistPath: plist, owner: nil, source: .launchd)
    static let printLine = "/bin/launchctl print gui/501/com.example.agent"
    static let kickstart = "/bin/launchctl kickstart gui/501/com.example.agent"
    static let kill = "/bin/launchctl kill SIGTERM gui/501/com.example.agent"
    static let succeeded = CommandResult(exitCode: 0, stdout: "")

    /// Der laufende Prozess des Dienstes (PID 4242 in `loaded(pid:)`).
    static let agentProcess = RunningProcess(pid: 4242, uid: 501, executablePath: "/usr/local/bin/agent", startTime: 9)

    /// Antwort von `launchctl print gui/501/<label>` für einen aus `path` geladenen Dienst, mit `pid`, solange er läuft.
    static func loaded(from path: String = plist, pid: Int32? = nil) -> CommandResult {
        let pidLine = pid.map { "\tpid = \($0)\n" } ?? ""
        return CommandResult(exitCode: 0, stdout: "gui/501/com.example.agent = {\n\tactive count = 1\n\tpath = \(path)\n\(pidLine)}\n")
    }

    /// `running` ist die Prozesstabelle; `unconfirmed` sind PIDs, deren Identität sich nicht bestätigen lässt. Die
    /// Tabelle ändert sich nicht: Ein Stopp wartet ohne Frist und findet den Prozess danach noch.
    private func control(_ runner: MockCommandRunner, running: [RunningProcess] = [agentProcess],
                         unconfirmed: Set<pid_t> = []) -> ServiceControl {
        control(runner, inspector: FixedProcessInspector(running, unconfirmed: unconfirmed))
    }

    func control(_ runner: MockCommandRunner, inspector: any ProcessInspecting) -> ServiceControl {
        ServiceControl(runner: runner, inspector: inspector, uid: 501, gracePeriod: .zero)
    }

    private func stop(_ item: AutostartItem = item) -> ServiceControlRequest {
        ServiceControlRequest(action: .stop, item: item)
    }

    @Test func startKickstartsAfterCheckingThePlist() async throws {
        let runner = MockCommandRunner([Self.printLine: Self.loaded(), Self.kickstart: Self.succeeded])
        try await control(runner).perform(ServiceControlRequest(action: .start, item: Self.item))
        #expect(runner.calls == [Self.printLine, Self.kickstart])
    }

    @Test func stopSendsSIGTERMThroughLaunchd() async throws {
        let runner = MockCommandRunner([Self.printLine: Self.loaded(pid: 4242), Self.kill: Self.succeeded])
        try await control(runner, inspector: EndsAfterSignalInspector(Self.agentProcess)).perform(stop())
        #expect(runner.calls == [Self.printLine, Self.kill])
    }

    // MARK: Ende erst nach Nachweis (Codex-Review PR 356, Befund 2)

    /// `launchctl kill` meldet nur, dass launchd das Signal zugestellt hat. Ein Agent, der SIGTERM ignoriert oder im
    /// Shutdown hängt, läuft weiter – das ist kein „gestoppt“.
    @Test func stopOfAProcessThatKeepsRunningIsNotReportedAsStopped() async {
        let runner = MockCommandRunner([Self.printLine: Self.loaded(pid: 4242), Self.kill: Self.succeeded])
        let outcome = await control(runner).outcome(of: stop())
        #expect(outcome == .failed(ServiceControl.stillRunningAfterSignal))
        #expect(runner.calls == [Self.printLine, Self.kill])
    }

    @Test func stopIsReportedOnceTheProcessHasEnded() async {
        let runner = MockCommandRunner([Self.printLine: Self.loaded(pid: 4242), Self.kill: Self.succeeded])
        let outcome = await control(runner, inspector: EndsAfterSignalInspector(Self.agentProcess)).outcome(of: stop())
        #expect(outcome == .done)
    }

    /// Ein KeepAlive-Neustart vergibt dieselbe PID höchstens mit neuer Startzeit: Der gestoppte Prozess ist beendet.
    @Test func restartUnderTheSamePIDCountsAsEnded() async {
        let runner = MockCommandRunner([Self.printLine: Self.loaded(pid: 4242), Self.kill: Self.succeeded])
        let restarted = EndsAfterSignalInspector(Self.agentProcess, afterwards: .running(startTime: 10))
        #expect(await control(runner, inspector: restarted).outcome(of: stop()) == .done)
    }

    /// Ein nicht feststellbarer Zustand belegt kein Ende.
    @Test func unknownStateAfterTheSignalIsNotReportedAsStopped() async {
        let runner = MockCommandRunner([Self.printLine: Self.loaded(pid: 4242), Self.kill: Self.succeeded])
        let unknown = EndsAfterSignalInspector(Self.agentProcess, afterwards: .unknown)
        #expect(await control(runner, inspector: unknown).outcome(of: stop())
            == .failed(ServiceControl.stillRunningAfterSignal))
    }

    @Test func serviceFromAnotherPlistIsNotTouched() async {
        let runner = MockCommandRunner([Self.printLine: Self.loaded(from: "/Library/LaunchAgents/other.plist")])
        await #expect(throws: ActionError.notAllowed(.conflictingService)) {
            try await control(runner).perform(ServiceControlRequest(action: .start, item: Self.item))
        }
        #expect(runner.calls == [Self.printLine])
    }

    @Test func notLoadedServiceIsReported() async {
        let runner = MockCommandRunner([Self.printLine: CommandResult(exitCode: 113, stdout: "")])
        await #expect(throws: ActionError.commandFailed(ServiceControl.notLoaded)) {
            try await control(runner).perform(ServiceControlRequest(action: .start, item: Self.item))
        }
    }

    @Test func agentOutsideHomeIsRefusedBeforeAnyCommand() async {
        var item = Self.item
        item.domain = .system
        item.plistPath = "/Library/LaunchAgents/com.example.agent.plist"
        let runner = MockCommandRunner()
        await #expect(throws: ActionError.notAllowed(.notOwnAgent)) {
            try await control(runner, inspector: EndsAfterSignalInspector(Self.agentProcess)).perform(stop(item))
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func failingLaunchctlBecomesReadableOutcome() async {
        let runner = MockCommandRunner([Self.printLine: Self.loaded(),
                                        Self.kickstart: CommandResult(exitCode: 1, stdout: "", stderr: "boom")])
        let outcome = await control(runner).outcome(of: ServiceControlRequest(action: .start, item: Self.item))
        guard case .failed(let message) = outcome else {
            Issue.record("erwartet .failed, war \(outcome)")
            return
        }
        #expect(message.contains("launchctl kickstart gui/501/com.example.agent fehlgeschlagen (Exit 1)"))
    }

    @Test func confirmationsNameTheService() {
        #expect(ActionConfirmation.startService(Self.item).title == "„com.example.agent“ starten?")
        #expect(!ActionConfirmation.startService(Self.item).isDestructive)
        #expect(ActionConfirmation.stopService(Self.item).confirmTitle == "Stoppen")
        #expect(ActionConfirmation.stopService(Self.item).note?.contains("KeepAlive") == true)
    }

    // MARK: Schutzliste: kein geschützter Prozess bekommt ein Signal (Master-Auftrag B)

    /// Die Policy prüft das Programm aus der Plist; hier steht dort ein harmloses Programm, der laufende Prozess ist aber
    /// ein geschützter (etwa ein Skript, das per `exec` ein anderes Programm startet).
    @Test(arguments: ProtectedProcesses.system.entries)
    func stopNeverSignalsAProtectedProcess(entry: ProtectedProcesses.Entry) async {
        let process = RunningProcess(pid: 4242, uid: 501, executablePath: entry.path, startTime: 9)
        let runner = MockCommandRunner([Self.printLine: Self.loaded(pid: 4242), Self.kill: Self.succeeded])
        await #expect(throws: ActionError.notAllowed(.protectedProgram)) {
            try await control(runner, running: [process]).perform(stop())
        }
        #expect(runner.calls == [Self.printLine])
    }

    @Test func stopNeverSignalsPIDOneWhateverItsPath() async {
        let launchd = RunningProcess(pid: 1, uid: 0, executablePath: "/x/not-launchd", startTime: 1)
        let runner = MockCommandRunner([Self.printLine: Self.loaded(pid: 1), Self.kill: Self.succeeded])
        await #expect(throws: ActionError.notAllowed(.protectedProgram)) {
            try await control(runner, running: [launchd]).perform(stop())
        }
        #expect(runner.calls == [Self.printLine])
    }

    @Test func stopWithAProcessWhoseIdentityIsNotConfirmedSignalsNothing() async {
        let runner = MockCommandRunner([Self.printLine: Self.loaded(pid: 4242), Self.kill: Self.succeeded])
        await #expect(throws: ActionError.commandFailed(ServiceControl.processNotVerifiable)) {
            try await control(runner, unconfirmed: [4242]).perform(stop())
        }
        #expect(runner.calls == [Self.printLine])
    }

    // MARK: Programm nicht sicher lokal (Codex-Review PR 356, P2)

    /// Netzlaufwerk `/Volumes/NAS`; alles andere liegt lokal.
    static let volumes = [MountedVolume(path: "/", isLocal: true), MountedVolume(path: "/Volumes/NAS", isLocal: false)]

    private func controlWithNetworkVolume(_ runner: MockCommandRunner, running: [RunningProcess]) -> ServiceControl {
        ServiceControl(runner: runner, policy: ActionPolicy(), inspector: FixedProcessInspector(running), uid: 501,
                       volumes: { Self.volumes })
    }

    /// Start und Stopp gehen durch dieselbe Policy wie die Zeilen des Tabs: Ein Programm auf dem Netzlaufwerk bekommt
    /// keinen Befehl, und der Pfad wird nie kanonisiert.
    @Test(arguments: [ServiceControlAction.start, .stop])
    func programOnANetworkVolumeIsRefusedBeforeAnyCommand(action: ServiceControlAction) async {
        var item = Self.item
        item.program = "/Volumes/NAS/bin/agent"
        let runner = MockCommandRunner()
        await #expect(throws: ActionError.notAllowed(.unverifiableProgram)) {
            try await controlWithNetworkVolume(runner, running: [Self.agentProcess])
                .perform(ServiceControlRequest(action: action, item: item))
        }
        #expect(runner.calls.isEmpty)
    }

    /// Die Policy kennt nur das Programm der Plist; der laufende Prozess (etwa per `exec` gestartet) kann auf dem
    /// Netzlaufwerk liegen. Seinen Pfad löst Grantry nicht auf, also geht kein Signal hinaus.
    @Test func stopOfAProcessOnANetworkVolumeSignalsNothing() async {
        let process = RunningProcess(pid: 4242, uid: 501, executablePath: "/Volumes/NAS/bin/agent", startTime: 9)
        let runner = MockCommandRunner([Self.printLine: Self.loaded(pid: 4242), Self.kill: Self.succeeded])
        await #expect(throws: ActionError.commandFailed(ServiceControl.processNotVerifiable)) {
            try await controlWithNetworkVolume(runner, running: [process]).perform(stop())
        }
        #expect(runner.calls == [Self.printLine])
    }

    @Test func stopOfAServiceWithoutProcessSignalsNothing() async {
        let runner = MockCommandRunner([Self.printLine: Self.loaded(), Self.kill: Self.succeeded])
        await #expect(throws: ActionError.commandFailed(ServiceControl.notRunning)) {
            try await control(runner).perform(stop())
        }
        #expect(runner.calls == [Self.printLine])
    }

    /// Starten sendet kein Signal: Der Prozess muss weder laufen noch geprüft werden.
    @Test func startNeedsNoProcessCheck() async throws {
        let runner = MockCommandRunner([Self.printLine: Self.loaded(), Self.kickstart: Self.succeeded])
        try await control(runner, running: []).perform(ServiceControlRequest(action: .start, item: Self.item))
        #expect(runner.calls == [Self.printLine, Self.kickstart])
    }

    @Test func servicePIDIsReadFromTheTopLevelLineOnly() {
        let nested = "gui/501/x = {\n\tenvironment = {\n\t\tpid = 1\n\t}\n\tpid = 4242\n\tpid = 9\n}\n"
        #expect(LaunchdServiceBinding.servicePID(in: nested) == 4242)
        #expect(LaunchdServiceBinding.servicePID(in: "gui/501/x = {\n\tenvironment = {\n\t\tpid = 1\n\t}\n}\n") == nil)
        #expect(LaunchdServiceBinding.servicePID(in: "gui/501/x = {\n\tpid = abc\n}\n") == nil)
        #expect(LaunchdServiceBinding.servicePID(in: "gui/501/x = {\n\tpid = 0\n}\n") == nil)
    }

    // MARK: Argumente von launchctl (Master-Auftrag C)

    /// Außer dem geprüften Label und der festen Domäne `gui/<uid>` steuert nichts, was der Nutzer oder eine Plist
    /// vorgibt, die Argumente: Die Aufrufe bestehen aus festen Wörtern und diesem einen Ziel.
    @Test(arguments: ["homebrew.mxcl.postgresql@14", "a+b_c-d.e", "0abc"])
    func launchctlReceivesOnlyFixedWordsTheLabelAndTheDomain(label: String) async throws {
        var item = Self.item
        item.label = label
        let target = "gui/501/\(label)"
        let runner = MockCommandRunner([
            "/bin/launchctl print \(target)": Self.loaded(pid: 4242),
            "/bin/launchctl kickstart \(target)": Self.succeeded,
            "/bin/launchctl kill SIGTERM \(target)": Self.succeeded,
        ])
        try await control(runner).perform(ServiceControlRequest(action: .start, item: item))
        try await control(runner, inspector: EndsAfterSignalInspector(Self.agentProcess)).perform(stop(item))
        #expect(runner.calls == ["/bin/launchctl print \(target)", "/bin/launchctl kickstart \(target)",
                                 "/bin/launchctl print \(target)", "/bin/launchctl kill SIGTERM \(target)"])
        #expect(runner.recordedEnvironments.allSatisfy { $0 == nil })
    }

    @Test func domainComesFromTheUserIDNotFromTheItem() async throws {
        let runner = MockCommandRunner([
            "/bin/launchctl print gui/502/com.example.agent": Self.loaded(),
            "/bin/launchctl kickstart gui/502/com.example.agent": Self.succeeded,
        ])
        let control = ServiceControl(runner: runner, inspector: FixedProcessInspector([]), uid: 502)
        try await control.perform(ServiceControlRequest(action: .start, item: Self.item))
        #expect(runner.calls == ["/bin/launchctl print gui/502/com.example.agent",
                                 "/bin/launchctl kickstart gui/502/com.example.agent"])
    }

    /// Optionen (`-k`), Pfade, Leerraum, Trennzeichen und Zeilenumbrüche im Label erreichen launchctl nie.
    @Test(arguments: ["-k", "--help", "a b", "a/b", "../x", "a;b", "a\nb", "$(id)", "x`id`", "", "-", ".hidden", "a&b"])
    func labelWithSpecialCharactersNeverReachesLaunchctl(label: String) async {
        var item = Self.item
        item.label = label
        let runner = MockCommandRunner()
        for action in [ServiceControlAction.start, .stop] {
            await #expect(throws: PolicyViolation.invalidLabel(label)) {
                try await control(runner).perform(ServiceControlRequest(action: action, item: item))
            }
        }
        #expect(runner.calls.isEmpty)
    }
}

/// Verlauf im Speicher, mit dem Zeitpunkt.
/// Bestätigt vor dem Signal `process`; danach meldet die Prozesstabelle für dessen PID `afterwards` (Standard: beendet).
struct EndsAfterSignalInspector: ProcessInspecting {
    private let running: RunningProcess
    private let afterwards: ProcessLiveness

    init(_ running: RunningProcess, afterwards: ProcessLiveness = .absent) {
        self.running = running
        self.afterwards = afterwards
    }

    func process(_ pid: pid_t) -> RunningProcess? { pid == running.pid ? running : nil }

    func liveness(of pid: pid_t) -> ProcessLiveness { pid == running.pid ? afterwards : .absent }
}

private final class RecordingActionLog: TaskActionLogging {
    private let entries = Mutex<[(record: TaskActionRecord, date: Date)]>([])
    var records: [TaskActionRecord] { entries.withLock { $0.map(\.record) } }
    var dates: [Date] { entries.withLock { $0.map(\.date) } }

    func record(_ record: TaskActionRecord, at date: Date) async throws {
        entries.withLock { $0.append((record, date)) }
    }
}

@MainActor
@Suite struct ServiceControlFlowTests {
    private let actions = ActionRunner(helperActivity: HelperActivityLock(), coordinator: IdlePerformer())
    private let log = RecordingActionLog()
    private let loggedAt = Date(timeIntervalSince1970: 100)

    private func row(pid: Int32?, item: AutostartItem? = ServiceControlTests.item) -> ServiceRow {
        ServiceListPresenter.rows([.user(501): [LaunchdServiceStatus(label: "com.example.agent", pid: pid,
                                                                      lastExit: .never)]],
                                  autostartItems: item.map { [$0] } ?? [])[0]
    }

    private func flow(_ runner: MockCommandRunner = MockCommandRunner(), actions: ActionRunner? = nil,
                      inspector: any ProcessInspecting = EndsAfterSignalInspector(ServiceControlTests.agentProcess),
                      refresh: @escaping @MainActor () async -> Void = {}) -> ServiceControlFlow {
        let loggedAt = loggedAt
        return ServiceControlFlow(
            actions: actions ?? self.actions,
            control: ServiceControlTests().control(runner, inspector: inspector),
            log: log, userName: "mara", now: { loggedAt }, refresh: refresh
        )
    }

    @Test func offersStartOnlyWhenStoppedAndStopOnlyWhenRunning() {
        let flow = flow()
        flow.prepare(.stop, for: row(pid: nil))
        #expect(flow.pendingRequest == nil)
        flow.prepare(.start, for: row(pid: nil))
        #expect(flow.pendingRequest == ServiceControlRequest(action: .start, item: ServiceControlTests.item))
        flow.pendingRequest = nil
        flow.prepare(.start, for: row(pid: 7))
        #expect(flow.pendingRequest == nil)
        flow.prepare(.stop, for: row(pid: 7, item: nil))
        #expect(flow.pendingRequest == nil)
    }

    @Test func confirmRunsReportsAndRefreshes() async {
        let runner = MockCommandRunner([ServiceControlTests.printLine: ServiceControlTests.loaded(),
                                        ServiceControlTests.kickstart: ServiceControlTests.succeeded])
        var refreshed = 0
        let flow = flow(runner, refresh: { refreshed += 1 })
        await flow.confirm(ServiceControlRequest(action: .start, item: ServiceControlTests.item))
        #expect(actions.result(in: .taskManager)?.text == "„com.example.agent“ wurde gestartet.")
        #expect(refreshed == 1)
    }

    // MARK: Verlauf (Master-Auftrag A)

    @Test func startAndStopAreLoggedInTheHistoryWithLabelAndUser() async {
        let runner = MockCommandRunner([ServiceControlTests.printLine: ServiceControlTests.loaded(pid: 4242),
                                        ServiceControlTests.kickstart: ServiceControlTests.succeeded,
                                        ServiceControlTests.kill: ServiceControlTests.succeeded])
        let flow = flow(runner)
        await flow.confirm(ServiceControlRequest(action: .start, item: ServiceControlTests.item))
        await flow.confirm(ServiceControlRequest(action: .stop, item: ServiceControlTests.item))
        let records = log.records
        #expect(records.map(\.action) == [.startService, .stopService])
        #expect(records.map(\.processName) == ["com.example.agent", "com.example.agent"])
        #expect(records.map(\.userName) == ["mara", "mara"])
        #expect(records.map(\.outcome) == [.done, .done])
        // Ein Dienst hat bei jedem Start eine andere PID; der Verlauf nennt ihn über sein Label.
        #expect(records.map(\.pid) == [nil, nil])
        #expect(log.dates == [loggedAt, loggedAt])
    }

    @Test func failedActionIsLoggedWithItsReason() async {
        let runner = MockCommandRunner([ServiceControlTests.printLine: CommandResult(exitCode: 113, stdout: "")])
        await flow(runner).confirm(ServiceControlRequest(action: .start, item: ServiceControlTests.item))
        #expect(log.records.map(\.outcome) == [.failed(ServiceControl.notLoaded)])
        #expect(actions.result(in: .taskManager)?.text == ServiceControl.notLoaded)
    }

    /// Läuft der Prozess nach dem Stoppsignal weiter, nennen Meldung und Verlauf das statt „gestoppt“.
    @Test func stopOfAProcessThatKeepsRunningIsLoggedAsFailed() async {
        let runner = MockCommandRunner([ServiceControlTests.printLine: ServiceControlTests.loaded(pid: 4242),
                                        ServiceControlTests.kill: ServiceControlTests.succeeded])
        let stillRunning = FixedProcessInspector([ServiceControlTests.agentProcess])
        await flow(runner, inspector: stillRunning)
            .confirm(ServiceControlRequest(action: .stop, item: ServiceControlTests.item))
        #expect(log.records.map(\.outcome) == [.failed(ServiceControl.stillRunningAfterSignal)])
        #expect(actions.result(in: .taskManager)?.text == ServiceControl.stillRunningAfterSignal)
    }

    /// Eine Aktion, die gar nicht begonnen hat (Sperre während einer Helper-Installation), steht nicht im Verlauf.
    @Test func actionThatDidNotStartIsNotLogged() async {
        let lock = HelperActivityLock()
        #expect(lock.begin(.action))
        let busy = ActionRunner(helperActivity: lock, coordinator: IdlePerformer())
        let runner = MockCommandRunner()
        await flow(runner, actions: busy).confirm(ServiceControlRequest(action: .start, item: ServiceControlTests.item))
        #expect(log.records.isEmpty)
        #expect(runner.calls.isEmpty)
    }
}
