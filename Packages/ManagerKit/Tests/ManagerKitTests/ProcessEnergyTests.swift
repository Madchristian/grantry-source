import Darwin
import Foundation
import Testing
@testable import ManagerKit

@Suite struct ProcessEnergyTests {
    private func process(_ pid: Int32 = 10, start: UInt64 = 1, energy: UInt64?) -> ProcessCounters {
        ProcessCounters(key: ProcessKey(pid: pid, startTime: start), parentPID: 1, uid: 501, name: "p\(pid)",
                        cpuTimeNanoseconds: 0, diskBytesRead: 0, diskBytesWritten: 0, memoryBytes: 1, threadCount: 1,
                        energyNanojoules: energy)
    }

    /// Spielt die Takte durch den echten Accumulator; der erste ist die Basis.
    private func ingest(_ ticks: [[ProcessCounters]], every elapsed: Duration = .seconds(1)) -> TaskManagerFrame {
        var accumulator = TaskManagerAccumulator(interval: .oneSecond, fallbackCoreCount: 4)
        var frame = TaskManagerFrame.empty(interval: .oneSecond)
        for (index, processes) in ticks.enumerated() {
            frame = accumulator.ingest(TaskManagerReadings(processes: .success(processes)),
                                       elapsed: index == 0 ? nil : elapsed)
        }
        return frame
    }

    @Test func energyRateIsMilliwatts() {
        // 2 J in 2 s = 1 W.
        let frame = ingest([[process(energy: 0)], [process(energy: 2_000_000_000)]], every: .seconds(2))
        #expect(frame.snapshot.processes[0].energyMilliwatts == 1_000)
    }

    @Test func firstMeasurementHasNoEnergyRate() {
        #expect(ingest([[process(energy: 5)]]).snapshot.processes[0].energyMilliwatts == nil)
    }

    @Test func unreadableEnergyStaysUnknown() {
        let frame = ingest([[process(energy: nil)], [process(energy: nil)]])
        #expect(frame.snapshot.processes[0].energyMilliwatts == nil)
        #expect(frame.snapshot.processes[0].energyTrendMilliwatts == nil)
        #expect(frame.history.points(for: .energyTotal, in: .oneMinute).isEmpty)
    }

    @Test func reusedPIDStartsWithoutEnergy() {
        let frame = ingest([[process(start: 1, energy: 0)], [process(start: 2, energy: 9_000_000_000)]])
        #expect(frame.snapshot.processes[0].energyMilliwatts == nil)
    }

    @Test func totalSumsMeasuredProcesses() {
        let frame = ingest([
            [process(10, energy: 0), process(11, energy: 0), process(12, energy: nil)],
            [process(10, energy: 500_000_000), process(11, energy: 250_000_000), process(12, energy: nil)],
        ])
        #expect(frame.history.points(for: .energyTotal, in: .oneMinute) == [750])
    }

    @Test func trendStartsWithFirstRateAndFollowsSlowly() throws {
        // 1 W, danach eine Sekunde 0 W: Der Mittelwert sinkt nur um den Faktor e^(−1/120).
        let frame = ingest([[process(energy: 0)], [process(energy: 1_000_000_000)], [process(energy: 1_000_000_000)]])
        let trend = try #require(frame.snapshot.processes[0].energyTrendMilliwatts)
        #expect(abs(trend - 1_000 * exp(-1.0 / 120)) < 1e-9)
    }

    @Test func trendWithoutMeasurementKeepsPreviousValue() {
        #expect(EnergyTrend.next(500, nil, elapsed: .seconds(1)) == 500)
        #expect(EnergyTrend.next(nil, 300, elapsed: .seconds(1)) == 300)
        #expect(EnergyTrend.next(nil, nil, elapsed: nil) == nil)
    }

    @Test func frameCarriesElapsedTime() {
        #expect(ingest([[process(energy: 0)], [process(energy: 0)]], every: .seconds(2)).elapsed == .seconds(2))
        #expect(ingest([[process(energy: 0)]]).elapsed == nil)
    }

    @Test func figuresSumEnergy() {
        let figures = ProcessFigures.sum([
            ProcessFigures(cpuLoad: nil, memoryBytes: nil, diskPerSecond: nil, networkPerSecond: nil,
                           energyMilliwatts: 100, energyTrendMilliwatts: 80),
            ProcessFigures(cpuLoad: nil, memoryBytes: nil, diskPerSecond: nil, networkPerSecond: nil,
                           energyMilliwatts: 50, energyTrendMilliwatts: nil),
        ])
        #expect(figures.energyMilliwatts == 150)
        #expect(figures.energyTrendMilliwatts == 80)
    }

    @Test func samplerPassesEnergyOfOwnProcesses() throws {
        let own = KernelProcess(pid: 42, parentPID: 1, uid: 501, startTime: 7, command: "Tool")
        let sampler = ProcessUsageSampler(
            currentUID: 501, processes: { [own] },
            usage: { _ in
                ResourceUsage(cpuTimeNanoseconds: 1, diskBytesRead: 0, diskBytesWritten: 0, memoryBytes: 1,
                              threadCount: 1, energyNanojoules: 77)
            },
            executablePath: { _ in nil }
        )
        #expect(try sampler.read().first?.energyNanojoules == 77)
    }

    @Test func ownProcessReportsEnergyOnlyOnAppleSilicon() throws {
        let first = try #require(ProcessUsageSampler.usage(of: getpid(), numer: 1, denom: 1))
        var value = 0.0
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .milliseconds(200) { value += sin(value + 1) }
        let second = try #require(ProcessUsageSampler.usage(of: getpid(), numer: 1, denom: 1))
        #expect(value.isFinite)
        #if arch(arm64)
        let before = try #require(first.energyNanojoules), after = try #require(second.energyNanojoules)
        #expect(after > before)
        #else
        #expect(second.energyNanojoules == nil)
        #endif
    }

    @Test func foreignProcessHasNoCountersWithoutRoot() {
        // launchd gehört root; ohne Root liefert proc_pid_rusage EPERM – Energie bleibt „–“.
        guard getuid() != 0 else { return }
        #expect(ProcessUsageSampler.usage(of: 1, numer: 1, denom: 1) == nil)
    }
}
