import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

/// Merkt sich Aufträge; `surviving` überlebt SIGTERM.
private final class RecordingTerminator: ProcessListTerminating {
    let calls = Mutex<[(pids: [pid_t], force: Bool)]>([])
    let surviving: Set<pid_t>

    init(surviving: Set<pid_t> = []) { self.surviving = surviving }

    func terminate(_ processes: [RunningProcess], force: Bool) async -> ProcessTerminationReport {
        calls.withLock { $0.append((processes.map(\.pid), force)) }
        let survivors = force ? [] : processes.filter { surviving.contains($0.pid) }
        return ProcessTerminationReport(ended: processes.filter { !survivors.contains($0) }, stillRunning: survivors)
    }
}

@MainActor
@Suite struct TaskTerminationFlowTests {
    private static let me: UInt32 = 501
    private static let app = RunningProcess(pid: 100, uid: me, executablePath: "/Applications/Browser.app/B", startTime: 5)
    private static let helper = RunningProcess(pid: 101, uid: me, executablePath: "/Applications/Browser.app/H",
                                               startTime: 6)
    private static let candidate = TaskTerminationCandidate(
        name: "Browser", keys: [ProcessKey(pid: 100, startTime: 5), ProcessKey(pid: 101, startTime: 6)]
    )

    private let actions = ActionRunner(helperActivity: HelperActivityLock(), coordinator: IdlePerformer())

    private func flow(_ processes: [RunningProcess] = [app, helper],
                      terminator: RecordingTerminator = RecordingTerminator()) -> TaskTerminationFlow {
        TaskTerminationFlow(actions: actions, terminator: terminator, inspector: FixedProcessInspector(processes),
                            currentUID: Self.me, ownPID: 1)
    }

    @Test func prepareConfirmsFreshProcessesInRowOrder() {
        let flow = flow()
        flow.prepare(Self.candidate, force: false)
        #expect(flow.pendingStep == .terminate(TaskTerminationRequest(name: "Browser", processes: [Self.app, Self.helper])))
        #expect(flow.pendingStep?.confirmation.title == "„Browser“ beenden?")
        #expect(flow.pendingStep?.confirmation.message == "Prozesse: PID 100, PID 101.")
    }

    @Test func optionDeleteAsksForForceDirectly() {
        let flow = flow()
        flow.prepare(Self.candidate, force: true)
        #expect(flow.pendingStep?.isForce == true)
        #expect(flow.pendingStep?.confirmation.confirmTitle == "Sofort beenden")
    }

    @Test func reusedPIDOrForeignProcessIsNotTargeted() {
        let reused = RunningProcess(pid: 100, uid: Self.me, executablePath: "/x", startTime: 99)
        let foreign = RunningProcess(pid: 101, uid: 0, executablePath: "/y", startTime: 6)
        let flow = flow([reused, foreign])
        flow.prepare(Self.candidate, force: false)
        #expect(flow.pendingStep == nil)
        #expect(flow.notice == TaskTerminationFlow.notRunning)
    }

    @Test func grantryDoesNotTerminateItself() {
        let flow = TaskTerminationFlow(actions: actions, terminator: RecordingTerminator(),
                                       inspector: FixedProcessInspector([Self.app]), currentUID: Self.me, ownPID: 100)
        flow.prepare(Self.candidate, force: false)
        #expect(flow.pendingStep == nil)
        #expect(flow.notice == TaskTerminationFlow.ownProcess)
    }

    @Test func survivorsOfTerminateAreOfferedForce() async throws {
        let terminator = RecordingTerminator(surviving: [101])
        let flow = flow(terminator: terminator)
        flow.prepare(Self.candidate, force: false)
        let step = try #require(flow.pendingStep)
        await flow.confirm(step)
        #expect(terminator.calls.withLock { $0.map(\.pids) } == [[100, 101]])
        #expect(flow.forceOffer?.processes == [Self.helper])
        #expect(actions.result(in: .taskManager)?.text == "1 Prozess läuft noch. „Sofort beenden“ (⌥⌫) steht bereit.")
        flow.offerForce()
        #expect(flow.pendingStep == .forceTerminate(TaskTerminationRequest(name: "Browser", processes: [Self.helper])))
    }

    @Test func endedTaskReportsSuccess() async throws {
        let terminator = RecordingTerminator()
        let flow = flow(terminator: terminator)
        flow.prepare(Self.candidate, force: true)
        await flow.confirm(try #require(flow.pendingStep))
        #expect(terminator.calls.withLock { $0.map(\.force) } == [true])
        #expect(flow.forceOffer == nil)
        #expect(actions.result(in: .taskManager)?.text == "„Browser“ wurde sofort beendet.")
    }
}
