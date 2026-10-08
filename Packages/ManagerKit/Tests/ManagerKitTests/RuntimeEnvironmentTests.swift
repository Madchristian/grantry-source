import Testing
import ManagerKit

@Suite struct RuntimeEnvironmentTests {
    @Test func xcodePreviewsStartOnlyThePreviewHost() {
        let environment = RuntimeEnvironment(variables: [RuntimeEnvironment.previewVariable: "1"])
        #expect(environment.isRunningForPreviews)
        #expect(environment.launchMode == .previewHost)
    }

    @Test func regularLaunchStartsTheApplication() {
        let environment = RuntimeEnvironment(variables: ["PATH": "/usr/bin"])
        #expect(!environment.isRunningForPreviews)
        #expect(environment.launchMode == .application)
    }

    /// Nur der Wert, den Xcode setzt, schaltet um; andere Werte starten die App wie gewohnt.
    @Test(arguments: ["0", "", "YES", "true"])
    func otherValuesStartTheApplication(value: String) {
        let environment = RuntimeEnvironment(variables: [RuntimeEnvironment.previewVariable: value])
        #expect(!environment.isRunningForPreviews)
        #expect(environment.launchMode == .application)
    }
}
