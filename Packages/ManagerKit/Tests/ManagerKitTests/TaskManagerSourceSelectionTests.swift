import Testing
import TestSupport
@testable import ManagerKit

@Suite(.timeLimit(.minutes(1))) struct TaskManagerSourceSelectionTests {
    private static let memory = MemoryStatus(physicalBytes: 16, usedBytes: 8, swapUsedBytes: nil, swapTotalBytes: nil,
                                             pressure: .normal, processCount: 0)

    @Test func restrictedKeepsOnlySelectedSources() {
        let sources = TaskManagerSources(
            processes: ScriptedMetricSource(readings: [[]]),
            cpu: ScriptedMetricSource(readings: [CPULoadReading(cores: [])]),
            memory: ScriptedMetricSource(readings: [Self.memory]),
            gpu: ScriptedMetricSource(readings: [GPULoadReading(utilization: 0.5, usedMemoryBytes: nil)])
        )
        #expect(sources.restricted(to: [.cpu, .memory]).configured == [.cpu, .memory])
        #expect(sources.restricted(to: []).configured.isEmpty)
        #expect(sources.restricted(to: Set(TaskManagerSource.allCases)).configured == sources.configured)
    }

    @Test func menuBarNeedsOnlyItsFourGraphs() {
        #expect(TaskManagerModel.Consumer.menuBar.sources == [.cpu, .memory, .disks, .interfaces])
        #expect(TaskManagerModel.Consumer.window.sources == Set(TaskManagerSource.allCases))
    }

    @Test func restrictedPassesTheBatterySourceOn() {
        let battery = ScriptedMetricSource(readings: [BatteryReading(charge: 0.5, source: .battery)])
        let sources = TaskManagerSources(memory: ScriptedMetricSource(readings: [Self.memory]), battery: battery)
        #expect(sources.restricted(to: [.battery]).configured == [.battery])
        #expect(sources.restricted(to: [.memory]).configured == [.memory])
        #expect(sources.restricted(to: TaskManagerModel.Consumer.window.sources).configured == [.memory, .battery])
        #expect(sources.restricted(to: TaskManagerModel.Consumer.menuBar.sources).configured == [.memory])
    }

    /// Übersicht der Menüleiste (#495): Prozesse, GPU und Akku nur, solange ihr Popover offen ist.
    @Test func openOverviewPopoverReadsEverySource() {
        #expect(TaskManagerModel.Consumer.menuBarPopover.sources == Set(TaskManagerSource.allCases))
        #expect(!MenuBarMeterKind.overview.sources.contains(.processes))
    }

    @Test func onlyTheWindowNeedsTheBattery() {
        #expect(TaskManagerModel.Consumer.window.sources.contains(.battery))
        #expect(!TaskManagerModel.Consumer.menuBar.sources.contains(.battery))
    }

    @Test func engineReadsTheCurrentSelectionEachTakt() async {
        let clock = TestClock()
        let processes = ScriptedMetricSource<[ProcessCounters]>(readings: [[]])
        let memory = ScriptedMetricSource(readings: [Self.memory])
        let selection = TaskManagerSourceSelection([.memory])
        let engine = TaskManagerEngine(sources: TaskManagerSources(processes: processes, memory: memory),
                                       selection: selection, interval: .oneSecond, clock: clock,
                                       failures: SourceFailureLog(report: { _, _ in }))
        let run = Task { await engine.run { _ in } }

        await clock.waitForSleeper(until: TestClock.Instant(offset: .seconds(1)))
        #expect(processes.callCount == 0)
        selection.select([.memory, .processes])
        _ = clock.advance(by: .seconds(1))
        await clock.waitForSleeper(until: TestClock.Instant(offset: .seconds(2)))
        #expect(processes.callCount == 1)
        #expect(memory.callCount == 2)

        run.cancel()
        await run.value
    }
}
