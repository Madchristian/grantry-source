import Testing
@testable import ManagerKit

@Suite struct SmokeTests {
    @Test func moduleExposesName() {
        #expect(ManagerKit.moduleName == "ManagerKit")
    }
}
