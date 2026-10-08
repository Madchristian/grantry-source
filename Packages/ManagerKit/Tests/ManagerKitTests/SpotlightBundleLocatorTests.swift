import Foundation
import Testing
@testable import ManagerKit
import TestSupport

/// Runner, dessen Antwort je Programm eine Closure bestimmt – kann auch werfen (z. B. Zeitüberschreitung).
private struct ClosureRunner: CommandRunning {
    let handler: @Sendable (String) throws -> CommandResult
    func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> CommandResult {
        try handler(executable)
    }
}

@Suite struct SpotlightBundleLocatorTests {
    private static let mdutil = "/usr/bin/mdutil -s /System/Volumes/Data"
    /// Review N1: ohne Groß-/Kleinschreibung (`'…'c` – `==[c]` versteht `mdfind` nicht).
    private static func mdfind(_ bundleID: String) -> String {
        "/usr/bin/mdfind kMDItemCFBundleIdentifier == '\(bundleID)'c"
    }

    private static let enabled = "/System/Volumes/Data:\n\tIndexing enabled. \n"

    private func runner(indexing: String = enabled) -> MockCommandRunner {
        let runner = MockCommandRunner()
        runner.stub(Self.mdutil, CommandResult(exitCode: 0, stdout: indexing))
        return runner
    }

    @Test func bundleFoundBySpotlightIsFound() async {
        let runner = runner()
        runner.stub(Self.mdfind("com.microsoft.wdav.epsext"), CommandResult(
            exitCode: 0, stdout: "/Library/SystemExtensions/E1/com.microsoft.wdav.epsext.systemextension\n"))
        let lookup = await SpotlightBundleLocator(runner: runner).lookup(bundleID: "com.microsoft.wdav.epsext")
        #expect(lookup == .found)
    }

    @Test func emptyResultIsNotFound() async {
        let runner = runner()
        runner.stub(Self.mdfind("ai.openclaw.mac"), CommandResult(exitCode: 0, stdout: ""))
        #expect(await SpotlightBundleLocator(runner: runner).lookup(bundleID: "ai.openclaw.mac") == .notFound)
    }

    @Test(arguments: ["", "x' || kMDItemFSName == '*", "com.example app", "com.example/app", "com.exämple", "a\nb"])
    func invalidBundleIDRunsNoCommand(bundleID: String) async {
        let runner = runner()
        #expect(await SpotlightBundleLocator(runner: runner).lookup(bundleID: bundleID) == .unavailable)
        #expect(runner.calls.isEmpty)
    }

    @Test func failingMdfindIsUnavailable() async {
        let runner = runner()
        runner.stub(Self.mdfind("com.example"), CommandResult(exitCode: 1, stdout: "", stderr: "boom"))
        #expect(await SpotlightBundleLocator(runner: runner).lookup(bundleID: "com.example") == .unavailable)
    }

    @Test func underscoreIsAllowedInBundleIDs() async {
        let runner = runner()
        runner.stub(Self.mdfind("com.example_app"), CommandResult(exitCode: 0, stdout: ""))
        #expect(await SpotlightBundleLocator(runner: runner).lookup(bundleID: "com.example_app") == .notFound)
    }

    /// Nur `mdfind` läuft in die Zeitüberschreitung, die Indexprüfung gelingt.
    @Test func mdfindTimeoutIsUnavailable() async {
        let runner = ClosureRunner { executable in
            guard executable == "/usr/bin/mdfind" else { return CommandResult(exitCode: 0, stdout: Self.enabled) }
            throw CommandError.timedOut(executable: executable, seconds: 5)
        }
        #expect(await SpotlightBundleLocator(runner: runner).lookup(bundleID: "com.example") == .unavailable)
    }

    /// Eine gescheiterte Indexprüfung gilt nicht dauerhaft, sondern wird nach einer Minute wiederholt.
    @Test func failedIndexingProbeIsRetriedAfterAMinute() async {
        let runner = MockCommandRunner()
        runner.stub(Self.mdutil, CommandResult(exitCode: 1, stdout: "", stderr: "boom"))
        runner.stub(Self.mdfind("com.example"), CommandResult(exitCode: 0, stdout: ""))
        let clock = ManualClock()
        let locator = SpotlightBundleLocator(runner: runner, now: { clock.now })
        #expect(await locator.lookup(bundleID: "com.example") == .unavailable)
        runner.stub(Self.mdutil, CommandResult(exitCode: 0, stdout: Self.enabled))
        clock.advance(by: 59)
        #expect(await locator.lookup(bundleID: "com.example") == .unavailable)
        clock.advance(by: 2)
        #expect(await locator.lookup(bundleID: "com.example") == .notFound)
    }

    /// Ohne Index beweist ein leeres Ergebnis nichts.
    @Test(arguments: ["/System/Volumes/Data:\n\tIndexing disabled. \n", "/System/Volumes/Data:\n\tError: unknown indexing state.\n"])
    func disabledIndexingIsUnavailableWithoutQuery(indexing: String) async {
        let runner = runner(indexing: indexing)
        #expect(await SpotlightBundleLocator(runner: runner).lookup(bundleID: "com.example") == .unavailable)
        #expect(runner.calls == [Self.mdutil])
    }

    @Test func indexingStateIsCheckedOnce() async {
        let runner = runner()
        runner.stub(Self.mdfind("a.b"), CommandResult(exitCode: 0, stdout: ""))
        runner.stub(Self.mdfind("c.d"), CommandResult(exitCode: 0, stdout: ""))
        let locator = SpotlightBundleLocator(runner: runner)
        _ = await locator.lookup(bundleID: "a.b")
        _ = await locator.lookup(bundleID: "c.d")
        #expect(runner.calls.filter { $0 == Self.mdutil }.count == 1)
    }
}
