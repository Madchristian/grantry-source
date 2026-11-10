import Foundation
import Testing
@testable import ManagerKit

/// Taktverteilung je Cluster über die letzten 60 s vor der jüngsten Messung (TM-14.3): gewichtet mit der aktiven Zeit
/// je Messung.
@Suite struct ClockDistributionHistoryTests {
    static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func reading(_ name: String, active: Double?, steps: [(Double, Double)]) -> SensorReading {
        SensorReading(clusters: [SensorReading.Cluster(
            name: name, frequencyMHz: nil, activeShare: active,
            frequencySteps: steps.map { SensorReading.FrequencyStep(frequencyMHz: $0.0, share: $0.1) })])
    }

    @Test func weightsEachReadingByItsActiveTime() {
        var history = ClockDistributionHistory()
        history.record(Self.reading("P0-Cluster", active: 0.9, steps: [(1000, 0), (4000, 1)]), at: Self.start)
        history.record(Self.reading("P0-Cluster", active: 0.1, steps: [(1000, 1), (4000, 0)]),
                       at: Self.start.addingTimeInterval(2))
        let steps = history.steps(ofCluster: "P0-Cluster")
        #expect(steps.map(\.frequencyMHz) == [1000, 4000])
        #expect(abs(steps[0].share - 0.1) < 1e-9)
        #expect(abs(steps[1].share - 0.9) < 1e-9)
    }

    @Test func forgetsReadingsOlderThanTheSpan() {
        var history = ClockDistributionHistory()
        history.record(Self.reading("E-Cluster", active: 1, steps: [(1000, 1), (2000, 0)]), at: Self.start)
        history.record(Self.reading("E-Cluster", active: 1, steps: [(1000, 0), (2000, 1)]),
                       at: Self.start.addingTimeInterval(61))
        #expect(history.steps(ofCluster: "E-Cluster").map(\.share) == [0, 1])
        #expect(history.count == 1)
    }

    /// Ohne aktive Zeit oder ohne Angabe zählt jede Messung gleich, statt die Verteilung zu verlieren.
    @Test func equalWeightsWithoutActiveTime() {
        var history = ClockDistributionHistory()
        history.record(Self.reading("P1-Cluster", active: nil, steps: [(1000, 1), (4000, 0)]), at: Self.start)
        history.record(Self.reading("P1-Cluster", active: nil, steps: [(1000, 0), (4000, 1)]),
                       at: Self.start.addingTimeInterval(2))
        #expect(history.steps(ofCluster: "P1-Cluster").map(\.share) == [0.5, 0.5])
    }

    @Test func unknownClusterOrNoStepsIsEmpty() {
        var history = ClockDistributionHistory()
        history.record(Self.reading("P0-Cluster", active: 0.5, steps: []), at: Self.start)
        #expect(history.steps(ofCluster: "P0-Cluster").isEmpty)
        #expect(history.steps(ofCluster: "P9-Cluster").isEmpty)
    }

    /// Auch bei vielen Messungen in kurzer Zeit bleibt der Puffer begrenzt.
    @Test func boundedEntries() {
        var history = ClockDistributionHistory()
        for index in 0..<500 {
            history.record(Self.reading("E-Cluster", active: 1, steps: [(1000, 1)]),
                           at: Self.start.addingTimeInterval(Double(index) * 0.01))
        }
        #expect(history.count <= ClockDistributionHistory.maximumEntries)
    }

    @MainActor
    @Test func sensorModelCollectsAndForgets() {
        let model = SensorModel(source: nil, now: { Self.start })
        model.apply(.success(SensorReading(cpuMilliwatts: 1000, clusters: [SensorReading.Cluster(
            name: "E-Cluster", frequencyMHz: 1000, activeShare: 1,
            frequencySteps: [SensorReading.FrequencyStep(frequencyMHz: 1000, share: 1)])])))
        #expect(model.clockHistory.count == 1)
        model.stop()
        #expect(model.clockHistory.count == 0)
    }
}
