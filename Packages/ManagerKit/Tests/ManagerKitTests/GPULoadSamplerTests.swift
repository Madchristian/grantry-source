import Testing
@testable import ManagerKit

@Suite struct GPULoadSamplerTests {
    @Test func readingFromPerformanceStatistics() {
        let reading = GPULoadSampler.reading(from: ["Device Utilization %": 37, "In use system memory": 1_382_891_520])
        #expect(reading == GPULoadReading(utilization: 0.37, usedMemoryBytes: 1_382_891_520))
    }

    @Test func missingValuesStayUnknown() {
        #expect(GPULoadSampler.reading(from: nil) == GPULoadReading(utilization: nil, usedMemoryBytes: nil))
        #expect(GPULoadSampler.reading(from: ["Renderer Utilization %": 5]).utilization == nil)
    }

    @Test func utilizationIsCappedAtFullLoad() {
        #expect(GPULoadSampler.reading(from: ["Device Utilization %": 140]).utilization == 1)
    }

    @Test func busiestGPUWinsAndUnknownFallsBack() {
        let idle = GPULoadReading(utilization: 0.1, usedMemoryBytes: 1)
        let busy = GPULoadReading(utilization: 0.8, usedMemoryBytes: 2)
        let unknown = GPULoadReading(utilization: nil, usedMemoryBytes: 3)
        #expect(GPULoadSampler.busiest([idle, unknown, busy]) == busy)
        #expect(GPULoadSampler.busiest([unknown]) == unknown)
        #expect(GPULoadSampler.busiest([]) == nil)
    }

    // MARK: Faule Erkennung (kein IOKit-Aufruf beim Erzeugen, Entscheidung beim ersten Messtakt)

    private static let measured = GPULoadReading(utilization: 0.4, usedMemoryBytes: 7)
    private static let none = GPULoadReading(utilization: nil, usedMemoryBytes: nil)

    private func sampler(_ source: ScriptedMetricSource<GPULoadReading>) -> GPULoadSampler {
        GPULoadSampler(reader: { try source.read() })
    }

    @Test func creatingTheSamplerReadsNothing() {
        let source = ScriptedMetricSource(readings: [Self.measured])
        _ = sampler(source)
        #expect(source.callCount == 0)
    }

    @Test func systemSourcesAlwaysRegisterTheGPUWithoutReadingIt() {
        // Die Quelle steht fest im Satz der App; ob die GPU eine Auslastung liefert, zeigt erst der Messtakt.
        #expect(TaskManagerSources.system.configured.contains(.gpu))
    }

    @Test func readableGPUYieldsAValueAtTheFirstTick() throws {
        let source = ScriptedMetricSource(readings: [Self.measured])
        let sampler = sampler(source)
        #expect(try sampler.read() == Self.measured)
        #expect(source.callCount == 1)
    }

    @Test func availableGPUKeepsReadingAndReportsLaterFailures() throws {
        let later = GPULoadReading(utilization: 0.9, usedMemoryBytes: 8)
        let source = ScriptedMetricSource(results: [.success(Self.measured), .success(later),
                                                    .failure(SourceFailure(message: "IOKit"))])
        let sampler = sampler(source)
        #expect(try sampler.read() == Self.measured)
        #expect(try sampler.read() == later)
        #expect(throws: SourceFailure.self) { try sampler.read() }
        #expect(source.callCount == 3)
    }

    @Test func unreadableGPUStaysSilentForever() throws {
        let source = ScriptedMetricSource(results: [.success(GPULoadReading(utilization: nil, usedMemoryBytes: 5)),
                                                    .success(Self.measured)])
        let sampler = sampler(source)
        for _ in 0..<5 {
            #expect(try sampler.read() == Self.none)
        }
        // Nach der ersten Lesung wird die GPU nicht mehr abgefragt – auch dann nicht, wenn sie später etwas lieferte.
        #expect(source.callCount == 1)
    }

    @Test func failingFirstReadStaysSilentWithoutFurtherAccess() throws {
        let source = ScriptedMetricSource<GPULoadReading>(results: [.failure(SourceFailure(message: "IOKit"))])
        let sampler = sampler(source)
        for _ in 0..<5 {
            #expect(try sampler.read() == Self.none)
        }
        #expect(source.callCount == 1)
    }

    @Test func unreadableGPUNeverFailsTheTick() async {
        let source = ScriptedMetricSource<GPULoadReading>(results: [.failure(SourceFailure(message: "IOKit"))])
        let sources = TaskManagerSources(gpu: sampler(source))
        for _ in 0..<3 {
            let readings = await TaskManagerReadings.read(sources)
            #expect(readings.failures.isEmpty)
            #expect(readings.gpu.flatMap { try? $0.get() } == Self.none)
        }
    }

    @Test(.enabled(if: (try? GPULoadSampler.readAccelerators())?.utilization != nil))
    func readsUtilizationOfThisMac() throws {
        let utilization = try #require(try GPULoadSampler().read().utilization)
        #expect((0...1).contains(utilization))
    }
}
