import GrantryShared
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct LaunchdServiceListTests {
    private static let output = """
    gui/501 = {
    \ttype = gui
    \tservices = {
    \t\t    1047      - \tcom.apple.syncdefaultsd
    \t\t       0      0 \tcom.apple.DataDetectorsLocalSources
    \t\t       0     78 \tcom.example.failing
    \t\t   79735     -9 \tDiscord Helper.79735
    \t\t   55271   (jt) \tcom.apple.findmy.findmylocateagent
    \t}
    }
    """

    private static let oneService = "\tservices = {\n\t\t     12      - \tcom.example.agent\n\t}\n"

    @Test func parsesPIDExitStatusAndLabel() {
        #expect(LaunchctlParsers.services(Self.output) == [
            LaunchdServiceStatus(label: "com.apple.syncdefaultsd", pid: 1047, lastExit: .never),
            LaunchdServiceStatus(label: "com.apple.DataDetectorsLocalSources", pid: nil, lastExit: .exited(0)),
            LaunchdServiceStatus(label: "com.example.failing", pid: nil, lastExit: .exited(78)),
            LaunchdServiceStatus(label: "Discord Helper.79735", pid: 79_735, lastExit: .signaled(9)),
            LaunchdServiceStatus(label: "com.apple.findmy.findmylocateagent", pid: 55_271, lastExit: .other("(jt)")),
        ])
    }

    @Test func missingBlockIsUnknownEmptyBlockIsEmpty() {
        #expect(LaunchctlParsers.services("gui/501 = {\n}\n") == nil)
        #expect(LaunchctlParsers.services("\tservices = {\n\t}\n") == [])
    }

    @Test func domainNames() {
        #expect(LaunchdServiceDomain.user(501).name == "gui/501")
        #expect(LaunchdServiceDomain.system.name == "system")
        #expect(LaunchdServiceDomain.system.isSystem && !LaunchdServiceDomain.user(501).isSystem)
    }

    @Test func readerAsksLaunchctlPrint() async throws {
        let runner = MockCommandRunner(["/bin/launchctl print gui/501": CommandResult(exitCode: 0, stdout: Self.oneService)])
        let services = try await LaunchdServiceReader(runner: runner).services(in: .user(501))
        #expect(services == [LaunchdServiceStatus(label: "com.example.agent", pid: 12, lastExit: .never)])
    }

    @Test func readerReportsFailureAndUnknownFormat() async {
        let runner = MockCommandRunner(["/bin/launchctl print system": CommandResult(exitCode: 0, stdout: "kein Block")])
        let reader = LaunchdServiceReader(runner: runner)
        await #expect(throws: LaunchdSourceError.self) { try await reader.services(in: .system) }
        await #expect(throws: LaunchdSourceError.self) { try await reader.services(in: .user(501)) }
    }

    /// Integration (nur lesend): `launchctl print system` geht auch ohne root.
    @Test func readsSystemDomainOfThisMac() async throws {
        #expect(try await !LaunchdServiceReader().services(in: .system).isEmpty)
    }
}

@MainActor
@Suite struct LaunchdServicesModelTests {
    @Test func readsBothDomainsAndKeepsFailuresSeparate() async {
        let runner = MockCommandRunner([
            "/bin/launchctl print gui/501": CommandResult(exitCode: 0,
                                                          stdout: "\tservices = {\n\t\t     12      - \tcom.example.agent\n\t}\n"),
        ])
        let model = LaunchdServicesModel(reader: LaunchdServiceReader(runner: runner), uid: 501)
        #expect(!model.hasLoaded)
        await model.refresh()
        #expect(model.listings[.user(501)]?.map(\.label) == ["com.example.agent"])
        #expect(model.listings[.system] == nil)
        #expect(model.failures.count == 1)
        #expect(model.failures.first?.hasPrefix("system: launchctl print system fehlgeschlagen (Exit 127)") == true)
        #expect(model.hasLoaded)
    }
}
