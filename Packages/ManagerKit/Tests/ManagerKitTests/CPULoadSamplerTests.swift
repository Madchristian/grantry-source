import Testing
@testable import ManagerKit

@Suite struct CPULoadSamplerTests {
    @Test func busyIsUserSystemAndNice() {
        // Je Kern: Benutzer, System, Leerlauf, nice.
        let cores = CPULoadSampler.cores(ticks: [10, 5, 80, 1, 0, 0, 7, 0], kinds: [.efficiency, .performance])
        #expect(cores == [CoreTicks(kind: .efficiency, busy: 16, idle: 80, system: 5),
                          CoreTicks(kind: .performance, busy: 0, idle: 7, system: 0)])
    }

    @Test func coresBeyondKnownKindsAreUnknown() {
        let cores = CPULoadSampler.cores(ticks: [1, 1, 1, 1, 2, 2, 2, 2], kinds: [.performance])
        #expect(cores.map(\.kind) == [.performance, .unknown])
    }

    @Test func readsEveryCoreOfThisMac() throws {
        let reading = try CPULoadSampler().read()
        #expect(reading.cores.count == Sysctl.int("hw.ncpu"))
        #expect(reading.cores.allSatisfy { $0.busy + $0.idle > 0 })
        #if arch(arm64)
        #expect(!reading.cores.contains { $0.kind == .unknown })
        #endif
    }
}
