import Foundation
import Testing
@testable import ManagerKit

/// Sensoren über den Helper (TM-9.4).
@MainActor
@Suite struct SensorModelTests {
    private final class Source: PrivilegedSensorReading {
        let result: Result<SensorReading, HelperClientError>
        init(_ result: Result<SensorReading, HelperClientError>) { self.result = result }
        func sensorReading() async throws -> SensorReading { try result.get() }
    }

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 10)
    }

    private static let reading = SensorReading(cpuMilliwatts: 2000, gpuMilliwatts: 450, combinedMilliwatts: 2460,
                                               clusters: [.init(name: "E-Cluster", frequencyMHz: 1260, activeShare: 0.3),
                                                          .init(name: "P0-Cluster", frequencyMHz: 3504, activeShare: 0.6)],
                                               gpuFrequencyMHz: 980)

    @Test func appliesReadingAndRecordsWatts() {
        let model = SensorModel(source: nil, now: { Date(timeIntervalSince1970: 10) })
        model.apply(.success(Self.reading))
        #expect(model.reading == Self.reading)
        #expect(model.history.points(for: .power, in: .oneMinute).compactMap { $0 }.last == 2.46)
        #expect(model.measuredAt == Date(timeIntervalSince1970: 10))
        model.apply(.failure(HelperClientError.outdated))
        #expect(model.reading == nil)
        model.stop()
        #expect(model.history.points(for: .power, in: .oneMinute).compactMap { $0 }.isEmpty)
    }

    /// Neu für den Task-Manager (`FrameLatch`, #481) ist nur eine neue Messung oder ihr Ende, nicht derselbe Stand.
    @Test func snapshotIsNewOnlyWithANewReadingOrItsEnd() {
        let clock = Clock()
        let model = SensorModel(source: nil, now: { clock.now })
        let empty = model.snapshot
        model.apply(.success(Self.reading))
        let first = model.snapshot
        #expect(first.isNew(comparedTo: empty))
        #expect(!model.snapshot.isNew(comparedTo: first))
        clock.now += 2
        model.apply(.success(Self.reading))
        #expect(model.snapshot.isNew(comparedTo: first))
        let second = model.snapshot
        model.stop()
        #expect(model.snapshot.isNew(comparedTo: second))
        #expect(model.snapshot.reading == nil)
    }

    /// Der Chip-Tab zeichnet die Leistung der Neural Engine über die Zeit.
    @Test func recordsNeuralEnginePower() {
        let model = SensorModel(source: nil)
        model.apply(.success(SensorReading(aneMilliwatts: 820, combinedMilliwatts: 3000)))
        #expect(model.history.points(for: .neuralEnginePower, in: .oneMinute).compactMap { $0 }.last == 0.82)
        model.apply(.success(SensorReading(combinedMilliwatts: 3000)))
        #expect(model.history.points(for: .neuralEnginePower, in: .oneMinute).last == .some(nil))
    }

    /// Darstellung „Je Block“ im Leistung-Tab (TM-14.5): CPU und GPU ebenfalls in Watt.
    @Test func recordsBlockPower() {
        let model = SensorModel(source: nil)
        model.apply(.success(Self.reading))
        #expect(model.history.points(for: .cpuPower, in: .oneMinute).compactMap { $0 }.last == 2)
        #expect(model.history.points(for: .gpuPower, in: .oneMinute).compactMap { $0 }.last == 0.45)
    }

    @Test func emptyReadingShowsNothing() {
        let model = SensorModel(source: nil)
        model.apply(.success(SensorReading()))
        #expect(model.reading == nil)
    }

    @Test func pollsOnlyBetweenStartAndStop() async throws {
        let model = SensorModel(source: Source(.success(Self.reading)), sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        #expect(!model.isRunning)
        model.start()
        #expect(model.isRunning)
        for _ in 0..<200 where model.reading == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.reading == Self.reading)
        model.stop()
        #expect(!model.isRunning && model.reading == nil)
    }

    @Test func withoutHelperNeverStarts() {
        let model = SensorModel(source: nil)
        model.start()
        #expect(!model.isRunning)
    }

    // MARK: - Kachel und Kennzahlen

    @Test func powerTileAppearsOnlyWithCombinedPower() throws {
        let snapshot = TaskManagerSnapshot()
        #expect(PerformancePresentation.tiles(for: snapshot, configured: [], sensors: nil).isEmpty)
        #expect(PerformancePresentation.tiles(for: snapshot, configured: [], sensors: SensorReading(cpuMilliwatts: nil)).isEmpty)
        let tile = try #require(PerformancePresentation.tiles(for: snapshot, configured: [], sensors: Self.reading).last)
        #expect(tile == PerformanceTile(metric: .power, title: "Leistungsaufnahme", value: "2,46 W",
                                        detail: "CPU 2,00 W · GPU 0,45 W"))
    }

    @Test func powerStatsShowFrequenciesAndThermalState() {
        let stats = PerformancePresentation.stats(for: .power, in: TaskManagerSnapshot(), uptime: 0, sensors: Self.reading,
                                                  thermalState: .serious)
        #expect(stats.map(\.title) == ["Gesamt", "CPU", "GPU", "Neural Engine", "CPU-Takt", "GPU-Takt",
                                       "Thermischer Zustand"])
        #expect(stats.map(\.value) == ["2,46 W", "2,00 W", "0,45 W", "–", "E 1,3 GHz · P0 3,5 GHz", "980 MHz",
                                       "Hoch – Leistung gedrosselt"])
        #expect(PerformancePresentation.stats(for: .power, in: TaskManagerSnapshot(), uptime: 0).map(\.value).prefix(6)
            .allSatisfy { $0 == "–" })
    }

    @Test func wattsUseGermanDecimals() {
        #expect(PerformancePresentation.watts(12_345) == "12,3 W")
        #expect(PerformancePresentation.watts(0) == "0,00 W")
    }

    /// Jede Antwort geht an die Regel „Drosselung“ weiter; ohne Messung als Lücke (`nil`).
    @Test func forwardsEachAnswer() {
        let model = SensorModel(source: nil)
        var forwarded: [SensorReading?] = []
        model.onReading = { forwarded.append($0) }
        model.apply(.success(Self.reading))
        model.apply(.success(SensorReading()))
        model.apply(.failure(HelperClientError.outdated))
        #expect(forwarded == [Self.reading, nil, nil])
    }
}

