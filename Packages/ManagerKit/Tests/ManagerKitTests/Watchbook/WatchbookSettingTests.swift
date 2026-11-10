import Foundation
import Testing
@testable import ManagerKit

/// Einstellung „Wachbuch führen“ (TM-12.3): Standard aus (Entscheidung O1), wirkt erst ab dem App-Start und gibt die
/// Aufrufe in Reihenfolge an den Recorder weiter.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct WatchbookSettingTests {
    final class FakeRecorder: WatchbookRecording {
        enum Call: Equatable, Sendable {
            case enabled(Bool), thermal(ThermalCondition), changes([UUID]), findings([WatchbookEvent]), willSleep, didWake
            case shutdown, retention
        }

        let calls = Recorder<Call>()

        func setEnabled(_ enabled: Bool) async { calls.append(.enabled(enabled)) }
        func setThermalCondition(_ condition: ThermalCondition) async { calls.append(.thermal(condition)) }
        func recordChanges(_ history: [HistoryEvent]) async { calls.append(.changes(history.map(\.id))) }
        func recordFindings(_ events: [WatchbookEvent]) async { calls.append(.findings(events)) }
        func systemWillSleep() async { calls.append(.willSleep) }
        func systemDidWake() async { calls.append(.didWake) }
        func shutdown() async { calls.append(.shutdown) }
        func enforceRetention() async { calls.append(.retention) }
    }

    private let settings = InMemorySettingsStore()
    private let recorder = FakeRecorder()

    private func model() -> WatchbookModel {
        WatchbookModel(recorder: recorder, settings: settings)
    }

    @Test func isOffByDefault() async {
        let model = model()
        model.activate()
        await model.settle()
        #expect(!model.isEnabled)
        #expect(recorder.calls.values.isEmpty)
    }

    @Test func storedChoiceStartsRecordingOnActivate() async {
        settings.set(true, forKey: WatchbookModel.storageKey)
        let model = model()
        #expect(model.isEnabled)
        await model.settle()
        #expect(recorder.calls.values.isEmpty)
        model.activate()
        await model.settle()
        #expect(recorder.calls.values == [.enabled(true)])
    }

    @Test func switchingIsRememberedAndForwardedInOrder() async {
        let model = model()
        model.activate()
        model.isEnabled = true
        model.isEnabled = false
        model.isEnabled = true
        await model.settle()
        #expect(recorder.calls.values == [.enabled(true), .enabled(false), .enabled(true)])
        #expect(settings.bool(forKey: WatchbookModel.storageKey))
    }

    /// „Aufzeichnung an seit …“ (TM-12.5): Einschalten merkt sich den Zeitpunkt, Ausschalten vergisst ihn.
    @Test func switchingOnRemembersSinceWhenItRecords() {
        let start = WatchbookFixtures.dayStart
        let model = WatchbookModel(recorder: recorder, settings: settings, now: { start })
        #expect(model.recordingSince == nil)
        model.isEnabled = true
        #expect(model.recordingSince == start)
        #expect(WatchbookModel(recorder: recorder, settings: settings).recordingSince == start)
        model.isEnabled = false
        #expect(model.recordingSince == nil)
        #expect(WatchbookModel(recorder: recorder, settings: settings).recordingSince == nil)
    }

    @Test func switchingBeforeActivateOnlyRemembers() async {
        let model = model()
        model.isEnabled = true
        await model.settle()
        #expect(recorder.calls.values.isEmpty)
        #expect(settings.bool(forKey: WatchbookModel.storageKey))
    }

    private static func change(_ label: String, at offset: TimeInterval) -> ChangeEvent {
        ChangeEvent(kind: .added, before: nil, after: .autostartItem(TestData.item(label)),
                    detectedAt: WatchbookFixtures.dayStart.addingTimeInterval(offset))
    }

    /// Beim Einschalten der Nachtrag aus dem Verlauf (nur innerhalb der Aufbewahrung), nach dem Einschalten.
    @Test func switchingOnBackfillsTheHistory() async throws {
        let history = try SwiftDataSnapshotStore.inMemory()
        _ = try await history.record(TestData.snapshot(), events: [
            Self.change("alt", at: -8 * 86_400), Self.change("neu", at: -3_600),
        ])
        let recent = try await history.events(since: WatchbookFixtures.dayStart.addingTimeInterval(-86_400))
        let model = WatchbookModel(recorder: recorder, history: history, settings: settings,
                                   now: { WatchbookFixtures.dayStart })
        model.activate()
        model.isEnabled = true
        await model.settle()
        #expect(recorder.calls.values == [.enabled(true), .changes(recent.map(\.id))])
    }

    /// Nach jedem Scan nur die Einträge, die beim letzten noch nicht dabei waren; ausgeschaltet keine.
    @Test func forwardsOnlyNewChangesWhileOn() async {
        let first = HistoryEvent(id: UUID(), event: Self.change("a", at: 0), isRead: false)
        let second = HistoryEvent(id: UUID(), event: Self.change("b", at: 10), isRead: false)
        let model = model()
        model.activate()
        model.recordChanges([first])
        model.isEnabled = true
        model.recordChanges([second, first])
        model.recordChanges([second, first])
        await model.settle()
        #expect(recorder.calls.values == [.enabled(true), .changes([second.id])])
    }

    private static func smartFailure(at offset: TimeInterval) -> SystemFinding {
        let inventory = VolumeInventory(devices: [StorageDevice(id: "disk4", name: "Extern", smartStatus: .failing)],
                                        localSnapshots: nil, isComplete: true)
        return FindingRules.storageFindings(in: inventory, at: WatchbookFixtures.dayStart.addingTimeInterval(offset))[0]
    }

    /// Datenträger-Befunde (TM-15.5): ein neuer beginnt, ein fortgesetzter schreibt nichts erneut, ein widerlegter endet
    /// mit der Prüfung, die ihn widerlegt. Ausgeschaltet geht nichts weiter; nach dem Einschalten beginnt, was läuft.
    @Test func forwardsStorageFindingChanges() async {
        let model = model()
        model.activate()
        let finding = Self.smartFailure(at: 0)
        let end = WatchbookFixtures.dayStart.addingTimeInterval(1_800)
        model.recordStorageFindings([finding], at: finding.start)
        model.isEnabled = true
        model.recordStorageFindings([finding], at: finding.start.addingTimeInterval(900))
        model.recordStorageFindings([finding], at: finding.start.addingTimeInterval(1_000))
        model.recordStorageFindings([], at: end)
        await model.settle()
        let ended = recorder.calls.values.last
        #expect(recorder.calls.values.dropLast() == [.enabled(true), .findings([finding.watchbookEvent])])
        guard case .findings(let events)? = ended else {
            Issue.record("Ende fehlt")
            return
        }
        #expect(events.map(\.id) == [finding.id])
        #expect(events.first?.end == end)
    }

    /// Thermik und Energiesparmodus: der Stand beim Start und jeder Wechsel der gemeinsamen Quelle.
    @Test func forwardsTheThermalConditionAndItsChanges() async throws {
        let provider = ThermalStateSourceTests.FakeProvider()
        let source = ThermalStateSource(provider: provider, now: { WatchbookFixtures.dayStart })
        let model = WatchbookModel(recorder: recorder, thermal: source, settings: settings)
        model.activate()
        try await eventually { recorder.calls.values == [.thermal(.nominal)] }
        let serious = ThermalCondition(state: .serious, isLowPowerModeEnabled: false)
        provider.send(serious)
        try await eventually { recorder.calls.values == [.thermal(.nominal), .thermal(serious)] }
        await model.stop()
    }

    private struct ConditionTimedOut: Error {}

    /// Wartet suspendierend, bis `condition` gilt; die Frist greift nur im Fehlerfall.
    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ConditionTimedOut() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func forwardsSleepWakeRetentionAndStop() async {
        let model = model()
        model.activate()
        model.systemWillSleep()
        model.systemDidWake()
        model.enforceRetention()
        await model.stop()
        #expect(recorder.calls.values == [.willSleep, .didWake, .retention, .shutdown])
    }
}
