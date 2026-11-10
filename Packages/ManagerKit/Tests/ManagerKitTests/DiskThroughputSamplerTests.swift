import Testing
@testable import ManagerKit

@Suite struct DiskThroughputSamplerTests {
    private let statistics: [String: Any] = [
        "Bytes (Read)": 1_000, "Bytes (Write)": 500, "Operations (Read)": 10, "Operations (Write)": 20,
        "Total Time (Read)": 300, "Total Time (Write)": 700,
    ]
    private let ssd: [String: Any] = ["Product Name": "APPLE SSD AP1024Z", "Medium Type": "Solid State"]
    private let internalBus: [String: Any] = ["Physical Interconnect Location": "Internal"]

    @Test func countersFromDriverStatistics() {
        let drive = DiskThroughputSampler.counters(statistics: statistics, bsdName: "disk0", device: ssd,
                                                   interconnect: internalBus)
        #expect(drive == DriveCounters(id: "disk0", name: "APPLE SSD AP1024Z", bytesRead: 1_000, bytesWritten: 500,
                                       operations: 30, busyNanoseconds: 1_000))
    }

    @Test func diskImagesAreSkipped() {
        let file: [String: Any] = ["Physical Interconnect": "Virtual Interface", "Physical Interconnect Location": "File"]
        let inKernel: [String: Any] = ["Physical Interconnect": "Virtual Interface"]
        for interconnect in [file, inKernel] {
            #expect(DiskThroughputSampler.counters(statistics: statistics, bsdName: "disk4", device: nil,
                                                   interconnect: interconnect) == nil)
        }
    }

    @Test func driverWithoutMediaOrStatisticsIsSkipped() {
        #expect(DiskThroughputSampler.counters(statistics: statistics, bsdName: nil, device: ssd,
                                               interconnect: internalBus) == nil)
        #expect(DiskThroughputSampler.counters(statistics: nil, bsdName: "disk0", device: ssd,
                                               interconnect: internalBus) == nil)
    }

    @Test func missingOperationCountersStayUnknown() {
        let bytesOnly: [String: Any] = ["Bytes (Read)": 1, "Bytes (Write)": 2]
        let drive = DiskThroughputSampler.counters(statistics: bytesOnly, bsdName: "disk2", device: nil,
                                                   interconnect: nil)
        #expect(drive?.operations == nil)
        #expect(drive?.busyNanoseconds == nil)
    }

    @Test func nameFallsBackToBSDName() {
        let blank: [String: Any] = ["Product Name": "  "]
        #expect(DiskThroughputSampler.counters(statistics: statistics, bsdName: "disk2", device: blank,
                                               interconnect: nil)?.name == "disk2")
    }

    @Test func readsDrivesOfThisMac() throws {
        let drives = try DiskThroughputSampler().read()
        #expect(!drives.isEmpty)
        #expect(drives.allSatisfy { $0.id.hasPrefix("disk") })
        #expect(Set(drives.map(\.id)).count == drives.count)
        #expect(!drives.contains { $0.name == "Disk Image" })
    }

    /// Name, BSD-Name und Art eines Laufwerks ändern sich nicht je Takt (#489): Der Cache liest sie je Treiber einmal,
    /// einen Treiber ohne Medium bei jedem Takt neu und vergisst verschwundene Treiber.
    @Test func identityIsReadOncePerDriverAndForgottenWhenItVanishes() {
        let cache = DriveIdentityCache()
        var reads = 0
        let disk = DriveIdentity(bsdName: "disk0", name: "APPLE SSD", isDiskImage: false)
        let noMedia = DriveIdentity(bsdName: nil, name: "", isDiskImage: false)
        for _ in 0..<3 {
            #expect(cache.identity(for: 1) { reads += 1; return disk } == disk)
            #expect(cache.identity(for: 2) { reads += 1; return noMedia } == noMedia)
            cache.keep(only: [1, 2])
        }
        #expect(reads == 1 + 3)
        cache.keep(only: [2])
        _ = cache.identity(for: 1) { reads += 1; return disk }
        #expect(reads == 1 + 3 + 1)
    }

    @Test func countersFromCachedIdentity() {
        let identity = DiskThroughputSampler.identity(bsdName: "disk0", device: ssd, interconnect: internalBus)
        #expect(identity == DriveIdentity(bsdName: "disk0", name: "APPLE SSD AP1024Z", isDiskImage: false))
        #expect(DiskThroughputSampler.counters(statistics: statistics, identity: identity)
            == DiskThroughputSampler.counters(statistics: statistics, bsdName: "disk0", device: ssd,
                                              interconnect: internalBus))
    }
}
