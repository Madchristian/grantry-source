import Testing
@testable import ManagerKit

@Suite struct PerformanceSourcesSystemTests {
    @Test func systemSourcesProduceAPerformanceFrame() async throws {
        var accumulator = TaskManagerAccumulator(interval: .oneSecond)
        _ = accumulator.ingest(await TaskManagerReadings.read(.system), elapsed: nil)
        let frame = accumulator.ingest(await TaskManagerReadings.read(.system), elapsed: .seconds(1))
        #expect(frame.snapshot.unavailable.isEmpty)
        let cpu = try #require(frame.snapshot.cpu)
        #expect(cpu.cores.count == Sysctl.int("hw.ncpu"))
        #expect(frame.snapshot.memory?.components != nil)
        #expect(frame.snapshot.interfaces.contains { $0.name == "lo0" })
        #expect(!frame.snapshot.drives.isEmpty)
        #expect(frame.history.points(for: .memory(.app), in: .oneMinute).count == 2)
    }
}
