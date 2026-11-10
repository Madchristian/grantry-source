import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

/// Helper-Ersatz: merkt sich Aufträge samt Bestätigung; scheitert mit `failure`.
private final class FakeTaskHelper: PrivilegedTaskControlling, PrivilegedSensorReading {
    struct Call: Equatable { let pid: Int32; let force: Bool?; let priority: ProcessPriority?; let authorization: Data }
    private let log = Mutex<[Call]>([])
    private let failure: HelperClientError?
    private let readings: Mutex<[Result<SensorReading, HelperClientError>]>

    init(failure: HelperClientError? = nil, readings: [Result<SensorReading, HelperClientError>] = []) {
        self.failure = failure
        self.readings = Mutex(readings)
    }

    var calls: [Call] { log.withLock { $0 } }

    func terminateTaskProcess(pid: Int32, executablePath: String, startTime: UInt64, force: Bool,
                              authorization: Data) async throws {
        log.withLock { $0.append(Call(pid: pid, force: force, priority: nil, authorization: authorization)) }
        if let failure { throw failure }
    }

    func setTaskProcessPriority(pid: Int32, executablePath: String, startTime: UInt64, priority: ProcessPriority,
                                authorization: Data) async throws {
        log.withLock { $0.append(Call(pid: pid, force: nil, priority: priority, authorization: authorization)) }
        if let failure { throw failure }
    }

    func sensorReading() async throws -> SensorReading {
        try readings.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }.get()
    }
}

/// Bestätigung ohne Authorization Services; zählt die ausgegebenen.
private final class CountingAuthorization: ActionAuthorizationIssuing {
    private let count = Mutex(0)
    var issued: Int { count.withLock { $0 } }

    func issue() throws -> IssuedAuthorization {
        count.withLock { $0 += 1 }
        return ActionAuthorization.placeholder()
    }
}

/// Verlauf im Speicher.
private final class RecordingLog: TaskActionLogging {
    private let log = Mutex<[TaskActionRecord]>([])
    var records: [TaskActionRecord] { log.withLock { $0 } }

    func record(_ record: TaskActionRecord, at date: Date) async throws { log.withLock { $0.append(record) } }
}

/// Fester nice-Wert; merkt sich, für welche Prozesse eine Priorität gesetzt wurde.
private final class FixedNice: ProcessPrioritySetting {
    let value: Int32?
    private let log = Mutex<[pid_t]>([])

    init(value: Int32?) { self.value = value }

    var changedPIDs: [pid_t] { log.withLock { $0 } }

    func setPriority(_ priority: ProcessPriority, of process: RunningProcess) throws(ProcessPriorityFailure) {
        log.withLock { $0.append(process.pid) }
    }

    func niceValue(of pid: pid_t) -> Int32? { value }
}

/// „Task beenden“ mit dem echten `ProcessTerminator` und `OwnProcessSignaler`; jedes Signal, jeder Helper-Auftrag, jede
/// ausgegebene Admin-Bestätigung und jeder Verlaufseintrag landet in einem der Doubles.
private struct TerminationRig {
    let flow: TaskTerminationFlow
    let terminator: ProcessTerminator
    let signaler: RecordingSignaler
    let helper: FakeTaskHelper
    let authorization: CountingAuthorization
    let log: RecordingLog

    /// Weder ein Signal noch ein Helper-Auftrag noch eine Admin-Bestätigung noch ein Verlaufseintrag.
    var didNothing: Bool {
        signaler.sent.isEmpty && helper.calls.isEmpty && authorization.issued == 0 && log.records.isEmpty
    }
}

private let currentUserID: UInt32 = 501

@MainActor
private func makeTerminationRig(
    actions: ActionRunner, processes: [RunningProcess], helper: FakeTaskHelper = FakeTaskHelper(),
    authorization: CountingAuthorization = CountingAuthorization(), log: RecordingLog = RecordingLog(),
    ownPID: Int32 = 1, allowsForeignProcesses: Bool = true
) -> TerminationRig {
    let inspector = FixedProcessInspector(processes)
    let signaler = RecordingSignaler()
    let terminator = ProcessTerminator(
        own: OwnProcessSignaler(policy: .taskManagerProcess(bundlePath: "/Applications/Grantry.app",
                                                            inspector: inspector),
                                signaler: signaler, currentUID: currentUserID),
        privileged: HelperTaskTerminator(helper: helper, authorization: authorization), inspector: inspector,
        ledger: nil, currentUID: currentUserID, gracePeriod: .zero
    )
    let flow = TaskTerminationFlow(
        actions: actions, terminator: terminator, inspector: inspector, currentUID: currentUserID, ownPID: ownPID,
        allowsForeignProcesses: allowsForeignProcesses, log: log, userName: { $0 == 0 ? "root" : "ich" },
        now: { Date(timeIntervalSince1970: 100) }
    )
    return TerminationRig(flow: flow, terminator: terminator, signaler: signaler, helper: helper,
                          authorization: authorization, log: log)
}

@MainActor
private func makePriorityFlow(actions: ActionRunner, processes: [RunningProcess], helper: FakeTaskHelper,
                              log: RecordingLog = RecordingLog(), nice: Int32? = 0,
                              setter: FixedNice? = nil) -> TaskPriorityFlow {
    let inspector = FixedProcessInspector(processes)
    let prioritySetter = TaskPrioritySetter(
        policy: .taskManagerProcess(bundlePath: "/Applications/Grantry.app", inspector: inspector),
        setter: setter ?? FixedNice(value: nice), helper: helper, authorization: CountingAuthorization(),
        currentUID: currentUserID
    )
    return TaskPriorityFlow(actions: actions, setter: prioritySetter, inspector: inspector,
                            niceValues: FixedNice(value: nice), log: log, now: { Date(timeIntervalSince1970: 100) })
}

@MainActor
@Suite struct TaskManagerHelperFlowTests {
    private static let me = currentUserID
    private static let agent = RunningProcess(pid: 4242, uid: 0, executablePath: "/usr/local/sbin/agent", startTime: 7)
    private static let own = RunningProcess(pid: 300, uid: me, executablePath: "/usr/local/bin/tool", startTime: 8)
    private static let loginwindow = RunningProcess(
        pid: 620, uid: me, executablePath: "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow",
        startTime: 1
    )
    private static let agentCandidate = TaskTerminationCandidate(name: "agent", keys: [ProcessKey(pid: 4242, startTime: 7)])

    private let actions = ActionRunner(helperActivity: HelperActivityLock(), coordinator: IdlePerformer())

    private func terminationFlow(helper: FakeTaskHelper, authorization: CountingAuthorization = CountingAuthorization(),
                                 log: RecordingLog = RecordingLog(),
                                 processes: [RunningProcess] = [agent, own, loginwindow]) -> TaskTerminationFlow {
        makeTerminationRig(actions: actions, processes: processes, helper: helper, authorization: authorization,
                           log: log).flow
    }

    // MARK: - Beenden fremder Prozesse

    @Test func foreignProcessGoesToHelperWithFreshAuthorizationAndIsLogged() async throws {
        let helper = FakeTaskHelper(), authorization = CountingAuthorization(), log = RecordingLog()
        let flow = terminationFlow(helper: helper, authorization: authorization, log: log,
                                   processes: [RunningProcess(pid: 4242, uid: 0, executablePath: "/usr/local/sbin/agent",
                                                              startTime: 7)])
        flow.prepare(Self.agentCandidate, force: true)
        let step = try #require(flow.pendingStep)
        #expect(step.isForce)
        await flow.confirm(step)
        #expect(helper.calls.map(\.pid) == [4242])
        #expect(helper.calls.first?.force == true)
        #expect(helper.calls.first?.authorization.count == 32)
        #expect(authorization.issued == 1)
        #expect(log.records.map(\.action) == [.forceTerminate])
        #expect(log.records.first?.processName == "agent")
        #expect(log.records.first?.userName == "root")
    }

    @Test func helperRejectionIsLoggedAsFailure() async throws {
        let log = RecordingLog()
        let flow = terminationFlow(helper: FakeTaskHelper(failure: .rejected("Admin-Bestätigung abgebrochen – nichts geändert")),
                                   log: log)
        flow.prepare(Self.agentCandidate, force: false)
        await flow.confirm(try #require(flow.pendingStep))
        #expect(log.records.first?.outcome == .failed("Admin-Bestätigung abgebrochen – nichts geändert"))
    }

    /// Ohne Helper-Freigabe bleiben fremde Prozesse wie in TM3 außen vor.
    @Test func foreignProcessesNeedOptIn() {
        let flow = TaskTerminationFlow(actions: actions, inspector: FixedProcessInspector([Self.agent]),
                                       currentUID: Self.me, ownPID: 1)
        flow.prepare(Self.agentCandidate, force: false)
        #expect(flow.pendingStep == nil)
        #expect(flow.notice == TaskTerminationFlow.notRunning)
    }

    /// `loginwindow` gehört dem eigenen Benutzer – trotzdem keine Rückfrage, sondern der Grund.
    @Test func protectedProcessGetsNoticeInsteadOfConfirmation() {
        let flow = terminationFlow(helper: FakeTaskHelper())
        flow.prepare(TaskTerminationCandidate(name: "loginwindow", keys: [ProcessKey(pid: 620, startTime: 1)]), force: false)
        #expect(flow.pendingStep == nil)
        #expect(flow.notice?.hasPrefix("„loginwindow“ ist für macOS unverzichtbar") == true)
    }

    /// Eigene Prozesse beendet die App selbst; sie kommen nicht in den Verlauf (wie TM3).
    @Test func ownProcessIsNotLogged() async throws {
        let helper = FakeTaskHelper(), log = RecordingLog()
        let flow = terminationFlow(helper: helper, log: log)
        flow.prepare(TaskTerminationCandidate(name: "tool", keys: [ProcessKey(pid: 300, startTime: 8)]), force: false)
        await flow.confirm(try #require(flow.pendingStep))
        #expect(helper.calls.isEmpty)
        #expect(log.records.isEmpty)
    }

    @Test func confirmationNamesUserAndAdminPrompt() {
        let foreign = ActionConfirmation.terminateTask(TaskTerminationRequest(name: "agent", processes: [Self.agent]),
                                                       currentUID: Self.me)
        #expect(foreign.message == "Prozesse: PID 4242 (Benutzer root).")
        #expect(foreign.note?.hasSuffix(ActionConfirmation.adminPrompt) == true)
        let own = ActionConfirmation.terminateTask(TaskTerminationRequest(name: "tool", processes: [Self.own]),
                                                   currentUID: Self.me)
        #expect(own.message == "Prozesse: PID 300.")
        #expect(own.note?.contains("Administrator") == false)
    }

    // MARK: - Priorität

    private func priorityFlow(helper: FakeTaskHelper, log: RecordingLog = RecordingLog(), nice: Int32? = 0) -> TaskPriorityFlow {
        makePriorityFlow(actions: actions, processes: [Self.agent, Self.own, Self.loginwindow], helper: helper, log: log,
                         nice: nice)
    }

    @Test func lowerPriorityOfOwnProcessNeedsNoHelper() async throws {
        let helper = FakeTaskHelper(), log = RecordingLog()
        let flow = priorityFlow(helper: helper, log: log)
        flow.prepare(TaskTerminationCandidate(name: "tool", keys: [ProcessKey(pid: 300, startTime: 8)]), priority: .low)
        let request = try #require(flow.pendingRequest)
        #expect(!request.needsHelper(currentUID: Self.me))
        #expect(ActionConfirmation.setPriority(request, currentUID: Self.me).note == nil)
        await flow.confirm(request)
        #expect(helper.calls.isEmpty)
        #expect(log.records.map(\.action) == [.setPriority(.low)])
        #expect(log.records.first?.outcome == .done)
    }

    @Test func higherPriorityOrForeignProcessGoesToHelper() async throws {
        let helper = FakeTaskHelper()
        let flow = priorityFlow(helper: helper)
        flow.prepare(TaskTerminationCandidate(name: "tool", keys: [ProcessKey(pid: 300, startTime: 8)]), priority: .high)
        await flow.confirm(try #require(flow.pendingRequest))
        flow.prepare(Self.agentCandidate, priority: .belowNormal)
        let foreign = try #require(flow.pendingRequest)
        #expect(ActionConfirmation.setPriority(foreign, currentUID: Self.me).note == ActionConfirmation.adminPrompt)
        #expect(ActionConfirmation.setPriority(foreign, currentUID: Self.me).message
            == "Prozess: PID 4242, Benutzer root. Bisher: Normal.")
        await flow.confirm(foreign)
        #expect(helper.calls.map(\.priority) == [.high, .belowNormal])
    }

    @Test func priorityNeedsSingleUnprotectedRunningProcess() {
        let flow = priorityFlow(helper: FakeTaskHelper())
        flow.prepare(TaskTerminationCandidate(name: "App", keys: [ProcessKey(pid: 300, startTime: 8),
                                                                  ProcessKey(pid: 4242, startTime: 7)]), priority: .low)
        #expect(flow.notice == TaskPriorityFlow.singleProcessOnly)
        flow.prepare(TaskTerminationCandidate(name: "loginwindow", keys: [ProcessKey(pid: 620, startTime: 1)]), priority: .low)
        #expect(flow.notice?.hasPrefix("„loginwindow“ ist für macOS unverzichtbar") == true)
        flow.prepare(TaskTerminationCandidate(name: "weg", keys: [ProcessKey(pid: 300, startTime: 99)]), priority: .low)
        #expect(flow.notice == TaskTerminationFlow.notRunning)
        #expect(flow.pendingRequest == nil)
    }

    @Test func failedPriorityIsLoggedAndShown() async throws {
        let log = RecordingLog()
        let flow = priorityFlow(helper: FakeTaskHelper(failure: .rejected("Admin-Bestätigung abgebrochen – nichts geändert")),
                                log: log)
        flow.prepare(Self.agentCandidate, priority: .high)
        await flow.confirm(try #require(flow.pendingRequest))
        #expect(log.records.first?.outcome == .failed("Admin-Bestätigung abgebrochen – nichts geändert"))
        #expect(actions.result(in: .taskManager)?.text == "Admin-Bestätigung abgebrochen – nichts geändert")
    }

    @Test func currentPriorityIsNearestLevel() {
        #expect(priorityFlow(helper: FakeTaskHelper(), nice: 19).currentPriority(of: ProcessKey(pid: 300, startTime: 8)) == .low)
        #expect(priorityFlow(helper: FakeTaskHelper(), nice: nil).currentPriority(of: ProcessKey(pid: 300, startTime: 8)) == nil)
    }

    // MARK: - Zeilen

    @Test func foreignRowIsCandidateOnlyWithHelperAndSingleProcess() {
        let single = entryRow([measurement(of: Self.agent)])
        #expect(single.terminationCandidate(currentUID: Self.me) == nil)
        #expect(single.terminationCandidate(currentUID: Self.me, allowingForeign: true)?.keys == [ProcessKey(pid: 4242, startTime: 7)])
        let mixed = entryRow([measurement(of: Self.own), measurement(of: Self.agent)])
        #expect(mixed.terminationCandidate(currentUID: Self.me, allowingForeign: true) == nil)
    }

    /// Der Hinweis „Zeile aufklappen“ gilt nur dort, wo es etwas aufzuklappen gibt: bei mehreren Prozessen, darunter
    /// fremden – gleich ob die Zeile in der Gruppe „System“ oder „Apps“ steht. Ein einzelner fremder Prozess ist beendbar
    /// und braucht keinen Hinweis.
    @Test func openRowNoteOnlyForRowsWithSeveralProcessesIncludingForeignOnes() {
        let foreignOnly = entryRow([measurement(of: Self.agent), measurement(of: Self.agent)])
        let mixed = entryRow([measurement(of: Self.own), measurement(of: Self.agent)])
        for row in [foreignOnly, mixed] {
            #expect(row.includesForeignProcess(currentUID: Self.me))
            #expect(row.foreignTerminationNote(currentUID: Self.me) == TaskTerminationCandidate.foreignProcessNote)
        }
        let single = entryRow([measurement(of: Self.agent)])
        #expect(single.includesForeignProcess(currentUID: Self.me))
        #expect(single.foreignTerminationNote(currentUID: Self.me) == nil)
        #expect(childRow(measurement(of: Self.agent)).foreignTerminationNote(currentUID: Self.me) == nil)
    }

    @Test func rowsWithoutForeignProcessesNeedNoNoteAndNoAdmin() {
        let ownOnly = entryRow([measurement(of: Self.own), measurement(of: Self.own)])
        #expect(!ownOnly.includesForeignProcess(currentUID: Self.me))
        #expect(ownOnly.foreignTerminationNote(currentUID: Self.me) == nil)
        let header = ProcessListRow(id: "group", kind: .group(.system, isCollapsed: false), group: .system,
                                    title: "System", detail: "", figures: noFigures)
        #expect(!header.includesForeignProcess(currentUID: Self.me))
        #expect(header.foreignTerminationNote(currentUID: Self.me) == nil)
    }
}

// MARK: - Zeilen und Messwerte

private let noFigures = ProcessFigures(cpuLoad: nil, memoryBytes: nil, diskPerSecond: nil, networkPerSecond: nil)

/// Zeile der obersten Ebene mit den `processes` (eine App bzw. ein einzelner Prozess).
private func entryRow(_ processes: [ProcessMeasurement]) -> ProcessListRow {
    let entry = ProcessGroupEntry(app: nil, processes: processes, figures: processes.map { _ in noFigures })
    return ProcessListRow(id: entry.id, kind: .entry(entry, isExpanded: false), group: .system, title: entry.name,
                          detail: "", figures: entry.totals)
}

/// Zeile eines Prozesses unter einer aufgeklappten App.
private func childRow(_ process: ProcessMeasurement) -> ProcessListRow {
    ProcessListRow(id: "child:\(process.key.id)", kind: .child(process), group: .system, title: process.name,
                   detail: "PID \(process.key.pid)", figures: noFigures)
}

private func measurement(of process: RunningProcess) -> ProcessMeasurement {
    ProcessMeasurement(key: ProcessKey(pid: process.pid, startTime: process.startTime), parentPID: 1, uid: process.uid,
                       name: (process.executablePath as NSString).lastPathComponent, cpuLoad: nil, memoryBytes: nil,
                       diskReadPerSecond: nil, diskWritePerSecond: nil, threadCount: nil,
                       executablePath: process.executablePath)
}

// MARK: - Schutzliste in allen Beenden-Wegen (TM3 und TM5)

/// Programme der Schutzliste, wie der Task-Manager sie sieht: `loginwindow` unter der UID des angemeldeten Benutzers,
/// dazu root, ein weiterer Systembenutzer und PID 1.
private enum ProtectedFixture: String, CaseIterable, Sendable {
    case loginwindowOfCurrentUser, opendirectorydOfRoot, windowServerOfSystemUser, launchdAsPID1

    var process: RunningProcess {
        switch self {
        case .loginwindowOfCurrentUser:
            RunningProcess(pid: 620, uid: currentUserID,
                           executablePath: "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow",
                           startTime: 1)
        case .opendirectorydOfRoot:
            RunningProcess(pid: 330, uid: 0, executablePath: "/usr/libexec/opendirectoryd", startTime: 2)
        case .windowServerOfSystemUser:
            RunningProcess(pid: 400, uid: 88, executablePath: "/System/Library/PrivateFrameworks/SkyLight.framework/"
                           + "Versions/A/Resources/WindowServer", startTime: 3)
        case .launchdAsPID1:
            RunningProcess(pid: 1, uid: 0, executablePath: "/sbin/launchd", startTime: 4)
        }
    }

    var name: String { (process.executablePath as NSString).lastPathComponent }
    var isOwn: Bool { process.uid == currentUserID }
    var key: ProcessKey { ProcessKey(pid: process.pid, startTime: process.startTime) }

    /// Der Hinweis, der die Rückfrage ersetzt.
    var expectedNotice: String { "„\(name)“ ist für macOS unverzichtbar" }
}

/// Die Einstiege in „Task beenden“. Im Modell unterscheiden sie sich nur durch die Quelle des Kandidaten; danach rufen
/// alle `TaskTerminationFlow.prepare` auf (App: `TaskTerminationSupport.swift` für ⌫/⌥⌫ und Aktionsleiste,
/// `DetailsTab.swift` für das Kontextmenü).
private enum TerminationEntry: String, CaseIterable, Sendable {
    /// Prozesse-Tab: ausgewählte Zeile, ⌫/⌥⌫ (`terminatesOnDelete`).
    case processesTabKeyboard
    /// Prozesse-Tab: Schaltflächen „Task beenden“/„Sofort beenden“ der Aktionsleiste.
    case processesTabActionBar
    /// Prozesse-Tab: Prozess unter einer aufgeklappten App.
    case processesTabChildRow
    /// Details-Tab: ausgewählte Zeile, ⌫/⌥⌫.
    case detailsTabKeyboard
    /// Details-Tab: Aktionsleiste.
    case detailsTabActionBar
    /// Details-Tab: Kontextmenü „Beenden“/„Sofort beenden“ (`ProcessDetailContextMenu`).
    case detailsTabContextMenu

    /// `nil`, wenn der Einstieg für diesen Prozess nichts anbietet (die Schaltflächen bleiben gesperrt).
    func candidate(for process: RunningProcess, allowingForeign: Bool) -> TaskTerminationCandidate? {
        let measured = measurement(of: process)
        switch self {
        case .processesTabKeyboard, .processesTabActionBar:
            var snapshot = TaskManagerSnapshot()
            snapshot.processes = [measured]
            return ProcessListPresenter.present(snapshot, apps: [], currentUID: currentUserID, network: nil,
                                                options: ProcessListOptions()).rows
                .compactMap { $0.terminationCandidate(currentUID: currentUserID, allowingForeign: allowingForeign) }
                .first { $0.keys.contains(measured.key) }
        case .processesTabChildRow:
            return childRow(measured).terminationCandidate(currentUID: currentUserID, allowingForeign: allowingForeign)
        case .detailsTabKeyboard, .detailsTabActionBar, .detailsTabContextMenu:
            var snapshot = TaskManagerSnapshot()
            snapshot.processes = [measured]
            return ProcessDetailPresenter.present(snapshot, currentUID: currentUserID, options: ProcessDetailOptions(),
                                                  userName: { String($0) }).rows.first?.terminationCandidate
        }
    }
}

private struct ProtectedScenario: Sendable, CustomTestStringConvertible {
    let entry: TerminationEntry
    let fixture: ProtectedFixture
    let force: Bool
    let allowsForeignProcesses: Bool

    var testDescription: String {
        "\(entry.rawValue), \(fixture.rawValue), \(force ? "SIGKILL" : "SIGTERM"), "
            + "fremde Prozesse \(allowsForeignProcesses ? "erlaubt" : "nicht erlaubt")"
    }
}

private let protectedScenarios = TerminationEntry.allCases.flatMap { entry in
    ProtectedFixture.allCases.flatMap { fixture in
        [false, true].flatMap { force in
            [false, true].map {
                ProtectedScenario(entry: entry, fixture: fixture, force: force, allowsForeignProcesses: $0)
            }
        }
    }
}

@MainActor
@Suite struct TaskManagerProtectedProcessTests {
    private static let tool = RunningProcess(pid: 300, uid: currentUserID, executablePath: "/usr/local/bin/tool",
                                             startTime: 8)
    private static let agent = RunningProcess(pid: 4242, uid: 0, executablePath: "/usr/local/sbin/agent", startTime: 7)
    private static let everyone = [tool, agent] + ProtectedFixture.allCases.map(\.process)

    private let actions = ActionRunner(helperActivity: HelperActivityLock(), coordinator: IdlePerformer())

    private func rig(allowsForeignProcesses: Bool = true) -> TerminationRig {
        makeTerminationRig(actions: actions, processes: Self.everyone, ownPID: 99_999,
                           allowsForeignProcesses: allowsForeignProcesses)
    }

    // MARK: - Hinweis statt Rückfrage

    /// Jeder Einstieg, jeder Prozess der Schutzliste (eigene und fremde UID), SIGTERM wie SIGKILL, mit und ohne
    /// Freigabe fremder Prozesse: keine Rückfrage, der Grund als Hinweis, kein Signal, kein Helper-Auftrag, keine
    /// Admin-Bestätigung.
    @Test(arguments: protectedScenarios)
    fileprivate func protectedProcessGetsNoticeOnEveryEntry(_ scenario: ProtectedScenario) {
        let rig = rig(allowsForeignProcesses: scenario.allowsForeignProcesses)
        let process = scenario.fixture.process
        guard let candidate = scenario.entry.candidate(for: process, allowingForeign: scenario.allowsForeignProcesses) else {
            // Nichts auszulösen; für eigene Prozesse wäre ein fehlender Kandidat eine Lücke im Test, nicht im Schutz.
            #expect(!scenario.fixture.isOwn, "Eigener Prozess ohne Kandidat – der Test prüfte nichts")
            #expect(rig.didNothing)
            return
        }
        rig.flow.prepare(candidate, force: scenario.force)
        #expect(rig.flow.pendingStep == nil)
        #expect(rig.flow.notice?.hasPrefix(scenario.fixture.expectedNotice) == true)
        #expect(rig.didNothing)
    }

    /// Kontrolle gegen ein Test-Artefakt „alles wird abgelehnt“: Ein eigener Prozess außerhalb der Liste bekommt über
    /// jeden Einstieg seine Rückfrage.
    @Test(arguments: TerminationEntry.allCases) fileprivate func unprotectedProcessKeepsItsConfirmation(_ entry: TerminationEntry) throws {
        let rig = rig()
        let candidate = try #require(entry.candidate(for: Self.tool, allowingForeign: true))
        rig.flow.prepare(candidate, force: false)
        #expect(rig.flow.pendingStep == .terminate(TaskTerminationRequest(name: "tool", processes: [Self.tool])))
        #expect(rig.flow.notice == nil)
    }

    /// Ein von Hand gebauter Kandidat (ohne den Filter der Zeilen) wird ebenso abgelehnt – fremde Prozesse ohne
    /// Freigabe gelten als nicht laufend.
    @Test(arguments: ProtectedFixture.allCases, [false, true])
    fileprivate func handBuiltCandidateIsRefused(_ fixture: ProtectedFixture, force: Bool) {
        for allowsForeignProcesses in [false, true] {
            let rig = rig(allowsForeignProcesses: allowsForeignProcesses)
            rig.flow.prepare(TaskTerminationCandidate(name: fixture.name, keys: [fixture.key]), force: force)
            #expect(rig.flow.pendingStep == nil)
            if !fixture.isOwn, !allowsForeignProcesses {
                #expect(rig.flow.notice == TaskTerminationFlow.notRunning)
            } else {
                #expect(rig.flow.notice?.hasPrefix(fixture.expectedNotice) == true)
            }
            #expect(rig.didNothing)
        }
    }

    /// Eine Zeile mit mehreren Prozessen, darunter einer der Schutzliste, wird als Ganzes abgelehnt – auch die
    /// übrigen Prozesse bekommen kein Signal.
    @Test(arguments: [ProtectedFixture.loginwindowOfCurrentUser, .opendirectorydOfRoot])
    fileprivate func rowWithAProtectedProcessIsRefusedAsAWhole(_ fixture: ProtectedFixture) {
        let rig = rig()
        let candidate = TaskTerminationCandidate(
            name: "App", keys: [ProcessKey(pid: Self.tool.pid, startTime: Self.tool.startTime), fixture.key]
        )
        rig.flow.prepare(candidate, force: false)
        #expect(rig.flow.pendingStep == nil)
        #expect(rig.flow.notice?.hasPrefix(fixture.expectedNotice) == true)
        #expect(rig.didNothing)
    }

    // MARK: - Zweite Linie: Schritte ohne `prepare`, Policy beim Signal

    /// Ein Schritt, der nicht aus `prepare` stammt, erreicht weder das Signal noch den Helper.
    @Test(arguments: ProtectedFixture.allCases, [false, true])
    fileprivate func stepWithoutPrepareIsRefusedBeforeAnySignal(_ fixture: ProtectedFixture, force: Bool) async {
        let rig = rig()
        let request = TaskTerminationRequest(name: fixture.name, processes: [fixture.process])
        await rig.flow.confirm(force ? .forceTerminate(request) : .terminate(request))
        #expect(rig.flow.notice?.hasPrefix(fixture.expectedNotice) == true)
        #expect(rig.flow.forceOffer == nil)
        #expect(rig.didNothing)
    }

    /// Die Policy des Signalwegs (TM3, eigener Benutzer) lehnt `loginwindow` auch ohne den Ablauf ab.
    @Test(arguments: [false, true]) func signalPolicyRefusesOwnProtectedProcess(force: Bool) async throws {
        let rig = rig()
        let loginwindow = ProtectedFixture.loginwindowOfCurrentUser
        let report = await rig.terminator.terminate([loginwindow.process], force: force)
        #expect(report.ended.isEmpty)
        let failure = try #require(report.failures.first)
        #expect(failure.message.hasPrefix(loginwindow.expectedNotice))
        #expect(rig.didNothing)
    }

    // MARK: - Priorität

    @Test(arguments: ProtectedFixture.allCases)
    fileprivate func priorityIsRefusedForEveryProtectedProcess(_ fixture: ProtectedFixture) async {
        let helper = FakeTaskHelper(), setter = FixedNice(value: 0)
        let flow = makePriorityFlow(actions: actions, processes: Self.everyone, helper: helper, setter: setter)
        flow.prepare(TaskTerminationCandidate(name: fixture.name, keys: [fixture.key]), priority: .low)
        #expect(flow.pendingRequest == nil)
        #expect(flow.notice?.hasPrefix(fixture.expectedNotice) == true)
        // Auch ein Auftrag ohne `prepare` setzt nichts.
        await flow.confirm(TaskPriorityRequest(name: fixture.name, process: fixture.process, priority: .low,
                                               currentNice: 0))
        #expect(helper.calls.isEmpty)
        #expect(setter.changedPIDs.isEmpty)
    }
}
