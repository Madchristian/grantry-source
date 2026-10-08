import Foundation
import Testing
@testable import ManagerKit

@Suite struct DeveloperNameTests {
    @Test(arguments: [
        ("Developer ID Application: Google LLC (EQHXZ8M8AV)", "EQHXZ8M8AV", "Google LLC"),
        ("Apple Development: Christian Strube (ABCDE12345)", "ABCDE12345", "Christian Strube"),
        ("Developer ID Application: Foo (Bar) GmbH (TEAM123456)", "TEAM123456", "Foo (Bar) GmbH"),
        ("Ohne Doppelpunkt", "TEAM123456", "Ohne Doppelpunkt"),
        // Die Klammer gehört zum Namen, wenn sie nicht die Team-ID enthält (Review M4).
        ("Developer ID Application: Foo (Bar)", "TEAM123456", "Foo (Bar)"),
        ("Developer ID Application: Foo (Bar)", nil, "Foo (Bar)"),
    ] as [(String, String?, String)])
    func parsesTheCertificateSummary(summary: String, teamID: String?, expected: String) {
        #expect(SigningInfo.developerName(fromCertificateSummary: summary, teamID: teamID) == expected)
    }

    @Test func emptySummaryHasNoName() {
        #expect(SigningInfo.developerName(fromCertificateSummary: "  ", teamID: nil) == nil)
    }

    @Test func olderSigningInfoDecodesWithoutDeveloperName() throws {
        let json = Data(#"{"kind":"developerID","teamID":"TEAMA12345","isNotarized":true}"#.utf8)
        let decoded = try JSONDecoder().decode(SigningInfo.self, from: json)
        #expect(decoded == SigningInfo(kind: .developerID, teamID: "TEAMA12345", isNotarized: true))
    }

    @Test func developerNameRoundTrips() throws {
        let signing = SigningInfo(kind: .developerID, teamID: "EQHXZ8M8AV", isNotarized: true, developerName: "Google LLC")
        #expect(try JSONDecoder().decode(SigningInfo.self, from: JSONEncoder().encode(signing)) == signing)
    }
}
