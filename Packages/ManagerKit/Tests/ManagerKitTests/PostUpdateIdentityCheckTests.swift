import Foundation
import Testing
@testable import ManagerKit

@MainActor
@Suite struct PostUpdateIdentityCheckTests {
    @Test func failedCheckRetainsMarkerAcrossLaunches() async {
        let preferences = UpdatePreferences(store: InMemorySettingsStore())
        preferences.pendingIdentityVerificationBuild = 281
        for _ in 0..<2 {
            let check = PostUpdateIdentityCheck(preferences: preferences, build: 281,
                isRelease: true, validate: { _ in false })
            #expect(await check.verify() != nil)
            #expect(preferences.pendingIdentityVerificationBuild == 281)
        }
    }

    @Test func matchingReleaseIdentityClearsMarker() async {
        let preferences = UpdatePreferences(store: InMemorySettingsStore())
        preferences.pendingIdentityVerificationBuild = 281
        let check = PostUpdateIdentityCheck(preferences: preferences, build: 281,
            isRelease: true, validate: { _ in true })
        #expect(await check.verify() == nil)
        #expect(preferences.pendingIdentityVerificationBuild == nil)
    }

    @Test func developerAndUnchangedBuildsNeverValidateOrWarn() async {
        let preferences = UpdatePreferences(store: InMemorySettingsStore())
        for (release, pending) in [(false, 281), (true, 282), (true, 0)] {
            preferences.pendingIdentityVerificationBuild = pending == 0 ? nil : pending
            let check = PostUpdateIdentityCheck(preferences: preferences, build: 281,
                isRelease: release, validate: { _ in
                    Issue.record("Entwicklerbuild oder noch nicht installiertes Update geprüft")
                    return false
                })
            #expect(await check.verify() == nil)
        }
    }

    @Test func appleSystemBinaryDoesNotMeetGrantryReleaseRequirement() {
        #expect(!PostUpdateIdentityCheck.hasReleaseIdentity(at: URL(fileURLWithPath: "/usr/bin/true")))
    }

    @Test func missingApplicationFailsClosed() {
        #expect(!PostUpdateIdentityCheck.hasReleaseIdentity(at: URL(fileURLWithPath: "/nonexistent/Grantry.app")))
    }
}
