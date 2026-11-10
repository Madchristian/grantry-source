import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@MainActor
@Suite(.timeLimit(.minutes(1))) struct TaskManagerModelTests {
    private let clock = TestClock()

    private static let memory = MemoryStatus(physicalBytes: 16, usedBytes: 8, swapUsedBytes: nil, swapTotalBytes: nil,
                                             pressure: .normal, processCount: 0)

    private func model() -> TaskManagerModel {
        TaskManagerModel(sources: TaskManagerSources(memory: ScriptedMetricSource(readings: [Self.memory])),
                         clock: clock, failures: SourceFailureLog(report: { _, _ in }))
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

    @Test func measuresWhileAConsumerIsActive() async throws {
        let model = model()
        model.start(for: .window)
        #expect(model.isRunning)
        try await eventually { model.frame.snapshot.memory?.usedBytes == 8 }
        model.stop(for: .window)
        #expect(!model.isRunning)
        await model.stopAndWait()
    }

    @Test func stampsEachFrameWithItsArrival() async throws {
        let arrival = Date(timeIntervalSinceReferenceDate: 1_000)
        let model = TaskManagerModel(sources: TaskManagerSources(memory: ScriptedMetricSource(readings: [Self.memory])),
                                     clock: clock, failures: SourceFailureLog(report: { _, _ in }), now: { arrival })
        #expect(model.frameDate == .distantPast)
        model.start(for: .window)
        try await eventually { model.frameDate == arrival }
        await model.stopAndWait()
    }

    @Test func keepsMeasuringForRemainingConsumer() async {
        let model = model()
        model.start(for: .window)
        model.start(for: .menuBar)
        model.stop(for: .window)
        #expect(model.isRunning)
        await model.stopAndWait()
        #expect(!model.isRunning)
    }

    @Test func changingIntervalRestartsWithNewInterval() async throws {
        let model = model()
        model.start(for: .window)
        await clock.waitForSleeper(until: TestClock.Instant(offset: .seconds(1)))
        model.interval = .twoSeconds
        await clock.waitForSleeper(until: TestClock.Instant(offset: .seconds(2)))
        try await eventually { model.frame.history.interval == .seconds(2) && model.frame.snapshot.memory != nil }
        await model.stopAndWait()
    }

    /// Das Wachbuch greift die Takte ab, statt selbst zu messen (TM-12.3).
    @Test func passesEachRunToTheTap() async throws {
        let tap = RecordingTaskManagerTap()
        let disks = ScriptedMetricSource(readings: [[DriveCounters(id: "disk0", name: "SSD", bytesRead: 7,
                                                                   bytesWritten: 0)]])
        let model = TaskManagerModel(sources: TaskManagerSources(disks: disks), clock: clock,
                                     failures: SourceFailureLog(report: { _, _ in }))
        model.tap = tap
        model.start(for: .menuBar)
        try await eventually { tap.seen.values.count >= 2 }
        await model.stopAndWait()
        #expect(tap.seen.values == [.started, .measured(readBytes: 7, readPerSecond: nil), .stopped])
    }

    @Test func reportsConfiguredSources() {
        #expect(model().configuredSources == [.memory])
    }

    private func modelWithProcesses() -> (TaskManagerModel, ScriptedMetricSource<[ProcessCounters]>,
                                          ScriptedMetricSource<MemoryStatus>) {
        let processes = ScriptedMetricSource<[ProcessCounters]>(readings: [[]])
        let memory = ScriptedMetricSource(readings: [Self.memory])
        let model = TaskManagerModel(sources: TaskManagerSources(processes: processes, memory: memory), clock: clock,
                                     failures: SourceFailureLog(report: { _, _ in }))
        return (model, processes, memory)
    }

    @Test func menuBarAloneReadsOnlyItsSources() async {
        let (model, processes, memory) = modelWithProcesses()
        model.start(for: .menuBar)
        await clock.waitForSleeper(until: TestClock.Instant(offset: .seconds(1)))
        #expect(memory.callCount == 1)
        #expect(processes.callCount == 0)
        await model.stopAndWait()
    }

    @Test func windowJoiningAddsSourcesWithoutRestart() async throws {
        let (model, processes, memory) = modelWithProcesses()
        model.start(for: .menuBar)
        await clock.waitForSleeper(until: TestClock.Instant(offset: .seconds(1)))
        model.start(for: .window)
        _ = clock.advance(by: .seconds(1))
        await clock.waitForSleeper(until: TestClock.Instant(offset: .seconds(2)))
        #expect(processes.callCount == 1)
        try await eventually { model.frame.history.series[.memoryUsed]?.values.count == 2 }

        model.stop(for: .window)
        #expect(model.isRunning)
        _ = clock.advance(by: .seconds(1))
        await clock.waitForSleeper(until: TestClock.Instant(offset: .seconds(3)))
        #expect(processes.callCount == 1)
        #expect(memory.callCount == 3)
        await model.stopAndWait()
    }

    /// Mangel 2b der Bewertung 2026.11.9/1510: Ohne Fenster als Abnehmer (geschlossen, verdeckt) folgt dessen Stand nicht
    /// dem Takt der Menüleiste – seine Ansichten rechneten und zeichneten sonst weiter. Kommt es zurück, zeigt es sofort
    /// den jüngsten Stand samt Verlauf.
    @Test func windowFrameFollowsTheTaktOnlyWhileTheWindowMeasures() async throws {
        let model = model()
        model.start(for: .menuBar)
        model.start(for: .window)
        try await eventually { model.frame.history.series[.memoryUsed]?.values.count == 1 }
        let windowDate = model.frameDate
        model.stop(for: .window)
        await clock.waitForSleeper(until: TestClock.Instant(offset: .seconds(1)))
        _ = clock.advance(by: .seconds(1))
        try await eventually { model.latestFrame.history.series[.memoryUsed]?.values.count == 2 }
        #expect(model.frame.history.series[.memoryUsed]?.values.count == 1)
        #expect(model.frameDate == windowDate)

        model.start(for: .window)
        #expect(model.frame.history.series[.memoryUsed]?.values.count == 2)
        #expect(model.frameDate == model.latestFrameDate)
        await model.stopAndWait()
    }

    @Test func menuBarAloneLeavesTheWindowFrameEmpty() async throws {
        let model = model()
        model.start(for: .menuBar)
        try await eventually { model.latestFrame.snapshot.memory != nil }
        #expect(model.frame.snapshot.memory == nil)
        #expect(model.frameDate == .distantPast)
        await model.stopAndWait()
    }

    /// Mangel 7 der Bewertung 2026.11.7: Ein neuer Lauf mit demselben Takt setzt den Verlauf fort und trägt die Pause als
    /// Lücke ein, statt leer zu beginnen.
    @Test func restartContinuesHistoryWithAGap() async throws {
        final class Now: @unchecked Sendable { var date = Date(timeIntervalSinceReferenceDate: 1_000) }
        let now = Now()
        let model = TaskManagerModel(sources: TaskManagerSources(memory: ScriptedMetricSource(readings: [Self.memory])),
                                     clock: clock, failures: SourceFailureLog(report: { _, _ in }), now: { now.date })
        model.start(for: .window)
        try await eventually { model.frame.history.series[.memoryUsed]?.values.count == 1 }
        model.stop(for: .window)
        await model.stopAndWait()
        now.date = now.date.addingTimeInterval(5)
        model.start(for: .window)
        try await eventually { model.frame.history.series[.memoryUsed]?.values.compactMap(\.self).count == 2 }
        let values = model.frame.history.series[.memoryUsed]?.values ?? []
        #expect(values.count == 6)
        #expect(values.dropFirst().dropLast().allSatisfy { $0 == nil })
        await model.stopAndWait()
    }

    // MARK: Thermik und Drosselung (TM-14.2)

    private static let fair = ThermalCondition(state: .fair, isLowPowerModeEnabled: false)

    /// Abnahmekriterium 2: Jeder Takt trägt den Stand der Quelle, die ihn nur bei einer Wechselbenachrichtigung liest –
    /// kein zusätzlicher Takt, keine Abfrage je Takt.
    @Test func framesCarryTheThermalConditionWithoutPolling() async throws {
        let provider = ThermalStateSourceTests.FakeProvider()
        let model = TaskManagerModel(sources: TaskManagerSources(memory: ScriptedMetricSource(readings: [Self.memory])),
                                     clock: clock, failures: SourceFailureLog(report: { _, _ in }),
                                     thermal: ThermalStateSource(provider: provider))
        model.start(for: .window)
        for second in 1...3 {
            await clock.waitForSleeper(until: TestClock.Instant(offset: .seconds(second)))
            _ = clock.advance(by: .seconds(1))
        }
        try await eventually { model.frame.history.series[.memoryUsed]?.values.count == 4 }
        #expect(model.frame.snapshot.thermal == .nominal)
        #expect(provider.reads == 1)

        provider.send(Self.fair)
        await clock.waitForSleeper(until: TestClock.Instant(offset: .seconds(4)))
        _ = clock.advance(by: .seconds(1))
        try await eventually { model.frame.snapshot.thermal == Self.fair }
        #expect(provider.reads == 2)
        await model.stopAndWait()
    }

    /// Sensor-Messungen des Helpers speisen die Regel „Drosselung“ der Lagezeile.
    @Test func sensorReadingsFeedTheThrottlingFinding() async throws {
        final class Now: @unchecked Sendable { var date = Date(timeIntervalSinceReferenceDate: 1_000) }
        let now = Now()
        let model = TaskManagerModel(sources: TaskManagerSources(memory: ScriptedMetricSource(readings: [Self.memory])),
                                     clock: clock, failures: SourceFailureLog(report: { _, _ in }), now: { now.date },
                                     thermal: ThermalStateSource(provider: ThermalStateSourceTests.FakeProvider()))
        let throttled = SensorReading(clusters: [.init(name: "P-Cluster", frequencyMHz: 2000, activeShare: 0.9,
                                                       maximumFrequencyMHz: 4000)], thermalPressure: .moderate)
        // Ohne laufende Messung zählt nichts.
        model.record(sensors: throttled)
        model.start(for: .window)
        for _ in 0...30 {
            model.record(sensors: throttled)
            now.date = now.date.addingTimeInterval(2)
        }
        #expect(model.findings.map(\.kind) == [.throttling])
        await model.stopAndWait()
    }
}

