import Testing
@testable import ManagerKit

@Suite struct LoadAverageTests {
    @Test func readsThreeAveragesOfThisMac() throws {
        let average = try #require(LoadAverage.current())
        #expect([average.one, average.five, average.fifteen].allSatisfy { $0 >= 0 && $0.isFinite })
    }
}
