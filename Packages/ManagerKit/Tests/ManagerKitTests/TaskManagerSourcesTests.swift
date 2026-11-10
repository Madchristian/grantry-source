import Testing
@testable import ManagerKit

@Suite struct TaskManagerSourcesTests {
    @Test func reportsConfiguredSources() {
        let sources = TaskManagerSources(
            cpu: ScriptedMetricSource(readings: [CPULoadReading(cores: [])]),
            gpu: ScriptedMetricSource(readings: [GPULoadReading(utilization: 0.5, usedMemoryBytes: nil)])
        )
        #expect(sources.configured == [.cpu, .gpu])
    }

    @Test func systemSourcesMeasureProcesses() {
        #expect(TaskManagerSources.system.configured.contains(.processes))
    }

    @Test func systemSourcesMeasurePerformance() {
        #expect(TaskManagerSources.system.configured.isSuperset(of: [.cpu, .memory, .disks, .interfaces]))
    }

    @Test func scriptedSourceReturnsResultsInOrderAndRepeatsTheLast() throws {
        let source = ScriptedMetricSource<Int>(results: [.success(1), .failure(SourceFailure(message: "x")), .success(3)])
        #expect(try source.read() == 1)
        #expect(throws: SourceFailure.self) { try source.read() }
        #expect(try source.read() == 3)
        #expect(try source.read() == 3)
        #expect(source.callCount == 4)
    }

    @Test func intervalsHaveExpectedDurations() {
        #expect(TaskManagerInterval.allCases.map(\.duration) == [.milliseconds(500), .seconds(1), .seconds(2), .seconds(5)])
        #expect(TaskManagerInterval.default == .oneSecond)
    }
}
