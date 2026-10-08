import Testing
@testable import ManagerKit

@Suite struct SystemVersionTests {
    @Test func parsesDottedSystemVersions() {
        #expect(SystemVersion(dotted: "27.0") == SystemVersion(major: 27))
        #expect(SystemVersion(dotted: "27.1.2") == SystemVersion(major: 27, minor: 1, patch: 2))
        #expect(SystemVersion(dotted: "27") == SystemVersion(major: 27))
    }

    @Test(arguments: ["27.x", "", "27.", ".1", "1.2.3.4", "-1.0", "siebenundzwanzig"])
    func rejectsMalformedSystemVersions(text: String) {
        #expect(SystemVersion(dotted: text) == nil)
    }

    @Test func comparesNumerically() {
        #expect(SystemVersion(major: 27, minor: 1) > SystemVersion(major: 27))
        #expect(SystemVersion(major: 27, minor: 10) > SystemVersion(major: 27, minor: 9))
        #expect(SystemVersion(major: 28) > SystemVersion(major: 27, minor: 9, patch: 9))
    }

    @Test func descriptionShowsThePatchOnlyWhenItIsNotZero() {
        #expect(SystemVersion(major: 27, minor: 1, patch: 2).description == "27.1.2")
        #expect(SystemVersion(major: 27).description == "27.0")
    }
}
