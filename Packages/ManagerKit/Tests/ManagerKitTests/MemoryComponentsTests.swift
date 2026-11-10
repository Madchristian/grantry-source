import Darwin
import Testing
@testable import ManagerKit

@Suite struct MemoryComponentsTests {
    @Test func splitsPagesLikeActivityMonitor() {
        var stats = vm_statistics64()
        stats.internal_page_count = 100
        stats.purgeable_count = 10
        stats.wire_count = 20
        stats.compressor_page_count = 5
        stats.external_page_count = 30
        let components = MemoryComponents(statistics: stats, pageSize: 4)
        #expect(components == MemoryComponents(appBytes: 360, wiredBytes: 80, compressedBytes: 20, cachedBytes: 160))
        #expect(components.usedBytes == 460)
    }

    @Test func purgeableAboveInternalDoesNotUnderflow() {
        var stats = vm_statistics64()
        stats.internal_page_count = 5
        stats.purgeable_count = 10
        #expect(MemoryComponents(statistics: stats, pageSize: 1).appBytes == 0)
    }

    @Test func subscriptReturnsEachKind() {
        let components = MemoryComponents(appBytes: 1, wiredBytes: 2, compressedBytes: 3, cachedBytes: 4)
        #expect(MemoryComponents.Kind.allCases.map { components[$0] } == [1, 2, 3, 4])
    }

    @Test func existingCallersKeepWorkingWithoutComponents() {
        let status = MemoryStatus(physicalBytes: 16, usedBytes: 8, swapUsedBytes: nil, swapTotalBytes: nil,
                                  pressure: .normal, processCount: 1)
        #expect(status.components == nil)
    }

    @Test func currentStatusDerivesUsedBytesFromComponents() throws {
        let status = MemoryStatus.current(processCount: 1)
        let components = try #require(status.components)
        #expect(status.usedBytes == components.usedBytes)
    }
}
