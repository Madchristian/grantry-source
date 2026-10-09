import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

// MARK: - Testdoubles

/// Quelle mit je Aufruf vorgegebenem Beitrag (der letzte wiederholt sich). `starts` meldet den Index jedes Aufrufs,
/// sobald er beginnt; mit `gate` hält jeder Aufruf an, bis der Test ihn freigibt.
private final class ScriptedSource: InventorySource, Sendable {
    private struct Counters {
        var calls = 0
        var running = 0
        var maxRunning = 0
    }

    let id: SourceID = .tccUser
    let starts: AsyncStream<Int>
    private let started: AsyncStream<Int>.Continuation
    private let script: [InventoryContribution]
    private let gate: Gate?
    private let counters = Mutex(Counters())

    init(script: [InventoryContribution], gate: Gate? = nil) {
        self.script = script
        self.gate = gate
        (starts, started) = AsyncStream<Int>.makeStream()
    }

    var calls: Int { counters.withLock { $0.calls } }
    /// Höchstzahl gleichzeitig laufender Aufrufe – 1 heißt: nie zwei Scans parallel.
    var maxConcurrentCalls: Int { counters.withLock { $0.maxRunning } }

    func collect() async throws -> InventoryContribution {
        let index = counters.withLock { counters in
            counters.running += 1
            counters.maxRunning = max(counters.maxRunning, counters.running)
            defer { counters.calls += 1 }
            return counters.calls
        }
        defer { counters.withLock { $0.running -= 1 } }
        started.yield(index)
        try await gate?.wait()
        return script[min(index, script.count - 1)]
    }
}

/// Reicht an einen echten Store durch, zählt Aufrufe und wirft auf Wunsch für einzelne Operationen.
private final class SpyStore: SnapshotStore, Sendable {
    enum Operation: Hashable {
        case latestSnapshot, record, touch, lastCheckedAt, events, unreadCount, markAllRead, pruneEvents
    }

    struct Failure: Error {}

    private struct State {
        var failing: Set<Operation> = []
        var held: [Operation: Gate] = [:]
        var calls: [Operation: Int] = [:]
        var pruneCutoffs: [Date] = []
    }

    /// Meldet jede Operation, sobald sie beginnt (vor einem etwaigen Tor).
    let starts: AsyncStream<Operation>
    private let started: AsyncStream<Operation>.Continuation
    private let wrapped: any SnapshotStore
    private let state = Mutex(State())

    init(wrapping wrapped: any SnapshotStore) {
        self.wrapped = wrapped
        (starts, started) = AsyncStream<Operation>.makeStream()
    }

    func fail(_ operations: Set<Operation>) { state.withLock { $0.failing = operations } }
    /// Hält jeden Aufruf von `operation` am Tor an, bis der Test ihn freigibt.
    func hold(_ operation: Operation, at gate: Gate) { state.withLock { $0.held[operation] = gate } }
    func calls(_ operation: Operation) -> Int { state.withLock { $0.calls[operation, default: 0] } }
    var pruneCutoffs: [Date] { state.withLock { $0.pruneCutoffs } }

    private func perform<Value>(_ operation: Operation, _ body: () async throws -> Value) async throws -> Value {
        let (fails, gate) = state.withLock { state in
            state.calls[operation, default: 0] += 1
            return (state.failing.contains(operation), state.held[operation])
        }
        started.yield(operation)
        if let gate { try await gate.wait() }
        if fails { throw Failure() }
        return try await body()
    }

    func latestSnapshot() async throws -> Snapshot? {
        try await perform(.latestSnapshot) { try await wrapped.latestSnapshot() }
    }

    func record(_ snapshot: Snapshot, events: [ChangeEvent], checkedAt: Date?) async throws -> [HistoryEvent] {
        try await perform(.record) { try await wrapped.record(snapshot, events: events, checkedAt: checkedAt) }
    }

    func touch(_ snapshot: Snapshot, checkedAt: Date?) async throws {
        try await perform(.touch) { try await wrapped.touch(snapshot, checkedAt: checkedAt) }
    }

    func lastCheckedAt() async throws -> Date? {
        try await perform(.lastCheckedAt) { try await wrapped.lastCheckedAt() }
    }

    func events(limit: Int, after cursor: HistoryEvent?) async throws -> [HistoryEvent] {
        try await perform(.events) { try await wrapped.events(limit: limit, after: cursor) }
    }

    func unreadCount() async throws -> Int {
        try await perform(.unreadCount) { try await wrapped.unreadCount() }
    }

    func markAllRead() async throws {
        try await perform(.markAllRead) { try await wrapped.markAllRead() }
    }

    func pruneEvents(olderThan date: Date) async throws {
        state.withLock { $0.pruneCutoffs.append(date) }
        try await perform(.pruneEvents) { try await wrapped.pruneEvents(olderThan: date) }
    }
}

/// Lauscher-Quelle, die wie der echte Mapper jede Sichtung mit der Scan-Zeit stempelt (`firstSeenAt`, `lastSeenAt`
/// = `now()`); `nil` liefert keinen Lauscher. `starts` meldet jeden Aufruf, sobald er beginnt.
private final class SightingSource: InventorySource, Sendable {
    let id: SourceID = .networkListeners
    let starts: AsyncStream<Void>
    private let started: AsyncStream<Void>.Continuation
    private let listener: NetworkListener?
    private let now: @Sendable () -> Date

    init(_ listener: NetworkListener?, now: @escaping @Sendable () -> Date) {
        self.listener = listener
        self.now = now
        (starts, started) = AsyncStream<Void>.makeStream()
    }

    func collect() async throws -> InventoryContribution {
        started.yield()
        guard var listener else { return InventoryContribution() }
        listener.firstSeenAt = now()
        listener.lastSeenAt = now()
        return InventoryContribution(networkListeners: [listener])
    }
}

/// Watcher ohne Signale; hält seine Continuation, damit der Strom offen bleibt.
private final class IdleWatcher: FileSystemWatching {
    private let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    init() { (stream, continuation) = AsyncStream<String>.makeStream() }

    func changes(in paths: [String], files: [String], shallowPaths: [String]) -> AsyncStream<String> { stream }
}

/// Auslöser unter Testkontrolle: `send(_:)` reicht einen Auslöser weiter. `consumerWaits` meldet jedes Mal, wenn der
/// Konsument auf den nächsten Auslöser wartet – alle zuvor gesendeten sind dann verarbeitet.
private final class ControlledTriggers: ScanTriggering, Sendable {
    struct Reasons: AsyncSequence, Sendable {
        typealias Element = ScanReason
        let triggers: ControlledTriggers
        func makeAsyncIterator() -> Iterator { Iterator(triggers: triggers) }
    }

    struct Iterator: AsyncIteratorProtocol {
        let triggers: ControlledTriggers
        mutating func next() async -> ScanReason? { await triggers.take() }
    }

    private enum Outcome {
        case ready(ScanReason?)
        case waiting
    }

    private struct State {
        var queue: [ScanReason] = []
        var waiter: CheckedContinuation<ScanReason?, Never>?
        var reasonsCalls = 0
        var consumerCancelled = false
    }

    let consumerWaits: AsyncStream<Void>
    /// Meldet jeden Aufruf von `reasons()`, sobald er beginnt (vor dem Tor).
    let reasonsStarts: AsyncStream<Void>
    private let waiting: AsyncStream<Void>.Continuation
    private let reasonsStarted: AsyncStream<Void>.Continuation
    private let reasonsGate: Gate?
    private let state = Mutex(State())

    /// - Parameter reasonsGate: hält `reasons()` an, bis der Test es freigibt.
    init(reasonsGate: Gate? = nil) {
        self.reasonsGate = reasonsGate
        (consumerWaits, waiting) = AsyncStream<Void>.makeStream()
        (reasonsStarts, reasonsStarted) = AsyncStream<Void>.makeStream()
    }

    var reasonsCalls: Int { state.withLock { $0.reasonsCalls } }
    /// `true`, sobald der Konsument den Strom durch Abbruch beendet hat.
    var consumerCancelled: Bool { state.withLock { $0.consumerCancelled } }

    /// Wie `ScanTriggers`: `.launch` kommt als Erstes.
    func reasons() async -> Reasons {
        state.withLock { $0.reasonsCalls += 1 }
        reasonsStarted.yield()
        try? await reasonsGate?.wait()
        send(.launch)
        return Reasons(triggers: self)
    }

    func requestScan() { send(.manual) }

    func requestScan(only sources: Set<SourceID>) { send(.sourceRefresh(sources)) }

    func send(_ reason: ScanReason) {
        let waiter = state.withLock { state -> CheckedContinuation<ScanReason?, Never>? in
            guard let waiter = state.waiter else {
                state.queue.append(reason)
                return nil
            }
            state.waiter = nil
            return waiter
        }
        waiter?.resume(returning: reason)
    }

    private func take() async -> ScanReason? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ScanReason?, Never>) in
                let outcome: Outcome = state.withLock { state in
                    if Task.isCancelled {
                        state.consumerCancelled = true
                        return .ready(nil)
                    }
                    guard state.queue.isEmpty else { return .ready(state.queue.removeFirst()) }
                    state.waiter = continuation
                    return .waiting
                }
                switch outcome {
                case .ready(let reason): continuation.resume(returning: reason)
                case .waiting: waiting.yield()
                }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                defer { state.waiter = nil }
                if state.waiter != nil { state.consumerCancelled = true }
                return state.waiter
            }
            waiter?.resume(returning: nil)
        }
    }
}

// MARK: - Aufbau

/// Alles, was ein Engine-Test braucht: Skript-Quelle, In-Memory-Store hinter einem Spion, aufzeichnender Notifier
/// und echte `ScanTriggers` ohne Dateisignale – deren Zeitgeber laufen auf der Test-Uhr und damit nie ab.
private struct Harness {
    let dates: ManualClock
    let clock = TestClock()
    let source: ScriptedSource
    let store: SpyStore
    let posted = RecordingNotifier()
    let engine: MonitoringEngine

    /// - Parameters:
    ///   - store: Ablage einer früheren Engine (Neustart-Tests); sonst eine frische im Speicher.
    ///   - dates: Uhr einer früheren Engine, damit die Zeit weiterläuft.
    init(
        script: [InventoryContribution], gate: Gate? = nil, triggers: (any ScanTriggering)? = nil,
        deepVerifier: DeepSignatureVerifier? = nil, extraSources: [any InventorySource] = [],
        store: (any SnapshotStore)? = nil, dates: ManualClock? = nil
    ) throws {
        let dates = dates ?? ManualClock()
        self.dates = dates
        source = ScriptedSource(script: script, gate: gate)
        let wrapped: any SnapshotStore
        if let store { wrapped = store } else { wrapped = try SwiftDataSnapshotStore.inMemory() }
        self.store = SpyStore(wrapping: wrapped)
        engine = MonitoringEngine(
            coordinator: ScanCoordinator(sources: [source] + extraSources, now: { dates.now }),
            store: self.store,
            notifier: ChangeNotifier(notifier: posted, clock: clock),
            triggers: triggers ?? ScanTriggers(watcher: IdleWatcher(), paths: ["/watched"], clock: clock),
            deepVerifier: deepVerifier,
            now: { dates.now }
        )
    }

    var now: Date { dates.now }
    func advance(seconds: TimeInterval) { dates.advance(by: seconds) }
}

private extension AsyncStream.Iterator where Element == MonitoringState {
    /// Liest Zustände, bis einer `predicate` erfüllt; `nil`, wenn der Strom vorher endet.
    mutating func next(where predicate: (MonitoringState) -> Bool) async -> MonitoringState? {
        while let state = await next() {
            if predicate(state) { return state }
        }
        return nil
    }
}

/// Zustand nach Abschluss des Scans, der zum Zeitpunkt `date` begann.
private func scanned(at date: Date) -> (MonitoringState) -> Bool {
    { !$0.isScanning && $0.lastCheckedAt == date }
}

private let grantA = TestData.grant("kTCCServiceCamera")
private let grantB = TestData.grant("kTCCServiceMicrophone")
private let grantC = TestData.grant("kTCCServiceScreenCapture")
private let ninetyDays: TimeInterval = 90 * 24 * 3_600

private func contribution(_ grants: PermissionGrant...) -> InventoryContribution {
    InventoryContribution(grants: grants)
}

// MARK: - Tests

@Suite(.timeLimit(.minutes(1)))
struct MonitoringEngineTests {
    @Test func acceptedAppStillPublishesDeepFindingsInDetails() async throws {
        try await ScratchDirectory.with(prefix: "accepted-deep") { directory in
            let path = directory.appending(path: "Known.app")
            try Data("x".utf8).write(to: path)
            let app = TestData.installedApp(path: path.path)
            let validator = ScriptedSignatureValidator(verdicts: [app.path: .invalid(status: -67023)], holding: true)
            let source = CountingSource(.apps, .success(InventoryContribution(installedApps: [app])))
            let harness = try Harness(script: [contribution()], deepVerifier: DeepSignatureVerifier(validator: validator),
                                      extraSources: [source])
            var states = await harness.engine.states().makeAsyncIterator()
            var starts = validator.starts.makeAsyncIterator()
            await harness.engine.start()
            _ = try #require(await states.next(where: scanned(at: harness.now)))
            #expect(await starts.next() == app.path)
            try await harness.engine.setAppRiskAccepted(true, appID: app.id)
            _ = try #require(await states.next { $0.acceptedAppIDs.contains(app.id) })
            validator.release()
            let updated = try #require(await states.next { $0.appFindings.contains { $0.rule == .invalidSignature } })
            #expect(updated.findings.isEmpty)
            #expect(updated.acceptedAppIDs == [app.id])
            await harness.engine.stop()
        }
    }

    @Test func acceptedAppRemovalIsRecordedWithoutNotification() async throws {
        let app = TestData.installedApp()
        let source = CountingSource(.apps, script: [
            .success(InventoryContribution(installedApps: [app])), .success(InventoryContribution())
        ])
        let harness = try Harness(script: [contribution()], extraSources: [source])
        var states = await harness.engine.states().makeAsyncIterator()
        await harness.engine.start()
        _ = try #require(await states.next(where: scanned(at: harness.now)))
        try await harness.engine.setAppRiskAccepted(true, appID: app.id)
        harness.advance(seconds: 60)
        await harness.engine.scanNow()
        let removed = try #require(await states.next(where: scanned(at: harness.now)))
        #expect(removed.recentEvents.first?.event.kind == .removed)
        await harness.engine.stop()
        #expect(harness.posted.all.isEmpty)
    }

    @Test func acceptedUpdatesStayInHistoryWithoutNotificationsAndNewTeamWarnsAgain() async throws {
        let app = TestData.installedApp(architecture: .intel)
        var update = app
        update.shortVersion = "7.0"
        var changed = update
        changed.signing.teamID = "NEWTEAM"
        let source = CountingSource(.apps, script: [app, update, changed].map {
            .success(InventoryContribution(installedApps: [$0]))
        })
        let harness = try Harness(script: [contribution()], extraSources: [source])
        var states = await harness.engine.states().makeAsyncIterator()
        await harness.engine.start()
        _ = try #require(await states.next(where: scanned(at: harness.now)))
        try await harness.engine.setAppRiskAccepted(true, appID: app.id)
        harness.advance(seconds: 60)
        await harness.engine.scanNow()
        let updated = try #require(await states.next(where: scanned(at: harness.now)))
        #expect(updated.acceptedAppIDs == [app.id])
        #expect(updated.findings.isEmpty)
        #expect(updated.recentEvents.count == 1)
        #expect(harness.posted.all.isEmpty)
        harness.advance(seconds: 60)
        await harness.engine.scanNow()
        let newTeam = try #require(await states.next(where: scanned(at: harness.now)))
        #expect(newTeam.acceptedAppIDs.isEmpty)
        #expect(newTeam.findings.contains { $0.rule == .teamIDChanged })
        await harness.engine.stop()
        #expect(harness.posted.all.count == 1)
    }

    @Test func acceptedAppImmediatelyLeavesWarningsAndRevocationRestoresThem() async throws {
        let app = TestData.installedApp(signing: SigningInfo(kind: .unsigned))
        let store = try SwiftDataSnapshotStore.inMemory()
        _ = try await store.record(TestData.appSnapshot([app]), events: [], checkedAt: TestData.date)
        let harness = try Harness(script: [contribution()], extraSources: [
            CountingSource(.apps, .success(InventoryContribution(installedApps: [app])))
        ], store: store)
        var states = await harness.engine.states().makeAsyncIterator()
        await harness.engine.start()
        _ = try #require(await states.next(where: { !$0.findings.isEmpty }))
        try await harness.engine.setAppRiskAccepted(true, appID: app.id)
        let accepted = try #require(await states.next(where: { $0.acceptedAppIDs.contains(app.id) }))
        #expect(accepted.findings.isEmpty)
        #expect(accepted.appFindings.map(\.rule) == [.unsignedApp])
        let presentation = try #require(PresentationInput(state: accepted, recentAdditions: []).map { $0.make(now: TestData.date) })
        #expect(presentation.metrics.flaggedCount == 0)
        #expect(presentation.highestSeverity(for: app.id) == nil)
        try await harness.engine.setAppRiskAccepted(false, appID: app.id)
        let revoked = try #require(await states.next(where: { !$0.findings.isEmpty && $0.acceptedAppIDs.isEmpty }))
        #expect(revoked.findings.map(\.rule) == [.unsignedApp])
        await harness.engine.stop()
    }

    @Test func firstScanIsBaselineWithoutEventsOrNotifications() async throws {
        let unsigned = TestData.grant(client: TestData.app("com.example.unsigned", signing: SigningInfo(kind: .unsigned)))
        let harness = try Harness(script: [contribution(grantA, unsigned)])
        var states = await harness.engine.states().makeAsyncIterator()
        await harness.engine.start()
        let state = try #require(await states.next(where: scanned(at: harness.now)))

        #expect(state.snapshot?.grants == [grantA, unsigned])
        #expect(state.snapshot?.baselineSources == [.tccUser])
        #expect(state.findings.map(\.rule) == [.unsignedClient])
        #expect(state.recentEvents.isEmpty)
        #expect(state.unreadCount == 0)
        #expect(try await harness.store.latestSnapshot() == state.snapshot)
        #expect(try await harness.store.events(limit: 10).isEmpty)
        await harness.engine.stop()
        #expect(harness.posted.all.isEmpty)
    }

    @Test func secondScanRecordsNotifiesAndCountsNewGrant() async throws {
        let harness = try Harness(script: [contribution(grantA), contribution(grantA, grantB)])
        var states = await harness.engine.states().makeAsyncIterator()
        await harness.engine.start()
        _ = try #require(await states.next(where: scanned(at: harness.now)))

        harness.advance(seconds: 60)
        await harness.engine.scanNow()
        let state = try #require(await states.next(where: scanned(at: harness.now)))

        #expect(state.snapshot?.grants == [grantA, grantB])
        #expect(state.unreadCount == 1)
        let event = try #require(state.recentEvents.first)
        #expect(event.event.kind == .added)
        #expect(event.event.subject == .grant(grantB))
        #expect(!event.isRead)
        #expect(try await harness.store.unreadCount() == 1)
        await harness.engine.stop()
        #expect(harness.posted.all.map(\.identifier) == [event.id.uuidString])
    }

    /// Ein äquivalenter Vollscan schreibt keine Events, frischt aber den gespeicherten Snapshot auf (Sichtungszeiten
    /// der Lauscher) und setzt den Prüfzeitpunkt.
    @Test func equivalentScanOnlyTouchesTheStore() async throws {
        let dates = ManualClock()
        let listeners = SightingSource(TestData.listener(uid: getuid()), now: { dates.now })
        let harness = try Harness(script: [contribution(grantA)], extraSources: [listeners], dates: dates)
        var states = await harness.engine.states().makeAsyncIterator()
        await harness.engine.start()
        let first = try #require(await states.next(where: scanned(at: harness.now)))

        harness.advance(seconds: 60)
        await harness.engine.scanNow()
        let second = try #require(await states.next(where: scanned(at: harness.now)))

        #expect(second.snapshot?.takenAt == harness.now)
        #expect(second.recentEvents.isEmpty)
        #expect(second.unreadCount == 0)
        #expect(try #require(second.snapshot).isEquivalent(to: try #require(first.snapshot)))
        #expect(try await harness.store.latestSnapshot() == second.snapshot)
        #expect(try await harness.store.latestSnapshot()?.networkListeners.map(\.lastSeenAt) == [harness.now])
        #expect(try await harness.store.lastCheckedAt() == harness.now)
        #expect(harness.store.calls(.record) == 1)
        #expect(harness.store.calls(.touch) == 1)
        await harness.engine.stop()
        #expect(harness.posted.all.isEmpty)
    }

    /// Neustart während einer kurzen Dienstunterbrechung: Die Sichtungszeiten der ruhigen Teilscans (die die Ablage
    /// nicht berühren) werden beim Stopp gespeichert. Der nächste Start entprellt mit der frischen Sichtung – kein
    /// falsches „beendet“, kein falsches „neu“.
    @Test func sightingsOfQuietRefreshesSurviveARestart() async throws {
        let dates = ManualClock()
        let listener = TestData.listener(uid: getuid())
        let triggers = ControlledTriggers()
        let listeners = SightingSource(listener, now: { dates.now })
        let harness = try Harness(script: [contribution(grantA)], triggers: triggers, extraSources: [listeners],
                                  dates: dates)
        var states = await harness.engine.states().makeAsyncIterator()
        var listenerStarts = listeners.starts.makeAsyncIterator()
        let firstScanAt = harness.now
        await harness.engine.start()
        #expect(await listenerStarts.next() != nil)
        _ = try #require(await states.next(where: scanned(at: firstScanAt)))

        // Zwei ruhige Teilscans: Beginnt der zweite, ist der erste abgeschlossen und hat die Sichtung aufgefrischt.
        harness.advance(seconds: 60)
        let refreshedAt = harness.now
        triggers.send(.sourceRefresh([.networkListeners]))
        #expect(await listenerStarts.next() != nil)
        harness.advance(seconds: 60)
        triggers.send(.sourceRefresh([.networkListeners]))
        #expect(await listenerStarts.next() != nil)
        await harness.engine.stop()
        let stored = try #require(try await harness.store.latestSnapshot()?.networkListeners.first)
        #expect(stored.lastSeenAt >= refreshedAt)
        #expect(stored.firstSeenAt == firstScanAt)

        // Neustart 5 min nach der aufgefrischten Sichtung; der Dienst ist gerade nicht da.
        harness.dates.advance(by: refreshedAt.addingTimeInterval(5 * 60).timeIntervalSince(harness.now))
        let restarted = try Harness(
            script: [contribution(grantA)], extraSources: [SightingSource(nil, now: { dates.now })],
            store: harness.store, dates: dates
        )
        var restartedStates = await restarted.engine.states().makeAsyncIterator()
        await restarted.engine.start()
        let state = try #require(await restartedStates.next(where: scanned(at: restarted.now)))
        await restarted.engine.stop()

        #expect(state.snapshot?.networkListeners.map(\.id) == [listener.id])
        #expect(state.recentEvents.isEmpty)
        #expect(restarted.posted.all.isEmpty)
    }

    @Test func triggersDuringAScanCoalesceIntoOneFollowUpScan() async throws {
        let triggers = ControlledTriggers()
        let gate = Gate()
        let harness = try Harness(script: [contribution(grantA)], gate: gate, triggers: triggers)
        var states = await harness.engine.states().makeAsyncIterator()
        var starts = harness.source.starts.makeAsyncIterator()
        var consumerWaits = triggers.consumerWaits.makeAsyncIterator()
        let firstScanAt = harness.now
        await harness.engine.start()
        #expect(await starts.next() == 0)
        #expect(await consumerWaits.next() != nil)

        // Drei Auslöser während des laufenden Scans; jeder ist verarbeitet, bevor der nächste kommt.
        for reason in [ScanReason.manual, .fileChange(path: "/watched/a.plist"), .interval] {
            triggers.send(reason)
            #expect(await consumerWaits.next() != nil)
        }

        harness.advance(seconds: 60)
        gate.open()
        _ = try #require(await states.next(where: scanned(at: firstScanAt)))
        #expect(await starts.next() == 1)
        gate.open()
        _ = try #require(await states.next(where: scanned(at: harness.now)))

        await harness.engine.stop()
        #expect(harness.source.calls == 2)
        #expect(harness.source.maxConcurrentCalls == 1)
    }

    /// Ein ruhiger Teilscan (äquivalent, gleiche Findings) frischt nur den Snapshot im Speicher auf: kein neuer
    /// Zustand im Strom, kein Zugriff auf die Ablage. Erst der folgende Vollscan veröffentlicht – mit dem
    /// aufgefrischten Snapshot.
    @Test func quietSourceRefreshPublishesNothing() async throws {
        let triggers = ControlledTriggers()
        let listeners = CountingSource(.networkListeners,
                                       .success(InventoryContribution(networkListeners: [TestData.listener()])))
        let harness = try Harness(script: [contribution(grantA)], triggers: triggers, extraSources: [listeners])
        var states = await harness.engine.states().makeAsyncIterator()
        var listenerStarts = listeners.starts.makeAsyncIterator()
        let firstScanAt = harness.now
        await harness.engine.start()
        #expect(await listenerStarts.next() != nil)
        _ = try #require(await states.next(where: scanned(at: firstScanAt)))
        let watched: [SpyStore.Operation] = [.record, .touch, .events, .unreadCount, .pruneEvents]
        let storeCalls = watched.map(harness.store.calls)

        harness.advance(seconds: 60)
        let refreshAt = harness.now
        triggers.send(.sourceRefresh([.networkListeners]))
        // Läuft der Teilscan, ist sein Auslöser abgeholt: `.manual` folgt als eigener Scan.
        #expect(await listenerStarts.next() != nil)
        triggers.send(.manual)

        let next = try #require(await states.next())
        #expect(next.isScanning, "der erste neue Zustand stammt vom Vollscan")
        #expect(next.snapshot?.takenAt == refreshAt, "der Teilscan hat den Snapshot im Speicher aufgefrischt")
        #expect(next.lastCheckedAt == firstScanAt)
        #expect(watched.map(harness.store.calls) == storeCalls)
        _ = try #require(await states.next(where: scanned(at: refreshAt)))
        #expect(harness.source.calls == 2, "Startscan und Vollscan, der Teilscan fragt die Quelle nicht")
        #expect(listeners.callCount == 3)
        await harness.engine.stop()
    }

    /// Ein Teilscan mit Änderung wird gespeichert und veröffentlicht, ohne Fortschritt und ohne den Prüfzeitpunkt zu
    /// ändern – weder im Zustand noch in der Ablage.
    @Test func changedSourceRefreshIsPublishedWithoutTouchingCheckedAt() async throws {
        let triggers = ControlledTriggers()
        let listener = TestData.listener()
        let listeners = CountingSource(.networkListeners, script: [
            .success(InventoryContribution()), .success(InventoryContribution(networkListeners: [listener])),
        ])
        let harness = try Harness(script: [contribution(grantA)], triggers: triggers, extraSources: [listeners])
        var states = await harness.engine.states().makeAsyncIterator()
        let firstScanAt = harness.now
        await harness.engine.start()
        _ = try #require(await states.next(where: scanned(at: firstScanAt)))

        harness.advance(seconds: 60)
        triggers.send(.sourceRefresh([.networkListeners]))
        let state = try #require(await states.next())

        #expect(!state.isScanning)
        #expect(state.snapshot?.networkListeners == [listener])
        #expect(state.lastCheckedAt == firstScanAt)
        #expect(state.recentEvents.map(\.event.kind) == [.added])
        #expect(harness.source.calls == 1)
        #expect(try await harness.store.latestSnapshot()?.networkListeners == [listener])
        #expect(try await harness.store.lastCheckedAt() == firstScanAt)
        #expect(harness.store.calls(.touch) == 0)
        await harness.engine.stop()
    }

    /// `scanNow(only:)` liest nur die genannten Quellen (Teilscan), die übrigen fragt er nicht.
    @Test func scanNowOnlyRefreshesTheGivenSources() async throws {
        let listener = TestData.listener()
        let listeners = CountingSource(.networkListeners, script: [
            .success(InventoryContribution()), .success(InventoryContribution(networkListeners: [listener])),
        ])
        let harness = try Harness(script: [contribution(grantA)], extraSources: [listeners])
        var states = await harness.engine.states().makeAsyncIterator()
        let firstScanAt = harness.now
        await harness.engine.start()
        _ = try #require(await states.next(where: scanned(at: firstScanAt)))

        harness.advance(seconds: 60)
        await harness.engine.scanNow(only: [.networkListeners])
        let state = try #require(await states.next())
        await harness.engine.stop()

        #expect(state.snapshot?.networkListeners == [listener])
        #expect(state.lastCheckedAt == firstScanAt)
        #expect(harness.source.calls == 1)
        #expect(listeners.callCount == 2)
    }

    /// „Prozess beenden …“: Ein Teilscan, der einen beendeten Lauscher nicht fortschreibt, ist nicht äquivalent und
    /// wird veröffentlicht. Das `.removed` landet im Verlauf, aber ohne Meldung.
    @Test func sourceRefreshDroppingAnEndedListenerIsPublishedWithoutNotification() async throws {
        let triggers = ControlledTriggers()
        let listener = TestData.listener()
        let listeners = CountingSource(.networkListeners, script: [
            .success(InventoryContribution(networkListeners: [listener])),
            .success(InventoryContribution(endedListenerIDs: [listener.id])),
        ])
        let harness = try Harness(script: [contribution(grantA)], triggers: triggers, extraSources: [listeners])
        var states = await harness.engine.states().makeAsyncIterator()
        await harness.engine.start()
        _ = try #require(await states.next(where: scanned(at: harness.now)))

        harness.advance(seconds: 60)
        triggers.send(.sourceRefresh([.networkListeners]))
        let state = try #require(await states.next())
        await harness.engine.stop()

        #expect(state.snapshot?.networkListeners.isEmpty == true)
        #expect(state.recentEvents.map(\.event.kind) == [.removed])
        #expect(try await harness.store.events(limit: 10).map(\.event.kind) == [.removed])
        #expect(harness.posted.all.isEmpty)
    }

    /// Eine neue Einschränkung (etwa „nur eigene Sockets“, wenn der Helper wegfällt) ändert nichts an der Äquivalenz,
    /// soll aber sofort sichtbar werden: Der Teilscan wird veröffentlicht.
    @Test func sourceRefreshWithNewLimitationIsPublished() async throws {
        let triggers = ControlledTriggers()
        let listener = TestData.listener()
        let listeners = CountingSource(.networkListeners, script: [
            .success(InventoryContribution(networkListeners: [listener])),
            .success(InventoryContribution(limitations: ["Nur eigene Sockets lesbar"], networkListeners: [listener])),
        ])
        let harness = try Harness(script: [contribution(grantA)], triggers: triggers, extraSources: [listeners])
        var states = await harness.engine.states().makeAsyncIterator()
        let firstScanAt = harness.now
        await harness.engine.start()
        let first = try #require(await states.next(where: scanned(at: firstScanAt)))

        harness.advance(seconds: 60)
        triggers.send(.sourceRefresh([.networkListeners]))
        let state = try #require(await states.next())

        #expect(try #require(state.snapshot).isEquivalent(to: try #require(first.snapshot)))
        #expect(!state.isScanning)
        #expect(state.snapshot?.sourceLimitations
            == [SourceLimitation(source: .networkListeners, message: "Nur eigene Sockets lesbar")])
        #expect(state.lastCheckedAt == firstScanAt)
        await harness.engine.stop()
    }

    /// Liefert der Helper erst nach einem eingeschränkten Scan, sind fremde Lauscher Baseline: weder Verlauf noch
    /// Meldung. Ein neuer eigener Lauscher erscheint weiterhin.
    @Test func firstCompleteListenerDeliveryAddsNoForeignListeners() async throws {
        let own = TestData.listener(uid: getuid())
        let newOwn = TestData.listener("/opt/homebrew/bin/python3", uid: getuid(), port: 8000)
        let root = TestData.listener("/usr/sbin/sshd", uid: 0, port: 22)
        let listeners = CountingSource(.networkListeners, script: [
            .success(InventoryContribution(limitations: ["Nur eigene Sockets lesbar"], networkListeners: [own],
                                           listenersLimitedToUID: getuid())),
            .success(InventoryContribution(networkListeners: [own, newOwn, root])),
        ])
        let harness = try Harness(script: [contribution(grantA)], extraSources: [listeners])
        var states = await harness.engine.states().makeAsyncIterator()
        await harness.engine.start()
        _ = try #require(await states.next(where: scanned(at: harness.now)))

        harness.advance(seconds: 60)
        await harness.engine.scanNow()
        let state = try #require(await states.next(where: scanned(at: harness.now)))
        await harness.engine.stop()

        #expect(state.snapshot?.networkListeners.map(\.id).sorted() == [own, newOwn, root].map(\.id).sorted())
        let history = try await harness.store.events(limit: 10)
        #expect(history.map(\.event.subject) == [.networkListener(newOwn)])
        #expect(Set(harness.posted.all.map(\.identifier)).isSubset(of: history.map(\.id.uuidString)))
    }

    /// Ein Teilscan verdrängt keinen wartenden Vollscan: Beide verdichten sich zu genau einem Vollscan.
    @Test func sourceRefreshDoesNotDisplaceAPendingFullScan() async throws {
        let triggers = ControlledTriggers()
        let gate = Gate()
        let listeners = CountingSource(.networkListeners)
        let harness = try Harness(script: [contribution(grantA)], gate: gate, triggers: triggers,
                                  extraSources: [listeners])
        var states = await harness.engine.states().makeAsyncIterator()
        var starts = harness.source.starts.makeAsyncIterator()
        var consumerWaits = triggers.consumerWaits.makeAsyncIterator()
        let firstScanAt = harness.now
        await harness.engine.start()
        #expect(await starts.next() == 0)
        #expect(await consumerWaits.next() != nil)

        for reason in [ScanReason.fileChange(path: "/watched/a.plist"), .sourceRefresh([.networkListeners])] {
            triggers.send(reason)
            #expect(await consumerWaits.next() != nil)
        }

        harness.advance(seconds: 60)
        gate.open()
        _ = try #require(await states.next(where: scanned(at: firstScanAt)))
        #expect(await starts.next() == 1)
        gate.open()
        _ = try #require(await states.next(where: scanned(at: harness.now)))

        await harness.engine.stop()
        #expect(harness.source.calls == 2)
        #expect(listeners.callCount == 2)
    }

    @Test func stopEndsTheLoopAndDiscardsTheRunningScan() async throws {
        let gate = Gate()
        let harness = try Harness(script: [contribution(grantA)], gate: gate)
        var states = await harness.engine.states().makeAsyncIterator()
        var starts = harness.source.starts.makeAsyncIterator()
        await harness.engine.start()
        #expect(await starts.next() == 0)
        _ = try #require(await states.next(where: \.isScanning))

        await harness.engine.stop()

        let idle = try #require(await states.next(where: { !$0.isScanning }))
        #expect(idle.snapshot == nil)
        #expect(try await harness.store.latestSnapshot() == nil)
        #expect(harness.source.calls == 1)

        // Nach dem Stopp löst nichts mehr einen Scan aus; ein zweites `stop()` ist wirkungslos.
        await harness.engine.scanNow()
        await harness.engine.stop()
        #expect(harness.source.calls == 1)
    }

    @Test func storeErrorsAreLoggedAndTheEngineKeepsRunning() async throws {
        let harness = try Harness(script: [
            contribution(grantA), contribution(grantA, grantB), contribution(grantA, grantB, grantC),
        ])
        harness.store.fail([.record])
        var states = await harness.engine.states().makeAsyncIterator()
        await harness.engine.start()
        let first = try #require(await states.next(where: scanned(at: harness.now)))
        #expect(first.snapshot?.grants == [grantA])
        #expect(try await harness.store.latestSnapshot() == nil)

        // Der Snapshot im Speicher bleibt aktuell, die Änderung wird trotzdem gemeldet …
        harness.advance(seconds: 60)
        await harness.engine.scanNow()
        let second = try #require(await states.next(where: scanned(at: harness.now)))
        #expect(second.snapshot?.grants == [grantA, grantB])
        #expect(second.recentEvents.isEmpty)
        #expect(harness.store.calls(.record) == 2)

        // … und sobald der Store wieder geht, wird nur die neue Änderung gespeichert.
        harness.store.fail([])
        harness.advance(seconds: 60)
        await harness.engine.scanNow()
        let third = try #require(await states.next(where: scanned(at: harness.now)))
        #expect(third.recentEvents.map(\.event.subject) == [.grant(grantC)])
        #expect(third.unreadCount == 1)
        #expect(try await harness.store.latestSnapshot() == third.snapshot)
        await harness.engine.stop()
        #expect(harness.posted.all.count == 2)
    }

    @Test func unreadableStoreAtStartFallsBackToBaseline() async throws {
        let harness = try Harness(script: [contribution(grantA)])
        _ = try await harness.store.record(TestData.snapshot(baseline: [.tccUser]), events: [])
        harness.store.fail([.latestSnapshot, .lastCheckedAt, .events, .unreadCount])
        var states = await harness.engine.states().makeAsyncIterator()
        await harness.engine.start()
        let state = try #require(await states.next(where: scanned(at: harness.now)))

        #expect(state.snapshot?.grants == [grantA])
        #expect(state.recentEvents.isEmpty)
        #expect(state.unreadCount == 0)
        harness.store.fail([])
        // Baseline: kein Event für A, obwohl der (unlesbare) gespeicherte Snapshot A nicht kannte.
        #expect(try await harness.store.events(limit: 10).isEmpty)
        #expect(try await harness.store.latestSnapshot() == state.snapshot)
        await harness.engine.stop()
    }

    @Test func statesDeliverTheCurrentStateFirst() async throws {
        let harness = try Harness(script: [contribution(grantA)])
        var before = await harness.engine.states().makeAsyncIterator()
        // Anfangszustand: leer bis auf die aktiven Quellen des Koordinators (#142).
        let initial = await before.next()
        #expect(initial == MonitoringState(activeSources: initial?.activeSources))
        #expect(initial?.activeSources?.isEmpty == false)

        await harness.engine.start()
        let scanned = try #require(await before.next(where: scanned(at: harness.now)))
        var after = await harness.engine.states().makeAsyncIterator()
        #expect(await after.next() == scanned)
        await harness.engine.stop()
    }

    @Test func everySubscriberReceivesUpdatesAndEndedOnesAreDropped() async throws {
        let harness = try Harness(script: [contribution(grantA)])
        var first = await harness.engine.states().makeAsyncIterator()
        var second = await harness.engine.states().makeAsyncIterator()
        let third = await harness.engine.states()
        let consumer = Task { for await _ in third {} }
        #expect(harness.engine.subscriberCount == 3)

        await harness.engine.start()
        let state = try #require(await first.next(where: scanned(at: harness.now)))
        #expect(await second.next(where: scanned(at: harness.now)) == state)

        consumer.cancel()
        await consumer.value
        #expect(harness.engine.subscriberCount == 2)
        await harness.engine.stop()
    }

    @Test func markAllReadResetsUnreadCount() async throws {
        let harness = try Harness(script: [contribution(grantA), contribution(grantA, grantB)])
        var states = await harness.engine.states().makeAsyncIterator()
        await harness.engine.start()
        _ = try #require(await states.next(where: scanned(at: harness.now)))
        harness.advance(seconds: 60)
        await harness.engine.scanNow()
        #expect(try #require(await states.next(where: scanned(at: harness.now))).unreadCount == 1)

        await harness.engine.markAllRead()

        let read = try #require(await states.next(where: { $0.unreadCount == 0 && !$0.recentEvents.isEmpty }))
        #expect(read.recentEvents.allSatisfy { $0.isRead })
        #expect(try await harness.store.unreadCount() == 0)
        await harness.engine.stop()
    }

    @Test func pruneRunsAtMostOncePerDay() async throws {
        let harness = try Harness(script: [contribution(grantA)])
        var states = await harness.engine.states().makeAsyncIterator()
        await harness.engine.start()
        _ = try #require(await states.next(where: scanned(at: harness.now)))
        #expect(harness.store.pruneCutoffs == [harness.now.addingTimeInterval(-ninetyDays)])

        harness.advance(seconds: 3_600)
        await harness.engine.scanNow()
        _ = try #require(await states.next(where: scanned(at: harness.now)))
        #expect(harness.store.calls(.pruneEvents) == 1)

        harness.advance(seconds: 23 * 3_600)
        await harness.engine.scanNow()
        _ = try #require(await states.next(where: scanned(at: harness.now)))
        #expect(harness.store.calls(.pruneEvents) == 2)
        #expect(harness.store.pruneCutoffs.last == harness.now.addingTimeInterval(-ninetyDays))
        await harness.engine.stop()
    }

    @Test func persistedStateIsLoadedAtStartAndUsedAsPrevious() async throws {
        let gate = Gate()
        let harness = try Harness(script: [contribution(grantA, grantB)], gate: gate)
        let persisted = TestData.snapshot(grants: [grantA], baseline: [.tccUser], at: harness.now.addingTimeInterval(-3_600))
        let oldEvent = ChangeEvent(kind: .added, before: nil, after: .grant(grantA), detectedAt: persisted.takenAt)
        _ = try await harness.store.record(persisted, events: [oldEvent])

        var states = await harness.engine.states().makeAsyncIterator()
        await harness.engine.start()
        // Während der Startscan noch läuft, zeigt der Zustand den gespeicherten Verlauf.
        let loaded = try #require(await states.next(where: \.isScanning))
        #expect(loaded.snapshot == persisted)
        #expect(loaded.lastCheckedAt == persisted.takenAt)
        #expect(loaded.unreadCount == 1)
        #expect(loaded.recentEvents.map(\.event) == [oldEvent])

        gate.open()
        let scanned = try #require(await states.next(where: scanned(at: harness.now)))
        // Nur B ist neu: Der gespeicherte Snapshot war die Vergleichsbasis, keine Baseline.
        #expect(scanned.recentEvents.map(\.event.subject) == [.grant(grantB), .grant(grantA)])
        #expect(scanned.unreadCount == 2)
        await harness.engine.stop()
    }

    // MARK: Lebenszyklus

    @Test func concurrentStartCallsStartOneLoop() async throws {
        let triggers = ControlledTriggers()
        let harness = try Harness(script: [contribution(grantA)], triggers: triggers)
        var states = await harness.engine.states().makeAsyncIterator()

        async let first: Void = harness.engine.start()
        async let second: Void = harness.engine.start()
        await first
        await second

        _ = try #require(await states.next(where: scanned(at: harness.now)))
        #expect(triggers.reasonsCalls == 1)
        #expect(harness.source.calls == 1)
        await harness.engine.stop()
    }

    @Test func stopDuringStartAbortsItAndLeavesNothingRunning() async throws {
        let triggers = ControlledTriggers()
        let gate = Gate()
        let harness = try Harness(script: [contribution(grantA)], triggers: triggers)
        harness.store.hold(.latestSnapshot, at: gate)
        var storeStarts = harness.store.starts.makeAsyncIterator()

        let starting = Task { await harness.engine.start() }
        #expect(await storeStarts.next() == .latestSnapshot)
        let stopping = Task { await harness.engine.stop() }
        gate.open()
        await starting.value
        await stopping.value

        #expect(triggers.reasonsCalls == 0)
        #expect(harness.source.calls == 0)
        var states = await harness.engine.states().makeAsyncIterator()
        let initial = await states.next()
        #expect(initial == MonitoringState(activeSources: initial?.activeSources))
        #expect(await states.next() == nil)
    }

    @Test func stopWhileFetchingTriggersReleasesTheFeed() async throws {
        let gate = Gate()
        let triggers = ControlledTriggers(reasonsGate: gate)
        let harness = try Harness(script: [contribution(grantA)], triggers: triggers)
        var reasonsStarts = triggers.reasonsStarts.makeAsyncIterator()

        let starting = Task { await harness.engine.start() }
        #expect(await reasonsStarts.next() != nil)
        let stopping = Task { await harness.engine.stop() }
        gate.open()
        await starting.value
        await stopping.value

        // Der schon geholte Strom ist beendet, der wartende `.launch`-Auslöser löste keinen Scan aus.
        #expect(triggers.consumerCancelled)
        #expect(harness.source.calls == 0)
    }

    @Test func startAfterStopIsANoOp() async throws {
        let triggers = ControlledTriggers()
        let harness = try Harness(script: [contribution(grantA)], triggers: triggers)
        var states = await harness.engine.states().makeAsyncIterator()
        await harness.engine.start()
        _ = try #require(await states.next(where: scanned(at: harness.now)))
        await harness.engine.stop()

        await harness.engine.start()

        #expect(triggers.reasonsCalls == 1)
        #expect(harness.source.calls == 1)
        await harness.engine.stop()
    }

    @Test func stopFinishesAllStateStreams() async throws {
        let harness = try Harness(script: [contribution(grantA)])
        var states = await harness.engine.states().makeAsyncIterator()
        await harness.engine.start()
        let scanned = try #require(await states.next(where: scanned(at: harness.now)))

        await harness.engine.stop()

        #expect(await states.next(where: { _ in false }) == nil)
        #expect(harness.engine.subscriberCount == 0)
        // Ein Abonnement nach dem Stopp liefert nur noch den letzten Zustand.
        var late = await harness.engine.states().makeAsyncIterator()
        #expect(await late.next() == scanned)
        #expect(await late.next() == nil)
    }

    // MARK: Tiefe Signaturprüfung

    /// Grant mit sensibler Berechtigung für eine App unter `path` (muss existieren, sonst kein Fingerabdruck).
    private func sensitiveGrant(clientAt path: String) -> PermissionGrant {
        let client = AppIdentity(
            bundleID: "com.corsair.icue", path: path, displayName: "iCUE",
            signing: SigningInfo(kind: .developerID, teamID: "T", isNotarized: true), presence: .present
        )
        return TestData.grant("kTCCServiceListenEvent", client: client)
    }

    @Test func deepFindingsArePublishedAfterTheScan() async throws {
        try await ScratchDirectory.with(prefix: "engine-deep") { directory in
            let app = directory.appending(path: "iCUE.app")
            try Data("x".utf8).write(to: app)
            let validator = ScriptedSignatureValidator(verdicts: [app.path: .invalid(status: -67023)], holding: true)
            let harness = try Harness(
                script: [contribution(sensitiveGrant(clientAt: app.path))],
                deepVerifier: DeepSignatureVerifier(validator: validator)
            )
            var states = await harness.engine.states().makeAsyncIterator()
            var starts = validator.starts.makeAsyncIterator()
            await harness.engine.start()

            let scanned = try #require(await states.next(where: scanned(at: harness.now)))
            #expect(scanned.findings.isEmpty, "der Scan wartet nicht auf die Tiefenprüfung")
            #expect(await starts.next() == app.path)

            validator.release()
            let updated = try #require(await states.next { $0.findings.contains { $0.rule == .invalidSignature } })
            #expect(updated.findings.map(\.recordID) == [scanned.snapshot!.grants[0].id])
            #expect(updated.lastCheckedAt == scanned.lastCheckedAt)
            #expect(!validator.ranOnMainThread)
            await harness.engine.stop()
        }
    }

    @Test func knownVerdictsApplyImmediatelyOnTheNextScan() async throws {
        try await ScratchDirectory.with(prefix: "engine-deep") { directory in
            let app = directory.appending(path: "iCUE.app")
            try Data("x".utf8).write(to: app)
            let validator = ScriptedSignatureValidator(verdicts: [app.path: .invalid(status: -67023)])
            let harness = try Harness(
                script: [contribution(sensitiveGrant(clientAt: app.path))],
                deepVerifier: DeepSignatureVerifier(validator: validator)
            )
            var states = await harness.engine.states().makeAsyncIterator()
            await harness.engine.start()
            _ = try #require(await states.next { $0.findings.contains { $0.rule == .invalidSignature } })

            harness.advance(seconds: 60)
            await harness.engine.scanNow()
            let second = try #require(await states.next(where: scanned(at: harness.now)))
            #expect(second.findings.map(\.rule) == [.invalidSignature])
            #expect(validator.calls == [app.path], "unveränderter Fingerabdruck: keine zweite Prüfung")
            await harness.engine.stop()
        }
    }

    @Test func stopDoesNotWaitForARunningDeepCheck() async throws {
        try await ScratchDirectory.with(prefix: "engine-deep") { directory in
            let app = directory.appending(path: "Xcode-like.app")
            try Data("x".utf8).write(to: app)
            let validator = ScriptedSignatureValidator(holding: true)
            let harness = try Harness(
                script: [contribution(sensitiveGrant(clientAt: app.path))],
                deepVerifier: DeepSignatureVerifier(validator: validator)
            )
            var starts = validator.starts.makeAsyncIterator()
            await harness.engine.start()
            #expect(await starts.next() == app.path)

            await harness.engine.stop()
            validator.release()
        }
    }

    @Test func onlySecurityDeteriorationIsNotified() async throws {
        let good = TestData.evaluatedCheck(TestData.firewallOn)
        let worse = TestData.evaluatedCheck(TestData.stealthOff)
        let harness = try Harness(script: [
            InventoryContribution(securityChecks: [good]),
            InventoryContribution(securityChecks: [worse]),
            InventoryContribution(securityChecks: [good]),
        ])
        var states = await harness.engine.states().makeAsyncIterator()
        await harness.engine.start()
        _ = try #require(await states.next(where: scanned(at: harness.now)))
        for _ in 0..<2 {
            harness.advance(seconds: 60)
            await harness.engine.scanNow()
            _ = try #require(await states.next(where: scanned(at: harness.now)))
        }
        await harness.engine.stop()
        #expect(try await harness.store.events(limit: 10).count == 2)  // beide Wechsel im Verlauf, ungelesen
        #expect(try await harness.store.unreadCount() == 2)
        #expect(harness.posted.all.map(\.title) == ["Sicherheit verschlechtert"])  // nur die Verschlechterung gemeldet
    }

    @Test func deteriorationAcrossAFailureIsNotified() async throws {
        let harness = try Harness(script: [
            InventoryContribution(securityChecks: [TestData.evaluatedCheck(TestData.firewallOn)]),
            InventoryContribution(securityChecks: [SecurityCheck.failed(.firewall, detail: "nicht lesbar")]),
            InventoryContribution(securityChecks: [TestData.evaluatedCheck(TestData.firewallOff)]),
        ])
        var states = await harness.engine.states().makeAsyncIterator()
        await harness.engine.start()
        _ = try #require(await states.next(where: scanned(at: harness.now)))
        for _ in 0..<2 {
            harness.advance(seconds: 60)
            await harness.engine.scanNow()
            _ = try #require(await states.next(where: scanned(at: harness.now)))
        }
        await harness.engine.stop()
        #expect(try await harness.store.events(limit: 10).map(\.event.kind) == [.modified])  // der Ausfall selbst nicht
        #expect(harness.posted.all.map(\.title) == ["Sicherheit verschlechtert"])
    }

    @Test func checkReadableForTheFirstTimeLeavesNoHistory() async throws {
        let harness = try Harness(script: [
            InventoryContribution(securityChecks: [SecurityCheck.failed(.gatekeeper, detail: "nicht lesbar")]),
            InventoryContribution(securityChecks: [TestData.evaluatedCheck(.gatekeeper(enabled: false))]),
        ])
        var states = await harness.engine.states().makeAsyncIterator()
        await harness.engine.start()
        _ = try #require(await states.next(where: scanned(at: harness.now)))
        harness.advance(seconds: 60)
        await harness.engine.scanNow()
        _ = try #require(await states.next(where: scanned(at: harness.now)))
        await harness.engine.stop()
        #expect(try await harness.store.events(limit: 10).isEmpty)
        #expect(harness.posted.all.isEmpty)
    }
}
