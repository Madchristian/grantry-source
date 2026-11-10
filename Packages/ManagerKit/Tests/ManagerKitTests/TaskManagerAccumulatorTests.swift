import Testing
@testable import ManagerKit

@Suite struct TaskManagerAccumulatorTests {
    private func process(_ pid: Int32, start: UInt64 = 1, cpuNanoseconds: UInt64) -> ProcessCounters {
        ProcessCounters(key: ProcessKey(pid: pid, startTime: start), parentPID: 1, uid: 501, name: "p\(pid)",
                        cpuTimeNanoseconds: cpuNanoseconds, diskBytesRead: 0, diskBytesWritten: 0,
                        memoryBytes: 1024, threadCount: 4)
    }

    private func drive(read: UInt64) -> [DriveCounters] {
        [DriveCounters(id: "disk0", name: "SSD", bytesRead: read, bytesWritten: 0)]
    }

    private func accumulator() -> TaskManagerAccumulator {
        TaskManagerAccumulator(interval: .oneSecond, fallbackCoreCount: 4)
    }

    @Test func firstMeasurementIsBaselineWithoutRates() {
        var accumulator = accumulator()
        let frame = accumulator.ingest(TaskManagerReadings(processes: .success([process(10, cpuNanoseconds: 0)])),
                                       elapsed: nil)
        #expect(frame.snapshot.processes.map(\.key.pid) == [10])
        #expect(frame.snapshot.processes[0].cpuLoad == nil)
        #expect(frame.snapshot.processes[0].memoryBytes == 1024)
    }

    @Test func processLoadIsShareOfFallbackCores() {
        var accumulator = accumulator()
        _ = accumulator.ingest(TaskManagerReadings(processes: .success([process(10, cpuNanoseconds: 0)])), elapsed: nil)
        let frame = accumulator.ingest(
            TaskManagerReadings(processes: .success([process(10, cpuNanoseconds: 2_000_000_000)])), elapsed: .seconds(1)
        )
        #expect(frame.snapshot.processes[0].cpuLoad == 0.5)
    }

    @Test func processLoadUsesCoreCountOfCPUReading() {
        var accumulator = accumulator()
        let cores = CPULoadReading(cores: Array(repeating: CoreTicks(kind: .performance, busy: 0, idle: 0), count: 8))
        _ = accumulator.ingest(TaskManagerReadings(processes: .success([process(10, cpuNanoseconds: 0)]),
                                                   cpu: .success(cores)), elapsed: nil)
        let frame = accumulator.ingest(
            TaskManagerReadings(processes: .success([process(10, cpuNanoseconds: 2_000_000_000)]), cpu: .success(cores)),
            elapsed: .seconds(1)
        )
        #expect(frame.snapshot.processes[0].cpuLoad == 0.25)
    }

    @Test func reusedPIDStartsWithoutRate() {
        var accumulator = accumulator()
        _ = accumulator.ingest(TaskManagerReadings(processes: .success([process(10, start: 1, cpuNanoseconds: 0)])),
                               elapsed: nil)
        let frame = accumulator.ingest(
            TaskManagerReadings(processes: .success([process(10, start: 2, cpuNanoseconds: 5_000_000_000)])),
            elapsed: .seconds(1)
        )
        #expect(frame.snapshot.processes[0].cpuLoad == nil)
    }

    @Test func failedSourceIsUnavailableAndRestartsAsBaseline() {
        var accumulator = accumulator()
        _ = accumulator.ingest(TaskManagerReadings(disks: .success(drive(read: 100))), elapsed: nil)
        let failed = accumulator.ingest(TaskManagerReadings(disks: .failure(SourceFailure(message: "IOKit"))),
                                        elapsed: .seconds(1))
        #expect(failed.snapshot.unavailable == [.disks])
        #expect(failed.snapshot.drives.isEmpty)
        let recovered = accumulator.ingest(TaskManagerReadings(disks: .success(drive(read: 300))), elapsed: .seconds(1))
        #expect(recovered.snapshot.unavailable.isEmpty)
        #expect(recovered.snapshot.drives.first?.readPerSecond == nil)
    }

    @Test func missingSourceIsNotUnavailable() {
        var accumulator = accumulator()
        #expect(accumulator.ingest(TaskManagerReadings(), elapsed: nil).snapshot.unavailable.isEmpty)
    }

    @Test func cpuTotalIsWeightedByTicks() {
        var accumulator = accumulator()
        let before = CPULoadReading(cores: [CoreTicks(kind: .performance, busy: 0, idle: 0),
                                            CoreTicks(kind: .efficiency, busy: 0, idle: 0)])
        let after = CPULoadReading(cores: [CoreTicks(kind: .performance, busy: 100, idle: 0),
                                           CoreTicks(kind: .efficiency, busy: 0, idle: 300)])
        _ = accumulator.ingest(TaskManagerReadings(cpu: .success(before)), elapsed: nil)
        let cpu = accumulator.ingest(TaskManagerReadings(cpu: .success(after)), elapsed: .seconds(1)).snapshot.cpu
        #expect(cpu?.total == 0.25)
        #expect(cpu?.cores.map(\.load) == [1, 0])
        #expect(cpu?.cores.map(\.kind) == [.performance, .efficiency])
    }

    /// Übersicht der Menüleiste (#495): Systemanteil aus denselben Ticks, nach Ticks gewichtet wie die Gesamtlast.
    @Test func cpuSystemShareIsWeightedByTicks() {
        var accumulator = accumulator()
        let before = CPULoadReading(cores: [CoreTicks(kind: .performance, busy: 0, idle: 0, system: 0),
                                            CoreTicks(kind: .efficiency, busy: 0, idle: 0, system: 0)])
        let after = CPULoadReading(cores: [CoreTicks(kind: .performance, busy: 100, idle: 0, system: 40),
                                           CoreTicks(kind: .efficiency, busy: 0, idle: 300, system: 0)])
        _ = accumulator.ingest(TaskManagerReadings(cpu: .success(before)), elapsed: nil)
        let frame = accumulator.ingest(TaskManagerReadings(cpu: .success(after)), elapsed: .seconds(1))
        #expect(frame.snapshot.cpu?.total == 0.25)
        #expect(frame.snapshot.cpu?.system == 0.1)
        #expect(frame.history.points(for: .cpuSystem, in: .oneMinute).last == 0.1)
    }

    @Test func cpuSystemShareIsMissingOnFirstMeasurement() {
        var accumulator = accumulator()
        let cores = CPULoadReading(cores: [CoreTicks(kind: .performance, busy: 10, idle: 10, system: 5)])
        let cpu = accumulator.ingest(TaskManagerReadings(cpu: .success(cores)), elapsed: nil).snapshot.cpu
        #expect(cpu?.system == nil)
    }

    @Test func recordsRatesInHistory() {
        var accumulator = accumulator()
        _ = accumulator.ingest(TaskManagerReadings(disks: .success(drive(read: 0))), elapsed: nil)
        let frame = accumulator.ingest(TaskManagerReadings(disks: .success(drive(read: 100))), elapsed: .seconds(2))
        #expect(frame.history.points(for: .diskRead("disk0"), in: .oneMinute) == [50])
    }

    /// Der Wachbuch-Takt braucht nur Raten und Auslastungen, keinen 15-min-Verlauf je Metrik (TM-12.3).
    @Test func withoutHistoryKeepsRatesButRecordsNoHistory() {
        var accumulator = TaskManagerAccumulator.withoutHistory(fallbackCoreCount: 4)
        _ = accumulator.ingest(TaskManagerReadings(disks: .success(drive(read: 0))), elapsed: nil)
        let frame = accumulator.ingest(TaskManagerReadings(disks: .success(drive(read: 100))), elapsed: .seconds(2))
        #expect(frame.snapshot.drives.first?.readPerSecond == 50)
        #expect(frame.history.series.isEmpty)
    }

    @Test func recordsMemoryInHistory() {
        var accumulator = accumulator()
        let memory = MemoryStatus(physicalBytes: 16, usedBytes: 8, swapUsedBytes: nil, swapTotalBytes: nil,
                                  pressure: .normal, processCount: 0)
        let frame = accumulator.ingest(TaskManagerReadings(memory: .success(memory)), elapsed: nil)
        #expect(frame.snapshot.memory == memory)
        #expect(frame.history.points(for: .memoryUsed, in: .oneMinute) == [8])
    }

    @Test func recordsMemoryComponentsInHistory() {
        var accumulator = accumulator()
        let components = MemoryComponents(appBytes: 4, wiredBytes: 2, compressedBytes: 1, cachedBytes: 3)
        let memory = MemoryStatus(physicalBytes: 16, usedBytes: 7, swapUsedBytes: nil, swapTotalBytes: nil,
                                  pressure: .normal, processCount: 0, components: components)
        let frame = accumulator.ingest(TaskManagerReadings(memory: .success(memory)), elapsed: nil)
        #expect(MemoryComponents.Kind.allCases.map { frame.history.points(for: .memory($0), in: .oneMinute) }
            == [[4], [2], [1], [3]])
    }

    @Test func driveOperationsAndActiveTimeAreRates() {
        var accumulator = accumulator()
        func reading(operations: UInt64, busy: UInt64) -> TaskManagerReadings {
            TaskManagerReadings(disks: .success([DriveCounters(id: "disk0", name: "SSD", bytesRead: 0, bytesWritten: 0,
                                                               operations: operations, busyNanoseconds: busy)]))
        }
        _ = accumulator.ingest(reading(operations: 10, busy: 0), elapsed: nil)
        let frame = accumulator.ingest(reading(operations: 50, busy: 500_000_000), elapsed: .seconds(2))
        #expect(frame.snapshot.drives.first?.operationsPerSecond == 20)
        #expect(frame.snapshot.drives.first?.activeShare == 0.25)
        let busy = accumulator.ingest(reading(operations: 50, busy: 4_000_000_000), elapsed: .seconds(1))
        #expect(busy.snapshot.drives.first?.activeShare == 1)
    }

    @Test func driveWithoutOperationCountersHasNoOperationRate() {
        var accumulator = accumulator()
        _ = accumulator.ingest(TaskManagerReadings(disks: .success(drive(read: 0))), elapsed: nil)
        let frame = accumulator.ingest(TaskManagerReadings(disks: .success(drive(read: 10))), elapsed: .seconds(1))
        #expect(frame.snapshot.drives.first?.operationsPerSecond == nil)
        #expect(frame.snapshot.drives.first?.activeShare == nil)
    }

    @Test func interfaceKeepsDisplayNameAndAddresses() {
        var accumulator = accumulator()
        let counters = InterfaceCounters(name: "en0", bytesReceived: 0, bytesSent: 0, displayName: "WLAN",
                                         addresses: ["192.0.2.7"], isPrimary: true)
        let frame = accumulator.ingest(TaskManagerReadings(interfaces: .success([counters])), elapsed: nil)
        #expect(frame.snapshot.interfaces.first?.displayName == "WLAN")
        #expect(frame.snapshot.interfaces.first?.addresses == ["192.0.2.7"])
        #expect(frame.snapshot.interfaces.first?.isPrimary == true)
    }
}
