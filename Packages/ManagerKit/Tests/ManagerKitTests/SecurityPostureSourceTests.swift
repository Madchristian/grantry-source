import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

/// Reicht an `MockCommandRunner` weiter, merkt sich die Zeitlimits und wirft für `failing` den Fehler selbst –
/// wie `ProcessCommandRunner` bei Zeitüberschreitung oder fehlendem Werkzeug.
private final class RunnerSpy: CommandRunning {
    private let base: MockCommandRunner
    private let failing: [String: CommandError]
    private let recordedTimeouts = Mutex<[Duration]>([])

    init(_ base: MockCommandRunner, failing: [String: CommandError] = [:]) {
        self.base = base
        self.failing = failing
    }

    var timeouts: [Duration] { recordedTimeouts.withLock { $0 } }

    func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> CommandResult {
        recordedTimeouts.withLock { $0.append(timeout) }
        if let error = failing[([executable] + arguments).joined(separator: " ")] { throw error }
        return try await base.run(executable, arguments, timeout: timeout)
    }
}

/// Zählt Lesezugriffe auf die SoftwareUpdate-Plist.
private final class PreferencesReader: Sendable {
    private let data: Data
    private let reads = Mutex(0)

    init(_ data: Data) { self.data = data }

    var count: Int { reads.withLock { $0 } }

    func read() -> Data {
        reads.withLock { $0 += 1 }
        return data
    }
}

@Suite struct SecurityPostureSourceTests {
    private let now = TestData.date

    private func stubbedRunner() throws -> MockCommandRunner {
        MockCommandRunner([
            "/usr/bin/fdesetup status": CommandResult(exitCode: 0, stdout: try securityFixture("fdesetup-on.txt")),
            "/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate --getstealthmode":
                CommandResult(exitCode: 0, stdout: try securityFixture("socketfilterfw-on-stealth-off.txt")),
            "/usr/bin/csrutil status": CommandResult(exitCode: 0, stdout: try securityFixture("csrutil-enabled.txt")),
            "/usr/sbin/spctl --status": CommandResult(exitCode: 0, stdout: try securityFixture("spctl-enabled.txt")),
            "/usr/bin/xprotect version --json": CommandResult(exitCode: 0, stdout: try securityFixture("xprotect-version.json")),
            "/usr/bin/profiles status -type enrollment":
                CommandResult(exitCode: 0, stdout: try securityFixture("profiles-not-enrolled.txt")),
        ])
    }

    private func source(_ runner: MockCommandRunner, plist: @escaping @Sendable () throws -> Data) -> SecurityPostureSource {
        SecurityPostureSource.standard(runner: runner, readPreferences: plist, now: { [now] in now })
    }

    @Test func collectsAllChecksInKindOrder() async throws {
        let plist = try securityFixtureData("SoftwareUpdate.plist")
        let contribution = try await source(stubbedRunner(), plist: { plist }).collect()
        #expect(contribution.securityChecks.map(\.kind) == SecurityCheckKind.allCases)
        #expect(contribution.grants.isEmpty && contribution.autostartItems.isEmpty)
        let firewall = try #require(contribution.securityChecks.first { $0.kind == .firewall })
        #expect(firewall.state == .warning && firewall.facts == TestData.stealthOff)
    }

    @Test func pendingUpdateWithoutOfferDateStartsNow() async throws {
        let plist = try securityFixtureData("SoftwareUpdate.plist")
        let contribution = try await source(stubbedRunner(), plist: { plist }).collect()
        let pending = try #require(contribution.securityChecks.first { $0.kind == .pendingUpdates })
        guard case .pendingUpdates(let updates, _)? = pending.facts else { Issue.record("keine Fakten"); return }
        #expect(updates.first { $0.identifier == "ProVideoFormats" }?.firstSeenAt == now)
    }

    @Test func failingProbeOnlyMarksItsOwnCheckUnknown() async throws {
        let runner = try stubbedRunner()
        runner.stub("/usr/bin/csrutil status", CommandResult(exitCode: 1, stdout: "", stderr: "csrutil: boom"))
        runner.stub("/usr/sbin/spctl --status", CommandResult(exitCode: 0, stdout: "assessments maybe"))
        let contribution = try await source(runner, plist: { throw CocoaError(.fileReadNoPermission) }).collect()
        let byKind = Dictionary(uniqueKeysWithValues: contribution.securityChecks.map { ($0.kind, $0) })
        #expect(byKind[.sip]?.state == .unknown)
        #expect(byKind[.sip]?.detail == "csrutil status fehlgeschlagen (Exit 1): csrutil: boom")
        #expect(byKind[.gatekeeper]?.detail == "Unerwartete Ausgabe von spctl --status: „assessments maybe“")
        #expect(byKind[.automaticUpdates]?.state == .unknown && byKind[.pendingUpdates]?.state == .unknown)
        #expect(byKind[.fileVault]?.state == .good)
        #expect(byKind[.xprotect]?.state != .unknown)
    }

    /// Manche Werkzeuge melden Zustände mit Exit ≠ 0: Lässt sich `stdout` auswerten, zählt der Exit-Code nicht.
    @Test func parseableOutputWinsOverNonZeroExit() async throws {
        let runner = try stubbedRunner()
        runner.stub("/usr/bin/fdesetup status", CommandResult(exitCode: 1, stdout: try securityFixture("fdesetup-off.txt")))
        let contribution = try await source(runner, plist: { Data() }).collect()
        let fileVault = try #require(contribution.securityChecks.first { $0.kind == .fileVault })
        #expect(fileVault.state == .critical && fileVault.facts == .fileVault(.off))
    }

    /// `spctl --status` meldet „assessments disabled“ mit Exit 1: Gatekeeper ist aus, nicht unbekannt.
    @Test func gatekeeperDisabledWithExitOneIsRecognized() async throws {
        let runner = try stubbedRunner()
        runner.stub("/usr/sbin/spctl --status", try SecurityHardeningStubs.fixtureResult("spctl-disabled.txt"))
        let contribution = try await source(runner, plist: { Data() }).collect()
        let gatekeeper = try #require(contribution.securityChecks.first { $0.kind == .gatekeeper })
        #expect(gatekeeper.facts == .gatekeeper(enabled: false))
        #expect(gatekeeper.state != .unknown)
    }

    /// Beide Update-Prüfungen beruhen auf demselben Stand der Plist: Sie wird pro Scan genau einmal gelesen.
    @Test func softwareUpdatePreferencesAreReadOncePerCollect() async throws {
        let reader = PreferencesReader(try securityFixtureData("SoftwareUpdate.plist"))
        let contribution = try await source(stubbedRunner(), plist: reader.read).collect()
        #expect(reader.count == 1)
        let kinds = contribution.securityChecks.filter { $0.state != .unknown }.map(\.kind)
        #expect(kinds.contains(.automaticUpdates) && kinds.contains(.pendingUpdates))
    }

    /// Wirft der Runner selbst (Zeitüberschreitung, fehlendes Werkzeug), wird nur die betroffene Prüfung `unknown`.
    @Test func throwingRunnerOnlyMarksItsOwnCheckUnknown() async throws {
        let timeout = CommandError.timedOut(executable: "/usr/bin/csrutil", seconds: 15)
        let missing = CommandError.launchFailed(executable: "/usr/bin/profiles", reason: "nicht gefunden")
        let runner = RunnerSpy(try stubbedRunner(), failing: [
            "/usr/bin/csrutil status": timeout, "/usr/bin/profiles status -type enrollment": missing,
        ])
        let plist = try securityFixtureData("SoftwareUpdate.plist")
        let contribution = try await SecurityPostureSource.standard(runner: runner, readPreferences: { plist }, now: { [now] in now })
            .collect()
        let byKind = Dictionary(uniqueKeysWithValues: contribution.securityChecks.map { ($0.kind, $0) })
        #expect(byKind[.sip]?.state == .unknown && byKind[.sip]?.detail == timeout.readableDescription)
        #expect(byKind[.mdmEnrollment]?.state == .unknown && byKind[.mdmEnrollment]?.detail == missing.readableDescription)
        let others = contribution.securityChecks.filter { ![.sip, .mdmEnrollment].contains($0.kind) }
        #expect(others.count == 6 && others.allSatisfy { $0.state != .unknown })
    }

    /// Jeder Befehl bekommt das Zeitlimit von 15 Sekunden.
    @Test func commandsRunWithFifteenSecondTimeout() async throws {
        let runner = RunnerSpy(try stubbedRunner())
        _ = try await SecurityPostureSource.standard(runner: runner, readPreferences: { Data() }, now: { [now] in now })
            .collect()
        #expect(runner.timeouts == Array(repeating: .seconds(15), count: 6))
    }

    @Test func watchedPathsCoverFirewallUpdatesAndXProtect() {
        #expect(SecurityPostureSource.watchedFiles == [
            "/Library/Preferences/com.apple.SoftwareUpdate.plist",
            "/Library/Preferences/com.apple.networkextension.plist",
        ])
        #expect(SecurityPostureSource.watchedDirectories == [
            "/var/protected/xprotect/XProtect.bundle",
            "/Library/Apple/System/Library/CoreServices/XProtect.bundle",
        ])
    }
}
