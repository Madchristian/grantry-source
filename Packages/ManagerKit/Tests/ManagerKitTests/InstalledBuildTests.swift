import Testing
@testable import ManagerKit

@Suite struct InstalledBuildTests {
    @Test func readsTheInstalledBuildFromInfo() {
        let installed = InstalledBuild(
            info: ["CFBundleShortVersionString": "2026.10.4", "CFBundleVersion": "276"],
            systemVersion: SystemVersion(major: 27), architecture: "arm64"
        )
        #expect(installed.version == "2026.10.4")
        #expect(installed.build == 276)
        #expect(installed.userAgent == "Grantry/2026.10.4 (276; macOS 27.0; arm64)")
    }

    @Test func missingInfoFallsBackToZero() {
        let installed = InstalledBuild(info: [:], systemVersion: SystemVersion(major: 27), architecture: "arm64")
        #expect(installed.version == "?")
        #expect(installed.build == 0)
    }
}
