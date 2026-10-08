import Testing
import Foundation
import TestSupport
@testable import ManagerKit

@Suite struct PermissionActionsTests {
    @Test func resetRunsTccutilWithShortServiceName() async throws {
        let runner = MockCommandRunner(["/usr/bin/tccutil reset Camera us.zoom.xos": CommandResult(exitCode: 0, stdout: "")])
        try await PermissionActions(runner: runner).reset(TestData.grant())
        #expect(runner.calls == ["/usr/bin/tccutil reset Camera us.zoom.xos"])
    }

    @Test func resetRefusesReadOnlyGrant() async {
        let runner = MockCommandRunner()
        let apple = TestData.grant(client: TestData.app("com.apple.Terminal", signing: SigningInfo(kind: .apple)))
        await #expect(throws: ActionError.notAllowed(.appleComponent)) { try await PermissionActions(runner: runner).reset(apple) }
        #expect(runner.calls.isEmpty)
    }

    @Test func resetRefusesUninstalledAndBundlelessClientsWithoutRunning() async {
        let runner = MockCommandRunner()
        let gone = TestData.grant(client: TestData.app("com.gone", presence: .missing))
        let pathClient = TestData.grant(client: AppIdentity(bundleID: nil, path: "/opt/tool", displayName: "tool", signing: .unknown, presence: .present))
        await #expect(throws: ActionError.notAllowed(.notInstalled)) { try await PermissionActions(runner: runner).reset(gone) }
        await #expect(throws: ActionError.notAllowed(.noBundleIdentifier)) { try await PermissionActions(runner: runner).reset(pathClient) }
        #expect(runner.calls.isEmpty)
    }

    @Test func tccutilFailureFallsBackToStdout() async {
        let runner = MockCommandRunner(["/usr/bin/tccutil reset Camera us.zoom.xos": CommandResult(exitCode: 70, stdout: "Failed to reset\n")])
        await #expect(throws: ActionError.commandFailed(
            "Kamera-Berechtigung für us.zoom.xos konnte nicht zurückgesetzt werden: tccutil reset Camera us.zoom.xos (Exit 70): Failed to reset"
        )) {
            try await PermissionActions(runner: runner).reset(TestData.grant())
        }
    }

    @Test func tccutilFailureIsReported() async {
        let runner = MockCommandRunner(["/usr/bin/tccutil reset Camera us.zoom.xos": CommandResult(exitCode: 64, stdout: "", stderr: "No such bundle identifier")])
        await #expect(throws: ActionError.commandFailed("Kamera-Berechtigung für us.zoom.xos konnte nicht zurückgesetzt werden: tccutil reset Camera us.zoom.xos (Exit 64): No such bundle identifier")) {
            try await PermissionActions(runner: runner).reset(TestData.grant())
        }
    }

    @Test func resetServiceRunsTccutilWithoutBundleIdentifier() async throws {
        let runner = MockCommandRunner(["/usr/bin/tccutil reset Accessibility": CommandResult(exitCode: 0, stdout: "")])
        try await PermissionActions(runner: runner).resetService("kTCCServiceAccessibility")
        #expect(runner.calls == ["/usr/bin/tccutil reset Accessibility"])
    }

    /// `tccutil reset All` setzt sämtliche Dienste zurück – nie aus einem Dienstnamen ableitbar.
    @Test(arguments: ["kTCCServiceAll", "All", "kTCCService", ""])
    func resetServiceRefusesAnythingButASingleService(service: String) async {
        let runner = MockCommandRunner()
        await #expect(throws: ActionError.notAllowed(.noSingleService)) {
            try await PermissionActions(runner: runner).resetService(service)
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func serviceNameMapping() {
        #expect(PermissionActions.tccutilServiceName("kTCCServiceSystemPolicyAllFiles") == "SystemPolicyAllFiles")
        #expect(PermissionActions.tccutilServiceName("Camera") == "Camera")
    }

    @Test func settingsURLComesFromCatalog() {
        #expect(PermissionActions(runner: MockCommandRunner()).settingsURL(for: TestData.grant()) == PermissionCatalog.service(for: "kTCCServiceCamera").settingsURL)
    }
}
