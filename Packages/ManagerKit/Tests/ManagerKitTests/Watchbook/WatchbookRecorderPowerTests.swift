import Foundation
import GrantryShared
import Testing
import TestSupport
@testable import ManagerKit

/// Leistungsaufnahme im Recorder (TM-14.5): nur, wenn die Sensoren des Helpers ohnehin messen, je Punkt das Mittel seines
/// Abschnitts; ausgeschaltet oder ohne Sensoren bleibt sie leer.
@Suite(.timeLimit(.minutes(1))) struct WatchbookRecorderPowerTests {
    private typealias Setup = WatchbookRecorderTests.Setup

    private func withSetup(_ body: (Setup) async throws -> Void) async throws {
        try await ScratchDirectory.withCanonical(prefix: "watchbook-power") { directory in
            let setup = Setup(directory: directory)
            try await body(setup)
            await setup.recorder.shutdown()
        }
    }

    private func reading(_ combined: Double, cpu: Double) -> SensorReading {
        SensorReading(cpuMilliwatts: cpu, gpuMilliwatts: 500, aneMilliwatts: 20, combinedMilliwatts: combined)
    }

    @Test func pointsCarryTheMeanOfTheirSection() async throws {
        try await withSetup { setup in
            await setup.recorder.setEnabled(true)
            await setup.tick(1, from: 10)
            setup.clock.advance(by: .seconds(2))
            setup.recorder.sensorsDidMeasure(reading(4_000, cpu: 3_000))
            setup.clock.advance(by: .seconds(2))
            setup.recorder.sensorsDidMeasure(reading(6_000, cpu: 5_000))
            await setup.tick(2, from: 20)
            let points = await setup.records().points
            #expect(points.map { $0.values[.power] } == [nil, 5, nil])
            #expect(points.map { $0.values[.cpuPower] } == [nil, 4, nil])
            #expect(points[1].values[.gpuPower] == 0.5)
            #expect(points[1].values[.neuralEnginePower] == 0.02)
        }
    }

    /// Ausgeschaltet nimmt der Recorder keine Messung an; auch keine, die erst nach dem Einschalten zählt.
    @Test func ignoresReadingsWhileOff() async throws {
        try await withSetup { setup in
            setup.recorder.sensorsDidMeasure(reading(4_000, cpu: 3_000))
            await setup.recorder.setEnabled(true)
            await setup.tick(1, from: 10)
            #expect(await setup.records().points.map { $0.values[.power] } == [nil])
        }
    }
}
