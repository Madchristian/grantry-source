import Testing
@testable import ManagerKit

@Suite struct BatteryAccumulatorTests {
    private static let reading = BatteryReading(charge: 0.8, source: .battery, minutesToEmpty: 254, cycleCount: 86,
                                                designCycleCount: 1_000, maximumCapacity: 0.976, condition: .normal,
                                                batteryMilliwatts: -4_288, systemMilliwatts: 12_500)

    @Test func batteryFillsSnapshotAndHistory() {
        var accumulator = TaskManagerAccumulator(interval: .oneSecond, fallbackCoreCount: 4)
        let frame = accumulator.ingest(TaskManagerReadings(battery: .success(Self.reading)), elapsed: nil)
        #expect(frame.snapshot.battery == Self.reading)
        #expect(frame.history.points(for: .batteryCharge, in: .oneMinute) == [0.8])
        #expect(frame.history.points(for: .systemPower, in: .oneMinute) == [12_500])
    }

    @Test func failedBatteryIsUnavailable() {
        var accumulator = TaskManagerAccumulator(interval: .oneSecond, fallbackCoreCount: 4)
        let frame = accumulator.ingest(TaskManagerReadings(battery: .failure(SourceFailure(message: "IOKit"))),
                                       elapsed: nil)
        #expect(frame.snapshot.unavailable == [.battery])
        #expect(frame.snapshot.battery == nil)
    }

    @Test func batterySourceCountsAsConfigured() {
        let sources = TaskManagerSources(battery: ScriptedMetricSource(readings: [Self.reading]))
        #expect(sources.configured == [.battery])
    }

    @Test func readingsReadTheBatterySource() async {
        let readings = await TaskManagerReadings.read(
            TaskManagerSources(battery: ScriptedMetricSource<BatteryReading>(results: [
                .failure(SourceFailure(message: "IOKit")),
            ]))
        )
        #expect(readings.failures.map(\.0) == [.battery])
    }
}
