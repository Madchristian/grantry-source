import Testing
@testable import ManagerKit

/// CPU-Zeit für den Tab „Details“: vom Zähler bis in den Snapshot, auch nach dem Ergänzen fremder Prozesse aus `ps`.
@Suite struct ProcessCPUTimeTests {
    private static func counters(cpu: UInt64?, uid: UInt32 = 501) -> ProcessCounters {
        ProcessCounters(key: ProcessKey(pid: 42, startTime: 7), parentPID: 1, uid: uid, name: "worker",
                        cpuTimeNanoseconds: cpu, diskBytesRead: nil, diskBytesWritten: nil, memoryBytes: nil,
                        threadCount: nil)
    }

    @Test func snapshotCarriesCumulativeCPUTime() {
        var accumulator = TaskManagerAccumulator(interval: .oneSecond)
        let frame = accumulator.ingest(TaskManagerReadings(processes: .success([Self.counters(cpu: 3_500_000_000)])),
                                       elapsed: nil)
        #expect(frame.snapshot.processes.first?.cpuTimeNanoseconds == 3_500_000_000)
    }

    @Test func unreadableCPUTimeStaysNil() {
        var accumulator = TaskManagerAccumulator(interval: .oneSecond)
        let frame = accumulator.ingest(TaskManagerReadings(processes: .success([Self.counters(cpu: nil, uid: 0)])),
                                       elapsed: nil)
        #expect(frame.snapshot.processes.first?.cpuTimeNanoseconds == nil)
    }

    @Test func fillingForeignUsageKeepsCPUTime() {
        var snapshot = TaskManagerSnapshot()
        snapshot.processes = [ProcessMeasurement(key: ProcessKey(pid: 88, startTime: 1), parentPID: 1, uid: 88,
                                                 name: "WindowServer", cpuLoad: nil, memoryBytes: nil,
                                                 diskReadPerSecond: nil, diskWritePerSecond: nil, threadCount: nil,
                                                 cpuTimeNanoseconds: 9)]
        let filled = snapshot.fillingForeignUsage([88: ForeignProcessUsage(uid: 88, cpuLoad: 0.1, residentBytes: 1)],
                                                  currentUID: 501)
        #expect(filled.processes[0].cpuTimeNanoseconds == 9)
        #expect(filled.processes[0].cpuLoad == 0.1)
    }
}
