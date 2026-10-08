import Foundation
import Testing
@testable import ManagerKit

@Suite struct UpdateFeedTests {
    @Test(arguments: [
        ("https://grantry.cstrube.de/download/Grantry-1.dmg", true),
        ("http://grantry.cstrube.de/download/Grantry-1.dmg", false),
        ("https://evil.example/download/Grantry-1.dmg", false),
        ("https://grantry.cstrube.de.evil.example/x.dmg", false),
        ("https://grantry.cstrube.de:8443/x.dmg", false),
        ("https://evil@grantry.cstrube.de/x.dmg", false),
    ])
    func allowsOnlyHTTPSOnTheGrantryHost(url: String, allowed: Bool) {
        #expect(UpdateFeed.isAllowed(URL(string: url)!) == allowed)
    }
}
