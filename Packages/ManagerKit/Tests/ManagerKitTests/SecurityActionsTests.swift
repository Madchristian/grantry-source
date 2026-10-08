import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

private final class RecordingHardening: PrivilegedSecurityControlling {
    private let performed = Mutex<[SecurityHardening]>([])
    private let failure: (any Error)?
    private let version: Int

    init(failure: (any Error)? = nil, version: Int = HelperXPC.protocolVersion) {
        self.failure = failure
        self.version = version
    }

    var all: [SecurityHardening] { performed.withLock { $0 } }

    func protocolVersion() async throws -> Int { version }

    func perform(_ hardening: SecurityHardening) async throws {
        performed.withLock { $0.append(hardening) }
        if let failure { throw failure }
    }
}

/// Läuft wie `ProcessCommandRunner` in seine Frist.
private struct TimingOutRunner: CommandRunning {
    func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> CommandResult {
        throw CommandError.timedOut(executable: executable, seconds: timeout.seconds)
    }
}

private struct UnreachableHelper: PrivilegedSecurityControlling {
    func protocolVersion() async throws -> Int { throw HelperClientError.unavailable("weg") }
    func perform(_ hardening: SecurityHardening) async throws { Issue.record("darf nicht gesendet werden") }
}

@Suite struct SecurityActionsTests {
    private static let search = "/usr/sbin/softwareupdate --list"

    @Test func helperActionsGoThroughTheHelper() async throws {
        let helper = RecordingHardening()
        let runner = MockCommandRunner()
        let actions = SecurityActions(privileged: helper, runner: runner)
        for action in SecurityAction.allCases where action.requiresHelper { try await actions.perform(action) }
        #expect(helper.all == SecurityHardening.allCases)
        #expect(runner.calls.isEmpty)
    }

    @Test func onlyTheSearchRunsWithoutTheHelper() {
        #expect(SecurityAction.allCases.filter { !$0.requiresHelper } == [.checkForUpdates])
    }

    @Test func helperErrorsBecomeReadableActionErrors() async {
        let helper = RecordingHardening(failure: HelperClientError.rejected("spctl fehlgeschlagen (Exit 1)"))
        await #expect(throws: ActionError.commandFailed("spctl fehlgeschlagen (Exit 1)")) {
            try await SecurityActions(privileged: helper, runner: MockCommandRunner()).perform(.enableGatekeeper)
        }
    }

    /// Ein Helper aus v1 kennt die Absichern-Methoden nicht und ließe den Aufruf bis zur Frist hängen.
    @Test(arguments: [1, HelperXPC.protocolVersion + 1])
    func outdatedHelperFailsImmediatelyWithoutSending(_ version: Int) async {
        let helper = RecordingHardening(version: version)
        await #expect(throws: ActionError.commandFailed("Helper veraltet – bitte neu installieren")) {
            try await SecurityActions(privileged: helper, runner: MockCommandRunner()).perform(.enableFirewall)
        }
        #expect(helper.all.isEmpty)
    }

    @Test func unreachableHelperDuringVersionCheckBecomesReadableError() async {
        let helper = UnreachableHelper()
        await #expect(throws: ActionError.commandFailed("Helper nicht erreichbar: weg")) {
            try await SecurityActions(privileged: helper, runner: MockCommandRunner()).perform(.enableGatekeeper)
        }
    }

    @Test func cancellationOfTheHelperStaysCancellation() async {
        let helper = RecordingHardening(failure: CancellationError())
        await #expect(throws: CancellationError.self) {
            try await SecurityActions(privileged: helper, runner: MockCommandRunner()).perform(.enableFirewall)
        }
    }

    @Test func checkForUpdatesRunsSoftwareupdateListAsUser() async throws {
        let helper = RecordingHardening()
        let runner = MockCommandRunner([Self.search: CommandResult(exitCode: 0, stdout: "", stderr: "No new software available.")])
        try await SecurityActions(privileged: helper, runner: runner).perform(.checkForUpdates)
        #expect(runner.calls == [Self.search])
        #expect(helper.all.isEmpty)
    }

    @Test func failedSearchReportsNoConnection() async {
        let runner = MockCommandRunner([Self.search: CommandResult(exitCode: 1, stdout: "", stderr: "Can’t connect\n")])
        await #expect(throws: ActionError.commandFailed("Suche fehlgeschlagen – keine Verbindung (Can’t connect)")) {
            try await SecurityActions(privileged: RecordingHardening(), runner: runner).perform(.checkForUpdates)
        }
    }

    @Test func searchWithoutAnswerReportsTheWaitWithoutPath() async {
        await #expect(throws: ActionError.commandFailed("Suche fehlgeschlagen – keine Verbindung (keine Antwort nach 3 min)")) {
            try await SecurityActions(privileged: RecordingHardening(), runner: TimingOutRunner()).perform(.checkForUpdates)
        }
    }

    @Test func failedSearchWithoutOutputHasNoDetail() async {
        let runner = MockCommandRunner([Self.search: CommandResult(exitCode: 1, stdout: " ", stderr: "")])
        await #expect(throws: ActionError.commandFailed("Suche fehlgeschlagen – keine Verbindung")) {
            try await SecurityActions(privileged: RecordingHardening(), runner: runner).perform(.checkForUpdates)
        }
    }

    @Test func verificationPerAction() {
        let start = TestData.date
        func snapshot(_ facts: SecurityFacts...) -> Snapshot {
            var snapshot = TestData.snapshot()
            snapshot.securityChecks = facts.map { TestData.evaluatedCheck($0, now: start) }
            return snapshot
        }
        typealias V = SecurityActionVerification
        #expect(V.isConfirmed(.enableStealthMode, in: snapshot(TestData.firewallOn), startedAt: start))
        #expect(!V.isConfirmed(.enableStealthMode, in: snapshot(TestData.stealthOff), startedAt: start))
        #expect(V.isConfirmed(.enableFirewall, in: snapshot(TestData.stealthOff), startedAt: start))
        #expect(!V.isConfirmed(.enableFirewall, in: snapshot(TestData.firewallOff), startedAt: start))
        #expect(V.isConfirmed(.enableGatekeeper, in: snapshot(.gatekeeper(enabled: true)), startedAt: start))
        #expect(!V.isConfirmed(.enableGatekeeper, in: snapshot(.gatekeeper(enabled: false)), startedAt: start))
        #expect(V.isConfirmed(.enableAutomaticUpdates, in: snapshot(.automaticUpdates(disabled: [])), startedAt: start))
        #expect(!V.isConfirmed(.enableAutomaticUpdates, in: snapshot(.automaticUpdates(disabled: [.automaticDownload])), startedAt: start))
        #expect(V.isConfirmed(.checkForUpdates, in: snapshot(.pendingUpdates(updates: [], lastCheck: start + 5)), startedAt: start))
        #expect(!V.isConfirmed(.checkForUpdates, in: snapshot(.pendingUpdates(updates: [], lastCheck: start - 5)), startedAt: start))
        #expect(!V.isConfirmed(.checkForUpdates, in: snapshot(.pendingUpdates(updates: [], lastCheck: nil)), startedAt: start))
        #expect(V.isConfirmed(.updateXProtect, in: snapshot(.xprotect(version: "2", installedAt: start + 1)), startedAt: start))
        // Kein neues XProtect, aber das vorhandene ist aktuell (Ampel grün).
        #expect(V.isConfirmed(.updateXProtect, in: snapshot(.xprotect(version: "1", installedAt: start - 86_400)), startedAt: start))
        #expect(!V.isConfirmed(.updateXProtect, in: snapshot(.xprotect(version: "1", installedAt: start - 20 * 86_400)), startedAt: start))
        #expect(!V.isConfirmed(.enableFirewall, in: TestData.snapshot(), startedAt: start))  // Prüfung fehlt
    }

    /// Nach einem Fehler zählt nur, was die Aktion bewirkt haben kann: bei XProtect eine Installation seit dem Start.
    @Test func effectDespiteFailureIsStricterForXProtect() {
        let start = TestData.date
        func snapshot(_ facts: SecurityFacts) -> Snapshot {
            var snapshot = TestData.snapshot()
            snapshot.securityChecks = [TestData.evaluatedCheck(facts, now: start)]
            return snapshot
        }
        typealias V = SecurityActionVerification
        let current = snapshot(.xprotect(version: "1", installedAt: start - 86_400))
        #expect(V.isConfirmed(.updateXProtect, in: current, startedAt: start))
        #expect(!V.isEffectiveDespiteFailure(.updateXProtect, in: current, startedAt: start))
        #expect(V.isEffectiveDespiteFailure(.updateXProtect, in: snapshot(.xprotect(version: "2", installedAt: start)), startedAt: start))
        #expect(V.isEffectiveDespiteFailure(.enableGatekeeper, in: snapshot(.gatekeeper(enabled: true)), startedAt: start))
        #expect(!V.isEffectiveDespiteFailure(.enableGatekeeper, in: snapshot(.gatekeeper(enabled: false)), startedAt: start))
    }

    @Test func onlyTheSearchIsCancelledWhenQuitting() {
        #expect(SecurityAction.allCases.filter(\.isCancellableWhenQuitting) == [.checkForUpdates])
    }

    @Test func unreadableCheckConfirmsNothing() {
        var snapshot = TestData.snapshot()
        var check = SecurityCheck.failed(.firewall, detail: "socketfilterfw fehlgeschlagen")
        check.facts = TestData.firewallOn  // fortgeschrieben
        check.lastKnownState = .good
        snapshot.securityChecks = [check]
        #expect(!SecurityActionVerification.isConfirmed(.enableFirewall, in: snapshot, startedAt: TestData.date))
    }

    @Test func unconfirmedOutcomesLeadToTheMatchingSettings() {
        typealias V = SecurityActionVerification
        #expect(V.unconfirmed(.enableFirewall) == .doneButUnverified(
            "Die Änderung ist im neuen Scan noch nicht zu sehen.", settingsURL: SecuritySettingsLinks.firewall
        ))
        #expect(V.unconfirmed(.enableGatekeeper) == .doneButUnverified(
            "Die Änderung ist im neuen Scan noch nicht zu sehen.", settingsURL: SecuritySettingsLinks.privacyAndSecurity
        ))
        #expect(V.unconfirmed(.enableAutomaticUpdates) == .doneButUnverified(
            "Die Änderung ist im neuen Scan noch nicht zu sehen.", settingsURL: SecuritySettingsLinks.softwareUpdate
        ))
        #expect(V.unconfirmed(.checkForUpdates) == .doneButUnverified(
            "Die Suche ist beendet, das Datum der letzten Suche hat sich aber nicht geändert.",
            settingsURL: SecuritySettingsLinks.softwareUpdate
        ))
        #expect(V.unconfirmed(.updateXProtect) == .doneButUnverified("Es wurde keine neuere XProtect-Version installiert."))
    }

    @Test func everyActionHasItsCheckAndSuccessMessage() {
        #expect(SecurityAction.allCases.map(\.checkKind) == [
            .firewall, .firewall, .gatekeeper, .automaticUpdates, .xprotect, .pendingUpdates,
        ])
        #expect(ActionOutcomePresentation.security(.enableStealthMode, outcome: .done).text == "Der Tarnmodus ist eingeschaltet.")
        #expect(Set(SecurityAction.allCases.map(\.successMessage)).count == SecurityAction.allCases.count)
    }
}
