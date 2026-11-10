import Foundation
import Testing
@testable import ManagerKit

@Suite struct OverviewPresentationTests {
    private typealias P = OverviewPresentation

    private static func process(_ pid: Int32, _ name: String, cpu: Double?, memory: UInt64? = 1 << 20)
        -> ProcessMeasurement {
        ProcessMeasurement(key: ProcessKey(pid: pid, startTime: 1), parentPID: 1, uid: 501, name: name, cpuLoad: cpu,
                           memoryBytes: memory, diskReadPerSecond: nil, diskWritePerSecond: nil, threadCount: 4)
    }

    @Test func topProcessesAreSortedByCPUAndSkipUnmeasured() {
        var snapshot = TaskManagerSnapshot()
        snapshot.processes = [Self.process(10, "zsh", cpu: 0.01), Self.process(11, "Xcode", cpu: 0.2),
                              Self.process(12, "neu", cpu: nil), Self.process(13, "Safari", cpu: 0.05)]
        let top = P.topProcesses(in: snapshot, count: 2)
        #expect(top.map(\.name) == ["Xcode", "Safari"])
        #expect(top.map(\.heat) == [1, 0.25])
        #expect(top.first?.pid == "11")
    }

    @Test func idleProcessesDoNotLookHot() {
        var snapshot = TaskManagerSnapshot()
        snapshot.processes = [Self.process(10, "zsh", cpu: 0.001)]
        #expect(P.topProcesses(in: snapshot).first?.heat == 0.1)
    }

    @Test func metersShowOnlyMeasuredSources() {
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = CPULoad(total: 0.25, cores: [])
        let meters = P.meters(for: snapshot, sensors: nil, powerScale: 20)
        #expect(meters.map(\.kind) == [.cpu, .memory])
        #expect(meters.map(\.level) == [0.25, nil])
        #expect(meters.last?.value == "–")
    }

    @Test func powerMeterUsesTheGraphScale() {
        let sensors = SensorReading(combinedMilliwatts: 5_000)
        var snapshot = TaskManagerSnapshot()
        snapshot.gpu = GPULoadReading(utilization: 0.4, usedMemoryBytes: nil)
        let meters = P.meters(for: snapshot, sensors: sensors, powerScale: 20)
        #expect(meters.map(\.kind) == [.cpu, .power, .gpu, .memory])
        #expect(meters[1].level == 0.25)
        #expect(meters[1].value == "5,00 W")
    }

    @Test func averageAlignsAtTheNewestValueAndKeepsGaps() throws {
        let spacing = Duration.seconds(1)
        let average = try #require(P.average([
            HistoryPoints(values: [0.2, nil, 0.4], spacing: spacing, latestOffset: .zero),
            HistoryPoints(values: [nil, 0.6], spacing: spacing, latestOffset: .zero),
        ]))
        #expect(average.values == [0.2, nil, 0.5])
        #expect(P.average([]) == nil)
        let gap = try #require(P.average([HistoryPoints(values: [nil, 1], spacing: spacing, latestOffset: .zero)]))
        #expect(gap.values == [nil, 1])
    }

    #if DEBUG
    @Test func statusNamesIntervalProcessesAndUptime() {
        let status = P.status(for: TaskManagerPreviewData.frame.snapshot, interval: "1 s",
                              uptime: TaskManagerPreviewData.uptime)
        #expect(status == ["Takt 1 s", "642 Prozesse · – Threads", "Laufzeit 3:04:17:22"])
    }
    #endif

    /// Summe je Stelle über alle Reihen (CPU-Last je Benutzer); Stellen ohne jeden Wert bleiben Lücke.
    @Test func sumAddsAlignedSeries() {
        let first = HistoryPoints(values: [0.1, nil, 0.3], spacing: .seconds(1), latestOffset: .zero)
        let second = HistoryPoints(values: [nil, 0.2], spacing: .seconds(1), latestOffset: .zero)
        let empty = HistoryPoints(values: [nil, nil, nil], spacing: .seconds(1), latestOffset: .zero)
        let sum = OverviewPresentation.sum([first, second])?.values ?? []
        #expect(sum.count == 3)
        #expect(sum[0] == 0.1)
        #expect(sum[1] == nil)
        #expect(abs((sum[2] ?? 0) - 0.5) < 1e-9)
        #expect(OverviewPresentation.sum([empty])?.values == [nil, nil, nil])
        #expect(OverviewPresentation.sum([]) == nil)
    }
}
