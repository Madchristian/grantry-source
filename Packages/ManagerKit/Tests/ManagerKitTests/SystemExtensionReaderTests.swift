import Foundation
import GrantryShared
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct SystemExtensionReaderTests {
    private static let command = "/usr/bin/systemextensionsctl list"

    @Test func readsListWithoutRoot() async throws {
        let runner = MockCommandRunner([
            Self.command: CommandResult(exitCode: 0, stdout: "0 extension(s)\n"),
        ])
        let list = try await SystemExtensionReader(runner: runner).systemExtensions()
        #expect(list.extensions.isEmpty)
        #expect(runner.calls == [Self.command])
    }

    /// Manche Werkzeuge melden mit Exit ≠ 0 trotzdem eine lesbare Liste; sie zählt.
    @Test func parseableOutputWinsOverExitCode() async throws {
        let runner = MockCommandRunner([Self.command: CommandResult(exitCode: 1, stdout: "0 extension(s)\n")])
        let list = try await SystemExtensionReader(runner: runner).systemExtensions()
        #expect(list.isComplete)
    }

    @Test func failedCommandNamesExitCodeAndDetail() async {
        let runner = MockCommandRunner([
            Self.command: CommandResult(exitCode: 64, stdout: "", stderr: "evil\nFAKE line"),
        ])
        await #expect(throws: ExtensionReadError.commandFailed(command: "systemextensionsctl list", exitCode: 64, detail: "evil FAKE line")) {
            try await SystemExtensionReader(runner: runner).systemExtensions()
        }
    }

    @Test func unknownFormatIsReported() async {
        let runner = MockCommandRunner([Self.command: CommandResult(exitCode: 0, stdout: "something new\n")])
        await #expect(throws: ExtensionReadError.unparseableOutput(command: "systemextensionsctl list")) {
            try await SystemExtensionReader(runner: runner).systemExtensions()
        }
    }
}
