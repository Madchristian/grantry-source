import Testing
@testable import ManagerKit

@Suite struct MemorySourceTests {
    @Test func readsComponentsOfThisMac() throws {
        let status = try MemorySource().read()
        let components = try #require(status.components)
        #expect(status.usedBytes == components.usedBytes)
        #expect(components.usedBytes > 0)
        #expect(components.usedBytes <= status.physicalBytes)
    }

    @Test func countsProcessesWithoutReadingThem() {
        #expect(MemorySource.processCount() > 1)
    }
}
