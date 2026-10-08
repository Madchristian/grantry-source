import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

/// Zeichnet Aufrufe auf und liefert feste Ergebnisse.
private final class FakeAgentConfigs: AgentConfigControlling {
    let calls = Mutex<[String]>([])
    let failure: AgentConfigEditError?
    let restoreResult: AgentRestoreResult

    init(failure: AgentConfigEditError? = nil, restoreResult: AgentRestoreResult = .restoredFile) {
        self.failure = failure
        self.restoreResult = restoreResult
    }

    func removeServer(_ entry: MCPServerEntry) async throws -> AgentConfigChange {
        calls.withLock { $0.append("remove \(entry.name)") }
        if let failure { throw failure }
        return ActionCoordinatorAgentTests.change(entry, .removedServer)
    }

    func setEnabled(_ entry: MCPServerEntry, _ enabled: Bool) async throws -> AgentConfigChange {
        calls.withLock { $0.append("enabled \(entry.name) \(enabled)") }
        if let failure { throw failure }
        return ActionCoordinatorAgentTests.change(entry, .setEnabled(enabled))
    }

    func restore(changeID: UUID) async throws -> AgentRestoreResult {
        calls.withLock { $0.append("restore") }
        if let failure { throw failure }
        return restoreResult
    }
}

/// Liefert immer denselben Snapshot.
private struct FixedScanner: ScanRequesting {
    let snapshot: Snapshot
    func scan(startedNotBefore date: Date) async -> Snapshot? { snapshot }
}

private struct NoPermissions: PermissionResetting {
    func reset(_ grant: PermissionGrant) async throws {}
    func resetService(_ service: String) async throws {}
}

private struct NoAutostart: AutostartControlling {
    func setEnabled(_ item: AutostartItem, _ enabled: Bool) async throws {}
    func remove(_ item: AutostartItem) async throws -> RemovalReceipt { throw CancellationError() }
    func restore(_ receipt: RemovalReceipt) async throws {}
}

private struct NoSecurity: SecurityControlling {
    func perform(_ action: SecurityAction) async throws {}
}

@Suite struct ActionCoordinatorAgentTests {
    static func change(_ entry: MCPServerEntry, _ kind: AgentConfigChange.Kind) -> AgentConfigChange {
        AgentConfigChange(id: UUID(), kind: kind, server: entry.reference, changedAt: TestData.date, originalDigest: "a",
                          resultDigest: "b")
    }

    private let server = TestData.mcpServer("files", toolID: "codex", toolName: "Codex", isEnabled: true)

    private func coordinator(_ agents: FakeAgentConfigs, servers: [MCPServerEntry]) -> ActionCoordinator {
        ActionCoordinator(
            permissions: NoPermissions(), autostart: NoAutostart(), security: NoSecurity(), agentConfigs: agents,
            scanner: FixedScanner(snapshot: TestData.agentSnapshot(servers)), clock: TestClock()
        )
    }

    @Test func removalIsConfirmedWhenTheServerIsGone() async {
        let agents = FakeAgentConfigs()
        #expect(await coordinator(agents, servers: []).removeServer(server) == .done)
        #expect(await coordinator(agents, servers: [server]).removeServer(server)
            == .doneButUnverified("Der Server ist im neuen Scan noch eingetragen."))
        #expect(agents.calls.withLock { $0 } == ["remove files", "remove files"])
    }

    @Test func failuresKeepTheirMessage() async {
        let agents = FakeAgentConfigs(failure: .fileChanged)
        #expect(await coordinator(agents, servers: [server]).removeServer(server)
            == .failed("Die Datei hat sich geändert, bitte erneut versuchen."))
    }

    @Test func switchingIsConfirmedByTheNewState() async {
        var disabled = server
        disabled.isEnabled = false
        #expect(await coordinator(FakeAgentConfigs(), servers: [disabled]).setServerEnabled(server, false) == .done)
        #expect(await coordinator(FakeAgentConfigs(), servers: [server]).setServerEnabled(server, false)
            == .doneButUnverified("Die Änderung ist im neuen Scan noch nicht zu sehen."))
    }

    @Test func restoreIsConfirmedByTheFormerState() async {
        let removal = Self.change(server, .removedServer)
        #expect(await coordinator(FakeAgentConfigs(), servers: [server]).restoreAgentChange(removal) == .done)
        let switched = Self.change(server, .setEnabled(false))
        #expect(await coordinator(FakeAgentConfigs(), servers: [server]).restoreAgentChange(switched) == .done)
        let already = FakeAgentConfigs(restoreResult: .alreadyRestored)
        #expect(await coordinator(already, servers: [server]).restoreAgentChange(removal)
            == .doneButUnverified("„files“ (Codex) stand bereits wieder so in der Datei – nichts geändert."))
        #expect(await coordinator(FakeAgentConfigs(), servers: []).restoreAgentChange(removal)
            == .doneButUnverified("Wiederhergestellt, aber im neuen Scan noch nicht zu sehen."))
    }

    /// Scheitert das Wiederherstellen, zeigt der Scan aber schon den früheren Zustand: eigener Hinweis, Beleg bleibt.
    @Test func failedRestoreWhoseStateAlreadyFitsSaysSo() async {
        let removal = Self.change(server, .removedServer)
        #expect(await coordinator(FakeAgentConfigs(failure: .fileChanged), servers: [server]).restoreAgentChange(removal)
            == .doneButUnverified("„files“ (Codex) stand bereits so in der Datei; der Beleg bleibt erhalten."))
        #expect(await coordinator(FakeAgentConfigs(failure: .fileChanged), servers: []).restoreAgentChange(removal)
            == .failed(AgentConfigEditError.fileChanged.errorDescription ?? ""))
    }

    /// Belegt der Fehler, dass nichts wiederhergestellt wurde, ist ein gleichnamiger Server im Scan ein anderer: echte
    /// Meldung statt „stand bereits so“ (Review #147).
    @Test func restoreFailuresThatRuleOutAnEffectKeepTheirMessage() async {
        let removal = Self.change(server, .removedServer)
        for error in [AgentConfigEditError.nameTaken, .unsupportedLayout, .changeNotFound] {
            #expect(await coordinator(FakeAgentConfigs(failure: error), servers: [server]).restoreAgentChange(removal)
                == .failed(error.errorDescription ?? ""))
        }
    }

    /// Fehler, aber wirksam: Ohne Änderung der Datei gibt es keinen Beleg; nach `replacedUnverified` gibt es ihn, und
    /// der Fehlertext sagt das.
    @Test func effectiveFailuresNameWhetherAReceiptExists() async {
        #expect(await coordinator(FakeAgentConfigs(failure: .fileChanged), servers: []).removeServer(server)
            == .doneButUnverified("\(ActionCoordinator.effectiveDespiteFailure) Kein Wiederherstellungsbeleg vorhanden."))
        let unverified = AgentConfigEditError.replacedUnverified("Rücktausch gescheitert")
        let message = unverified.errorDescription ?? ""
        #expect(message.contains("Die Sicherung bleibt im Verlauf erhalten."))
        #expect(await coordinator(FakeAgentConfigs(failure: unverified), servers: []).removeServer(server)
            == .doneButUnverified(message))
        var disabled = server
        disabled.isEnabled = false
        #expect(await coordinator(FakeAgentConfigs(failure: unverified), servers: [disabled]).setServerEnabled(server, false)
            == .doneButUnverified(message))
        #expect(await coordinator(FakeAgentConfigs(failure: .fileChanged), servers: [disabled]).setServerEnabled(server, false)
            == .doneButUnverified(ActionCoordinator.effectiveDespiteFailure))
    }
}

@MainActor
@Suite struct ActionRunnerAgentTests {
    private let server = TestData.mcpServer("files", toolID: "codex", toolName: "Codex", isEnabled: true)

    private func runner(servers: [MCPServerEntry], agents: FakeAgentConfigs = FakeAgentConfigs()) -> ActionRunner {
        let coordinator = ActionCoordinator(
            permissions: NoPermissions(), autostart: NoAutostart(), security: NoSecurity(), agentConfigs: agents,
            scanner: FixedScanner(snapshot: TestData.agentSnapshot(servers)), clock: TestClock()
        )
        return ActionRunner(helperActivity: HelperActivityLock(), coordinator: coordinator)
    }

    @Test func runsAgentActionsAndPresentsTheirResults() async {
        let agents = FakeAgentConfigs()
        let removing = runner(servers: [], agents: agents)
        await removing.removeServer(server, context: .agents)
        #expect(removing.result(in: .agents) == .removeServer(server, outcome: .done))

        var disabled = server
        disabled.isEnabled = false
        let switching = runner(servers: [disabled], agents: agents)
        await switching.setServerEnabled(server, false, context: .agents)
        #expect(switching.result(in: .agents) == .setServerEnabled(server, false, outcome: .done))

        let change = ActionCoordinatorAgentTests.change(server, .removedServer)
        let restoring = runner(servers: [server], agents: agents)
        await restoring.restore(RestorableChange.agentConfig(change), context: .history)
        #expect(restoring.result(in: .history) == .restore(change, outcome: .done))
        #expect(restoring.result(in: .agents) == nil)
        #expect(agents.calls.withLock { $0 } == ["remove files", "enabled files false", "restore"])
    }
}

@Suite struct AgentActionPresentationTests {
    private let home = "/Users/test"

    @Test func confirmationsNameEntryFileAndRestart() {
        let entry = TestData.mcpServer("files", toolID: "codex", toolName: "Codex", configPath: home + "/.codex/config.toml")
        let confirmation = ActionConfirmation.removeServer(entry, capabilities: entry.editCapabilities(home: home))
        #expect(confirmation.title == "„files“ aus Codex entfernen?")
        #expect(confirmation.isDestructive && confirmation.confirmTitle == "Entfernen")
        #expect(confirmation.note == "Codex übernimmt die Änderung erst nach einem Neustart.")
    }

    @Test func restoreConfirmationNamesLocationAndFile() {
        let entry = TestData.mcpServer("files", toolID: "codex", toolName: "Codex", configPath: home + "/.codex/config.toml")
        let removal = AgentConfigChange(id: UUID(), kind: .removedServer, server: entry.reference, changedAt: TestData.date,
                                        originalDigest: "a", resultDigest: "b")
        let confirmation = ActionConfirmation.restore(.agentConfig(removal), home: home)
        #expect(confirmation.title == "„files“ (Codex) wiederherstellen?")
        #expect(confirmation.message?.hasPrefix("Grantry trägt den entfernten Server wieder in Codex (~/.codex/config.toml) ein.") == true)
        let switched = AgentConfigChange(id: UUID(), kind: .setEnabled(false), server: entry.reference, changedAt: TestData.date,
                                         originalDigest: "a", resultDigest: "b")
        #expect(ActionConfirmation.restore(.agentConfig(switched), home: home).message?.hasPrefix("Grantry stellt den Server in Codex (~/.codex/config.toml) wieder auf „aktiviert“.") == true)
        #expect(ActionConfirmation.removeServer(entry, capabilities: entry.editCapabilities(home: home), home: home).message?.contains("aus ~/.codex/config.toml;") == true)
        #expect(ActionOutcomePresentation.removeServer(entry, outcome: .done, home: home)
            == ActionOutcomePresentation(.done, successMessage: "„files“ wurde aus Codex entfernt. "
                + "Codex übernimmt die Änderung erst nach einem Neustart. Wiederherstellen ist im Verlauf möglich."))
    }

    @Test func namesRestorablesLikeTheHistory() {
        let entry = TestData.mcpServer("files")
        let removal = AgentConfigChange(id: UUID(), kind: .removedServer, server: entry.reference, changedAt: TestData.date,
                                        originalDigest: "a", resultDigest: "b")
        let switched = AgentConfigChange(id: UUID(), kind: .setEnabled(true), server: entry.reference, changedAt: TestData.date,
                                         originalDigest: "a", resultDigest: "b")
        #expect(RestorableChange.agentConfig(removal).actionName == ChangeEvent.Kind.removed.displayName)
        #expect(RestorableChange.agentConfig(switched).actionName == ChangeEvent.Kind.modified.displayName)
        #expect(RestorableChange.agentConfig(switched).restoreHelp == "Gesicherte Konfiguration bzw. den Eintrag zurücklegen")
    }

    /// Zuordnung: nur gleiche Art und gleicher Server innerhalb der Toleranz, das zeitlich nächste Ereignis, Schalter
    /// beim Ereignis „Geändert“; Autostart- und Agenten-Belege nebeneinander.
    @Test func matchesAgentChangesByKindToleranceAndDistance() {
        let entry = TestData.mcpServer("files")
        let other = TestData.mcpServer("andere")
        func change(_ kind: AgentConfigChange.Kind, at seconds: TimeInterval = 0) -> AgentConfigChange {
            AgentConfigChange(id: UUID(), kind: kind, server: entry.reference, changedAt: TestData.date.addingTimeInterval(seconds),
                              originalDigest: "a", resultDigest: "b")
        }
        func event(_ kind: ChangeEvent.Kind, _ server: MCPServerEntry = entry, at seconds: TimeInterval) -> HistoryEvent {
            TestData.historyEvent(kind, .mcpServer(server), at: TestData.date.addingTimeInterval(seconds))
        }
        let removal = change(.removedServer)
        let wrongKind = event(.modified, at: 1)
        let wrongServer = event(.removed, other, at: 1)
        let tooLate = event(.removed, at: RestoreMatching.defaultTolerance + 1)
        let far = event(.removed, at: 120)
        let near = event(.removed, at: -30)
        let matches = RestoreMatching.restorablesByEvent(events: [wrongKind, wrongServer, tooLate, far, near], receipts: [], changes: [removal])
        #expect(matches == [near.id: .agentConfig(removal)])

        let switched = change(.setEnabled(false), at: 10)
        let modified = event(.modified, at: 12)
        let item = TestData.item("com.example.a")
        let autostartRemoval = TestData.historyEvent(.removed, .autostartItem(item), at: TestData.date)
        let receipt = ReceiptEntry(id: UUID(), receipt: RemovalReceipt(
            label: item.label, backupPath: "/Users/test/Library/Application Support/Grantry/Backups/x/LaunchAgents/com.example.a.plist",
            isPrivileged: false, wasEnabled: true, wasLoaded: true
        ), label: item.label, removedAt: TestData.date, eventID: autostartRemoval.id)
        let mixed = RestoreMatching.restorablesByEvent(events: [autostartRemoval, modified, near], receipts: [receipt],
                                                       changes: [removal, switched])
        #expect(mixed == [autostartRemoval.id: .autostart(receipt), modified.id: .agentConfig(switched), near.id: .agentConfig(removal)])
    }

    @Test func matchesAgentChangesToTheirEvents() {
        let entry = TestData.mcpServer("files")
        let removal = AgentConfigChange(id: UUID(), kind: .removedServer, server: entry.reference,
                                        changedAt: TestData.date, originalDigest: "a", resultDigest: "b")
        let event = TestData.historyEvent(.removed, .mcpServer(entry), at: TestData.date.addingTimeInterval(5))
        let other = TestData.historyEvent(.modified, .mcpServer(entry), at: TestData.date)
        let matches = RestoreMatching.restorablesByEvent(events: [event, other], receipts: [], changes: [removal])
        #expect(matches == [event.id: .agentConfig(removal)])
        #expect(RestoreMatching.unmatchedRestorables(receipts: [], changes: [removal], matches: matches, filter: HistoryFilter(),
                                                     now: TestData.date).isEmpty)
        #expect(RestoreMatching.unmatchedRestorables(receipts: [], changes: [removal], matches: [:],
                                                     filter: HistoryFilter(category: .autostart), now: TestData.date).isEmpty)
        #expect(RestoreMatching.unmatchedRestorables(receipts: [], changes: [removal], matches: [:],
                                                     filter: HistoryFilter(category: .agents), now: TestData.date) == [.agentConfig(removal)])
    }
}
