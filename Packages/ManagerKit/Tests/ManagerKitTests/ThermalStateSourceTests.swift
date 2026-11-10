import Combine
import Foundation
import Testing
@testable import ManagerKit

/// Thermischer Zustand und Energiesparmodus ohne Helper (TM-14.2): Wechselbenachrichtigung statt Abfrage im Takt,
/// Verlauf als Zustandsreihe.
@MainActor
@Suite struct ThermalStateSourceTests {
    /// Meldet Wechsel nur auf `send`; zählt, wie oft der Stand gelesen wird.
    final class FakeProvider: ThermalConditionProviding, @unchecked Sendable {
        var condition: ThermalCondition
        private(set) var reads = 0
        private(set) var isObserved = false
        private var onChange: (@MainActor () -> Void)?

        init(_ condition: ThermalCondition = .nominal) { self.condition = condition }

        func currentCondition() -> ThermalCondition {
            reads += 1
            return condition
        }

        func observeChanges(_ onChange: @escaping @MainActor @Sendable () -> Void) -> AnyCancellable {
            self.onChange = onChange
            isObserved = true
            return AnyCancellable { [weak self] in
                self?.onChange = nil
                self?.isObserved = false
            }
        }

        /// Wie die Benachrichtigung von `ProcessInfo` auf dem Hauptthread.
        @MainActor func send(_ condition: ThermalCondition) {
            self.condition = condition
            onChange?()
        }
    }

    final class Now: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 1_794_009_600)
        func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
    }

    private static let fair = ThermalCondition(state: .fair, isLowPowerModeEnabled: false)
    private static let lowPower = ThermalCondition(state: .nominal, isLowPowerModeEnabled: true)

    private func source(_ provider: FakeProvider, now: Now, span: TimeInterval = 900) -> ThermalStateSource {
        ThermalStateSource(provider: provider, now: { now.date }, span: span)
    }

    @Test func readsOnceAtStartAndRecordsTheFirstState() {
        let provider = FakeProvider()
        let now = Now()
        let source = source(provider, now: now)
        #expect(source.current == .nominal)
        #expect(provider.reads == 1)
        #expect(provider.isObserved)
        #expect(source.history.changes == [.init(time: now.date, condition: .nominal)])
    }

    /// Abnahmekriterium 2: Der Stand kommt per Wechselbenachrichtigung, Lesen von `current` fragt das System nicht.
    @Test func readingTheCurrentStateDoesNotQueryTheSystem() {
        let provider = FakeProvider()
        let source = source(provider, now: Now())
        for _ in 0..<100 { _ = source.current }
        #expect(provider.reads == 1)
    }

    @Test func changeNotificationUpdatesStateAndHistory() {
        let provider = FakeProvider()
        let now = Now()
        let source = source(provider, now: now)
        let start = now.date
        now.advance(30)
        provider.send(Self.fair)
        now.advance(30)
        provider.send(Self.lowPower)
        #expect(source.current == Self.lowPower)
        #expect(provider.reads == 3)
        #expect(source.history.changes.map(\.condition) == [.nominal, Self.fair, Self.lowPower])
        #expect(source.history.changes.map(\.time) == [start, start.addingTimeInterval(30), start.addingTimeInterval(60)])
    }

    /// Benachrichtigungen ohne Änderung (etwa beide Namen nacheinander) ergeben keinen neuen Abschnitt.
    @Test func notificationWithoutChangeKeepsTheHistory() {
        let provider = FakeProvider()
        let now = Now()
        let source = source(provider, now: now)
        now.advance(10)
        provider.send(.nominal)
        #expect(source.history.changes.count == 1)
    }

    @Test func endsObservationWhenReleased() {
        let provider = FakeProvider()
        var source: ThermalStateSource? = source(provider, now: Now())
        #expect(provider.isObserved)
        _ = source
        source = nil
        #expect(!provider.isObserved)
    }

    // MARK: Zustandsreihe

    private static let t0 = Date(timeIntervalSince1970: 1_794_009_600)
    private static func t(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    @Test func segmentsCoverTheRangeFromTheFirstKnownState() {
        var history = ThermalStateHistory(span: 900)
        history.record(.nominal, at: Self.t(10))
        history.record(Self.fair, at: Self.t(40))
        let segments = history.segments(from: Self.t(0), to: Self.t(60))
        // Vor der ersten Messung ist nichts bekannt: Lücke statt „normal“.
        #expect(segments == [.init(start: Self.t(10), end: Self.t(40), condition: .nominal),
                             .init(start: Self.t(40), end: Self.t(60), condition: Self.fair)])
        #expect(history.condition(at: Self.t(5)) == nil)
        #expect(history.condition(at: Self.t(40)) == Self.fair)
    }

    @Test func segmentsAreClippedToTheRange() {
        var history = ThermalStateHistory(span: 900)
        history.record(.nominal, at: Self.t(0))
        history.record(Self.fair, at: Self.t(100))
        #expect(history.segments(from: Self.t(50), to: Self.t(80))
                    == [.init(start: Self.t(50), end: Self.t(80), condition: .nominal)])
        #expect(history.segments(from: Self.t(80), to: Self.t(80)).isEmpty)
    }

    /// Ältere Wechsel entfallen; der Stand am Beginn des Zeitraums bleibt bekannt.
    @Test func dropsChangesOlderThanTheSpanButKeepsTheStateAtItsStart() {
        var history = ThermalStateHistory(span: 60)
        history.record(.nominal, at: Self.t(0))
        history.record(Self.fair, at: Self.t(10))
        history.record(.nominal, at: Self.t(20))
        history.record(Self.fair, at: Self.t(100))
        #expect(history.changes.map(\.time) == [Self.t(20), Self.t(100)])
        #expect(history.condition(at: Self.t(40)) == .nominal)
    }

    /// Ausgaben begrenzen: Auch ein flatternder Zustand belegt höchstens `maximumChanges` Einträge.
    @Test func limitsTheNumberOfChanges() {
        var history = ThermalStateHistory(span: 86_400)
        for index in 0..<(ThermalStateHistory.maximumChanges * 2) {
            history.record(index.isMultiple(of: 2) ? .nominal : Self.fair, at: Self.t(Double(index)))
        }
        #expect(history.changes.count == ThermalStateHistory.maximumChanges)
        #expect(history.changes.last?.time == Self.t(Double(ThermalStateHistory.maximumChanges * 2 - 1)))
    }

    /// Eine zurückgestellte Uhr bringt die Reihe nicht durcheinander.
    @Test func keepsTheOrderWhenTheClockGoesBack() {
        var history = ThermalStateHistory(span: 900)
        history.record(.nominal, at: Self.t(100))
        history.record(Self.fair, at: Self.t(50))
        #expect(history.changes.map(\.time) == [Self.t(100), Self.t(100)])
        #expect(history.condition(at: Self.t(100)) == Self.fair)
    }

    @Test func systemProviderReadsProcessInfo() {
        let condition = SystemThermalConditionProvider().currentCondition()
        #expect(condition.state == ProcessInfo.processInfo.thermalState)
        #expect(condition.isLowPowerModeEnabled == ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}
