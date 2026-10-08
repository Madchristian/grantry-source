import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

/// Liefert `outcome`; mit `gate` hält jede Aktion nach ihrem Beginn an (`started`).
private final class FakePerformer: ActionPerforming {
    let outcome: ActionOutcome
    let gate: Gate?
    let report: ProcessTerminationReport
    let started = Gate()
    private let drains = Mutex(0)
    private let cancellations = Mutex(0)

    init(outcome: ActionOutcome = .done, gate: Gate? = nil, report: ProcessTerminationReport = ProcessTerminationReport()) {
        self.outcome = outcome
        self.gate = gate
        self.report = report
    }

    var drainCount: Int { drains.withLock { $0 } }
    /// Wie oft der Task einer laufenden Aktion abgebrochen wurde.
    var cancellationCount: Int { cancellations.withLock { $0 } }

    private func perform() async -> ActionOutcome {
        await withTaskCancellationHandler {
            started.open()
            try? await gate?.wait()
            return outcome
        } onCancel: {
            cancellations.withLock { $0 += 1 }
        }
    }

    func reset(_ grant: PermissionGrant) async -> ActionOutcome { await perform() }
    func resetService(_ reset: ServiceReset) async -> ActionOutcome { await perform() }
    func setEnabled(_ item: AutostartItem, _ enabled: Bool) async -> ActionOutcome { await perform() }
    func remove(_ item: AutostartItem) async -> ActionOutcome { await perform() }
    func restore(receiptID: UUID) async -> ActionOutcome { await perform() }
    func removeServer(_ entry: MCPServerEntry) async -> ActionOutcome { await perform() }
    func setServerEnabled(_ entry: MCPServerEntry, _ enabled: Bool) async -> ActionOutcome { await perform() }
    func restoreAgentChange(_ change: AgentConfigChange) async -> ActionOutcome { await perform() }
    func perform(_ action: SecurityAction) async -> ActionOutcome { await perform() }
    /// Meldet den (leeren) Bericht vor dem Prüfscan, also bevor die Aktion endet.
    func performRemoval(
        _ plan: RemovalPlan, onExecuted: @escaping @Sendable (RemovalReport) async -> Void
    ) async -> RemovalReport {
        await onExecuted(RemovalReport(entries: []))
        _ = await perform()
        return RemovalReport(entries: [])
    }
    func terminate(_ request: ProcessTerminationRequest, force: Bool) async -> ProcessTerminationResult {
        ProcessTerminationResult(request: request, force: force, outcome: await perform(), report: report)
    }
    func drain() async { drains.withLock { $0 += 1 } }
}

@MainActor
@Suite struct ActionRunnerTests {
    private let lock = HelperActivityLock()

    @Test(.timeLimit(.minutes(1))) func tracksTheRunningRecordAndTheResultPerContext() async throws {
        let gate = Gate()
        let performer = FakePerformer(gate: gate)
        let runner = ActionRunner(helperActivity: lock, coordinator: performer)
        let item = TestData.item("com.vendor.agent")

        let running = Task { await runner.remove(item, context: .autostart) }
        try await performer.started.wait()
        #expect(runner.runningRecordID == item.id && runner.isRunning && !runner.canStart)
        #expect(lock.current == .action)

        gate.open()
        await running.value
        #expect(runner.runningRecordID == nil && runner.canStart && lock.current == nil)
        #expect(runner.result(in: .autostart) == .remove(item, outcome: .done))
        #expect(runner.result(in: .permissions) == nil)

        runner.dismissResult()
        #expect(runner.lastResult == nil)
    }

    @Test(.timeLimit(.minutes(1))) func ignoresASecondActionWhileOneRuns() async throws {
        let gate = Gate()
        let performer = FakePerformer(gate: gate)
        let runner = ActionRunner(helperActivity: lock, coordinator: performer)
        let first = TestData.item("first")

        let running = Task { await runner.setEnabled(first, false, context: .autostart) }
        try await performer.started.wait()
        await runner.reset(TestData.grant(), context: .permissions)
        #expect(runner.runningRecordID == first.id)

        gate.open()
        await running.value
        #expect(runner.result(in: .permissions) == nil)
        #expect(runner.result(in: .autostart) != nil)
    }

    @Test func doesNothingDuringHelperMaintenance() async {
        let runner = ActionRunner(helperActivity: lock, coordinator: FakePerformer())
        #expect(lock.begin(.helperMaintenance))
        #expect(!runner.canStart)
        await runner.reset(TestData.grant(), context: .permissions)
        #expect(runner.lastResult == nil)
        #expect(lock.current == .helperMaintenance)
    }

    @Test func failsReadablyWithoutCoordinator() async {
        let runner = ActionRunner(helperActivity: lock, coordinator: nil)
        let grant = TestData.grant()
        await runner.reset(grant, context: .permissions)
        #expect(runner.result(in: .permissions) == .reset(grant, outcome: .failed(ActionRunner.unavailableMessage)))
    }

    @Test func drainIsForwarded() async {
        let performer = FakePerformer()
        await ActionRunner(helperActivity: lock, coordinator: performer).drain()
        #expect(performer.drainCount == 1)
    }

    @Test(.timeLimit(.minutes(1))) func securityActionTracksItsCheckAndReportsInSecurityContext() async throws {
        let gate = Gate()
        let performer = FakePerformer(gate: gate)
        let runner = ActionRunner(helperActivity: lock, coordinator: performer)

        let running = Task { await runner.perform(.enableFirewall) }
        try await performer.started.wait()
        #expect(runner.runningRecordID == SecurityCheckKind.firewall.rawValue)

        gate.open()
        await running.value
        #expect(runner.result(in: .security)?.text == "Die Firewall ist eingeschaltet.")
        #expect(runner.result(in: .autostart) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func removalResultLandsInItsContext() async throws {
        let gate = Gate()
        let performer = FakePerformer(gate: gate)
        let runner = ActionRunner(helperActivity: lock, coordinator: performer)
        let plan = RemovalPlan(app: TestData.installedApp(), grants: [], autostartItems: [], files: [])

        let running = Task { await runner.performRemoval(plan, context: .apps) }
        try await performer.started.wait()
        #expect(runner.runningRecordID == plan.id && lock.current == .action)
        #expect(await runner.performRemoval(plan, context: .cleanup) == false, "läuft schon eine Aktion, beginnt keine weitere")

        gate.open()
        #expect(await running.value)
        #expect(runner.result(in: .apps)?.text == "Nichts wurde entfernt.")
        #expect(runner.result(in: .cleanup) == nil)
    }

    /// Die Oberfläche erfährt vom Papierkorb, sobald er erledigt ist – nicht erst nach dem Prüfscan.
    @Test(.timeLimit(.minutes(1))) func executedRemovalIsReportedBeforeTheActionEnds() async throws {
        let gate = Gate()
        let performer = FakePerformer(gate: gate)
        let runner = ActionRunner(helperActivity: lock, coordinator: performer)
        var reports: [RemovalReport] = []
        runner.onRemovalExecuted = { reports.append($0) }
        let plan = RemovalPlan(app: TestData.installedApp(), grants: [], autostartItems: [], files: [])

        let running = Task { await runner.performRemoval(plan, context: .apps) }
        try await performer.started.wait()
        #expect(reports == [RemovalReport(entries: [])])
        #expect(runner.isRunning)

        gate.open()
        #expect(await running.value)
        #expect(reports.count == 1)
    }

    // MARK: - Abbrechen für „Neu installieren“

    /// Hängt eine Aktion am nicht startbaren Helper, endet sie sofort als abgebrochen und gibt die Sperre frei, damit der
    /// Helper neu installiert werden kann; ihr spätes Ergebnis wird verworfen.
    @Test(.timeLimit(.minutes(1))) func abandoningEndsTheRunningActionAndFreesTheLock() async throws {
        let gate = Gate()
        let performer = FakePerformer(outcome: .failed("spät"), gate: gate)
        let runner = ActionRunner(helperActivity: lock, coordinator: performer)
        let item = TestData.item("com.vendor.agent")

        let running = Task { await runner.remove(item, context: .autostart) }
        try await performer.started.wait()
        await runner.abandonRunningAction()

        #expect(!runner.isRunning && runner.runningRecordID == nil)
        #expect(lock.current == nil)
        #expect(runner.result(in: .autostart) == .abandoned)
        await running.value

        gate.open()
        for _ in 0..<50 { await Task.yield() }
        #expect(runner.result(in: .autostart) == .abandoned)
    }

    /// Issue #102: Der Abbruch erreicht den Coordinator, bevor die Sperre frei wird – die Aktion beginnt dann keine
    /// weiteren Schritte mehr (`ActionCoordinator.performRemoval`), während der Helper gewartet wird.
    @Test(.timeLimit(.minutes(1))) func abandoningCancelsTheActionBeforeFreeingTheLock() async throws {
        let performer = FakePerformer(gate: Gate())
        let runner = ActionRunner(helperActivity: lock, coordinator: performer)
        let plan = RemovalPlan(app: TestData.installedApp(), grants: [], autostartItems: [], files: [])

        let running = Task { await runner.performRemoval(plan, context: .apps) }
        try await performer.started.wait()
        await runner.abandonRunningAction()

        #expect(performer.cancellationCount == 1)
        #expect(lock.current == nil && runner.result(in: .apps) == .abandoned)
        #expect(await running.value)
    }

    /// Eine regulär beendete Aktion wird nicht nachträglich abgebrochen.
    @Test(.timeLimit(.minutes(1))) func finishedActionIsNotCancelled() async {
        let performer = FakePerformer()
        await ActionRunner(helperActivity: lock, coordinator: performer).reset(TestData.grant(), context: .permissions)
        #expect(performer.cancellationCount == 0)
    }

    @Test func abandoningWithoutRunningActionChangesNothing() async {
        let runner = ActionRunner(helperActivity: lock, coordinator: FakePerformer())
        await runner.abandonRunningAction()
        #expect(runner.lastResult == nil && lock.current == nil)
    }

    @Test func removalWithoutCoordinatorChangesNothing() async {
        let runner = ActionRunner(helperActivity: lock, coordinator: nil)
        let file = LeftoverCandidate(path: "/Users/test/Library/Caches/ai.openclaw.mac", kind: .caches, confidence: .safe)
        await runner.performRemoval(RemovalPlan(app: nil, grants: [], autostartItems: [], files: [file]), context: .cleanup)
        #expect(runner.result(in: .cleanup)?.text == ActionRunner.unavailableMessage)
        #expect(runner.result(in: .cleanup)?.tone == .critical)
    }

    // MARK: Prozess beenden

    private static let nodeProcess = RunningProcess(pid: 4242, uid: 501, executablePath: "/opt/homebrew/bin/node", startTime: 1)

    @Test(.timeLimit(.minutes(1))) func terminationTracksTheListenerAndReportsInNetworkContext() async throws {
        let gate = Gate()
        let performer = FakePerformer(outcome: .doneButUnverified("1 Prozess läuft noch."), gate: gate,
                                      report: ProcessTerminationReport(stillRunning: [Self.nodeProcess]))
        let runner = ActionRunner(helperActivity: lock, coordinator: performer)
        let request = ProcessTerminationRequest(listener: TestData.listener(), processes: [Self.nodeProcess])

        let running = Task { await runner.terminate(request, force: false) }
        try await performer.started.wait()
        #expect(runner.runningRecordID == request.listener.id)
        gate.open()
        let result = try #require(await running.value)
        #expect(result.forceRequest?.processes == [Self.nodeProcess])
        #expect(runner.result(in: .network) == .termination(result))
    }

    @Test func terminationWithoutCoordinatorFailsReadably() async {
        let runner = ActionRunner(helperActivity: lock, coordinator: nil)
        let request = ProcessTerminationRequest(listener: TestData.listener(), processes: [Self.nodeProcess])
        let result = await runner.terminate(request, force: false)
        #expect(result?.outcome == .failed(ActionRunner.unavailableMessage))
        #expect(runner.result(in: .network)?.tone == .critical)
    }

    @Test func terminationDuringHelperMaintenanceDoesNotStart() async {
        let runner = ActionRunner(helperActivity: lock, coordinator: FakePerformer())
        #expect(lock.begin(.helperMaintenance))
        let request = ProcessTerminationRequest(listener: TestData.listener(), processes: [Self.nodeProcess])
        #expect(await runner.terminate(request, force: false) == nil)
        #expect(runner.lastResult == nil)
    }

    // MARK: Ablauf „Prozess beenden …“

    @MainActor private final class RefreshCounter {
        var count = 0
    }

    /// Socket des `nodeProcess` – mit dessen Startzeit, wie der Enumerator sie liefert.
    private static let nodeSocket = ListeningSocket(pid: 4242, uid: 501, executablePath: "/opt/homebrew/bin/node",
                                                    transport: .tcp, localAddress: "0.0.0.0", localPort: 3000,
                                                    startTime: nodeProcess.startTime)

    private func makeFlow(
        _ runner: ActionRunner, sockets: [ListeningSocket], refreshes: RefreshCounter,
        ledger: ListenerTerminationLedger = ListenerTerminationLedger()
    ) -> ProcessTerminationFlow {
        ProcessTerminationFlow(
            resolver: ListenerProcessResolver(
                provider: nil, local: FixedSockets(result: .success(ListeningSocketScan(sockets: sockets))),
                inspector: FixedProcessInspector([Self.nodeProcess]), currentUID: 501
            ),
            actions: runner,
            ledger: ledger,
            refresh: { refreshes.count += 1 },
            now: { TestData.date }
        )
    }

    @Test func prepareAsksToConfirmFreshProcesses() async {
        let flow = makeFlow(ActionRunner(helperActivity: lock, coordinator: FakePerformer()), sockets: [Self.nodeSocket],
                            refreshes: RefreshCounter())
        await flow.prepare(TestData.listener())
        #expect(flow.pendingStep == .terminate(ProcessTerminationRequest(listener: TestData.listener(), processes: [Self.nodeProcess])))
        #expect(flow.preparingListenerID == nil && flow.notice == nil)
    }

    @Test func vanishedServiceShowsANoticeAndRescans() async {
        let refreshes = RefreshCounter()
        let flow = makeFlow(ActionRunner(helperActivity: lock, coordinator: FakePerformer()), sockets: [], refreshes: refreshes)
        await flow.prepare(TestData.listener())
        #expect(flow.pendingStep == nil)
        #expect(flow.notice?.listenerID == TestData.listener().id && flow.notice?.text == ProcessTerminationFlow.notRunning)
        #expect(refreshes.count == 1)
    }

    /// „läuft nicht mehr“ vermerkt den Lauscher, damit der Teilscan danach ihn nicht fortschreibt.
    @Test func vanishedServiceIsRecordedAsEnded() async {
        let ledger = ListenerTerminationLedger()
        let flow = makeFlow(ActionRunner(helperActivity: lock, coordinator: FakePerformer()), sockets: [],
                            refreshes: RefreshCounter(), ledger: ledger)
        await flow.prepare(TestData.listener())
        #expect(ledger.settleEndedIDs(at: TestData.date, seen: []) == [TestData.listener().id])
        #expect(ledger.takeHelperRefresh())
    }

    /// Laufende Prozesse oder ein Fehler beim Ermitteln vermerken nichts.
    @Test func resolvedOrFailedServiceIsNotRecorded() async {
        let ledger = ListenerTerminationLedger()
        let flow = makeFlow(ActionRunner(helperActivity: lock, coordinator: FakePerformer()), sockets: [Self.nodeSocket],
                            refreshes: RefreshCounter(), ledger: ledger)
        await flow.prepare(TestData.listener())
        await flow.prepare(TestData.listener(uid: 0))
        #expect(ledger.settleEndedIDs(at: TestData.date, seen: []).isEmpty)
    }

    @Test func foreignListenerWithoutHelperShowsTheReason() async {
        let flow = makeFlow(ActionRunner(helperActivity: lock, coordinator: FakePerformer()), sockets: [], refreshes: RefreshCounter())
        let foreign = TestData.listener(uid: 0)
        await flow.prepare(foreign)
        #expect(flow.pendingStep == nil)
        #expect(flow.notice?.listenerID == foreign.id)
        #expect(flow.notice?.text.contains("Helper") == true)
    }

    @Test func prepareDuringHelperMaintenanceDoesNothing() async {
        let flow = makeFlow(ActionRunner(helperActivity: lock, coordinator: FakePerformer()), sockets: [Self.nodeSocket],
                            refreshes: RefreshCounter())
        #expect(lock.begin(.helperMaintenance))
        await flow.prepare(TestData.listener())
        #expect(flow.pendingStep == nil && flow.notice == nil)
    }

    @Test func survivorsLeadToTheForceConfirmation() async {
        let performer = FakePerformer(outcome: .doneButUnverified("1 Prozess läuft noch."),
                                      report: ProcessTerminationReport(stillRunning: [Self.nodeProcess]))
        let flow = makeFlow(ActionRunner(helperActivity: lock, coordinator: performer), sockets: [], refreshes: RefreshCounter())
        let request = ProcessTerminationRequest(listener: TestData.listener(), processes: [Self.nodeProcess])
        await flow.confirm(.terminate(request))
        #expect(flow.forceOffer == request)
        flow.offerForce()
        #expect(flow.pendingStep == .forceTerminate(request))
        #expect(flow.pendingStep?.confirmation == .forceTerminate(request))
        await flow.confirm(.forceTerminate(request))
        #expect(flow.forceOffer == nil)
    }

    @Test func allEndedOffersNoForce() async {
        let flow = makeFlow(ActionRunner(helperActivity: lock, coordinator: FakePerformer()), sockets: [], refreshes: RefreshCounter())
        let request = ProcessTerminationRequest(listener: TestData.listener(), processes: [Self.nodeProcess])
        await flow.confirm(.terminate(request))
        #expect(flow.forceOffer == nil)
        flow.offerForce()
        #expect(flow.pendingStep == nil)
    }

    @Test func forceOfferSurvivesAConfirmationThatDoesNotStart() async {
        let performer = FakePerformer(outcome: .doneButUnverified("1 Prozess läuft noch."),
                                      report: ProcessTerminationReport(stillRunning: [Self.nodeProcess]))
        let flow = makeFlow(ActionRunner(helperActivity: lock, coordinator: performer), sockets: [], refreshes: RefreshCounter())
        let request = ProcessTerminationRequest(listener: TestData.listener(), processes: [Self.nodeProcess])
        await flow.confirm(.terminate(request))
        #expect(lock.begin(.helperMaintenance))
        await flow.confirm(.forceTerminate(request))
        #expect(flow.forceOffer == request)
    }

    @Test func noticeLapsesOnceTheListenerIsSeenAgain() async {
        let flow = makeFlow(ActionRunner(helperActivity: lock, coordinator: FakePerformer()), sockets: [], refreshes: RefreshCounter())
        let listener = TestData.listener()
        await flow.prepare(listener)
        // Fortgeschrieben (Entprellung), aber nicht erneut gesehen: Der Hinweis bleibt.
        flow.reconcile(with: [listener])
        #expect(flow.notice?.text == ProcessTerminationFlow.notRunning)
        flow.reconcile(with: [TestData.listener(lastSeen: TestData.date.addingTimeInterval(60))])
        #expect(flow.notice == nil)
    }

    @Test func forceOfferLapsesOnceTheListenerIsGone() async {
        let performer = FakePerformer(outcome: .doneButUnverified("1 Prozess läuft noch."),
                                      report: ProcessTerminationReport(stillRunning: [Self.nodeProcess]))
        let flow = makeFlow(ActionRunner(helperActivity: lock, coordinator: performer), sockets: [], refreshes: RefreshCounter())
        let request = ProcessTerminationRequest(listener: TestData.listener(), processes: [Self.nodeProcess])
        await flow.confirm(.terminate(request))
        flow.reconcile(with: [TestData.listener(lastSeen: TestData.date.addingTimeInterval(60))])
        #expect(flow.forceOffer == request)
        flow.reconcile(with: [TestData.listener(port: 8080)])
        #expect(flow.forceOffer == nil)
    }
}
