import Testing
import TestSupport
@testable import ManagerKit

@Suite(.timeLimit(.minutes(1))) struct TaskManagerEngineTests {
    private static let silent = SourceFailureLog(report: { _, _ in })

    @Test func measuresImmediatelyThenOncePerInterval() async {
        let clock = TestClock()
        let disks = ScriptedMetricSource(readings: [
            [DriveCounters(id: "disk0", name: "SSD", bytesRead: 0, bytesWritten: 0)],
            [DriveCounters(id: "disk0", name: "SSD", bytesRead: 100, bytesWritten: 0)],
        ])
        let frames = Recorder<TaskManagerFrame>()
        let engine = TaskManagerEngine(sources: TaskManagerSources(disks: disks), interval: .oneSecond, clock: clock,
                                       failures: Self.silent)
        let run = Task { await engine.run { frames.append($0) } }

        await clock.waitForSleeper(until: TestClock.Instant(offset: .seconds(1)))
        #expect(frames.values.count == 1)
        _ = clock.advance(by: .seconds(1))
        await clock.waitForSleeper(until: TestClock.Instant(offset: .seconds(2)))
        #expect(frames.values.map { $0.snapshot.drives.first?.readPerSecond } == [nil, 100])

        run.cancel()
        await run.value
    }

    @Test func reportsEachFailingSourceOnce() async {
        let clock = TestClock()
        let reports = Recorder<TaskManagerSource>()
        let gpu = ScriptedMetricSource<GPULoadReading>(results: [.failure(SourceFailure(message: "IOKit"))])
        let engine = TaskManagerEngine(sources: TaskManagerSources(gpu: gpu), interval: .oneSecond, clock: clock,
                                       failures: SourceFailureLog(report: { source, _ in reports.append(source) }))
        let run = Task { await engine.run { _ in } }

        await clock.waitForSleeper(until: TestClock.Instant(offset: .seconds(1)))
        _ = clock.advance(by: .seconds(1))
        await clock.waitForSleeper(until: TestClock.Instant(offset: .seconds(2)))
        #expect(gpu.callCount == 2)
        #expect(reports.values == [.gpu])

        run.cancel()
        await run.value
    }
}

/// Abgriff der Takte für das Wachbuch (TM-12.3): Beginn und Ende eines Laufs, je Takt Rohmessung und fertiger Stand.
@Suite(.timeLimit(.minutes(1))) struct TaskManagerEngineTapTests {
    @Test func tapSeesStartEachTaktAndStop() async {
        let clock = TestClock()
        let disks = ScriptedMetricSource(readings: [
            [DriveCounters(id: "disk0", name: "SSD", bytesRead: 0, bytesWritten: 0)],
            [DriveCounters(id: "disk0", name: "SSD", bytesRead: 100, bytesWritten: 0)],
        ])
        let tap = RecordingTaskManagerTap()
        let engine = TaskManagerEngine(sources: TaskManagerSources(disks: disks),
                                       selection: TaskManagerSourceSelection([.disks]), interval: .oneSecond,
                                       clock: clock, failures: SourceFailureLog(report: { _, _ in }), tap: tap)
        let run = Task { await engine.run { _ in } }

        await clock.waitForSleeper(until: .at(.seconds(1)))
        _ = clock.advance(by: .seconds(1))
        await clock.waitForSleeper(until: .at(.seconds(2)))
        run.cancel()
        await run.value

        #expect(tap.seen.values == [
            .started, .measured(readBytes: 0, readPerSecond: nil), .measured(readBytes: 100, readPerSecond: 100),
            .stopped,
        ])
    }
}
