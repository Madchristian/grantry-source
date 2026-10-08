import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

// MARK: - Testdoubles

/// Gemeinsames Protokoll aller Testdoubles, um die Reihenfolge von Aktionen und Scans zu prüfen.
private final class CallLog: Sendable {
    private let entries = Mutex<[String]>([])
    func append(_ entry: String) { entries.withLock { $0.append(entry) } }
    var all: [String] { entries.withLock { $0 } }
}

private struct FakeFailure: LocalizedError {
    var errorDescription: String? { "Befehl fehlgeschlagen" }
}

/// Liefert je Scan den nächsten Snapshot aus `script` (der letzte wiederholt sich); `nil` bildet einen Scan nach,
/// der ausbleibt. Mit `hang` wartet jeder Scan, bis er abgebrochen wird.
private final class ScriptedScanner: ScanRequesting {
    private struct State {
        var script: [Snapshot?]
        var requestedDates: [Date] = []
    }

    private let log: CallLog
    private let hang: Bool
    private let state: Mutex<State>

    init(log: CallLog, script: [Snapshot?] = [TestData.snapshot()], hang: Bool = false) {
        self.log = log
        self.hang = hang
        state = Mutex(State(script: script))
    }

    var requestedDates: [Date] { state.withLock { $0.requestedDates } }

    func scan(startedNotBefore date: Date) async -> Snapshot? {
        log.append("scan")
        let snapshot = state.withLock { state in
            state.requestedDates.append(date)
            return state.script.count > 1 ? state.script.removeFirst() : state.script.first ?? nil
        }
        if hang { try? await Gate().wait() }
        return hang ? nil : snapshot
    }
}

private final class FakePermissions: PermissionResetting {
    private let log: CallLog
    private let failure: (any Error)?

    init(log: CallLog, failure: (any Error)? = nil) {
        self.log = log
        self.failure = failure
    }

    func reset(_ grant: PermissionGrant) async throws {
        log.append("reset \(grant.client.displayName)")
        if let failure { throw failure }
    }

    func resetService(_ service: String) async throws {
        log.append("reset service \(service)")
        if let failure { throw failure }
    }
}

/// Mit `gate` hält jeder `setEnabled`- und `remove`-Aufruf nach seinem Beginn an; `started` meldet den Beginn.
private final class FakeAutostart: AutostartControlling {
    private let log: CallLog
    private let failure: (any Error)?
    private let gate: Gate?
    let started = Gate()
    let receipt: RemovalReceipt

    init(log: CallLog, failure: (any Error)? = nil, gate: Gate? = nil, receipt: RemovalReceipt = ActionCoordinatorTests.receipt) {
        self.log = log
        self.failure = failure
        self.gate = gate
        self.receipt = receipt
    }

    func setEnabled(_ item: AutostartItem, _ enabled: Bool) async throws {
        log.append("begin \(item.label)")
        started.open()
        try await gate?.wait()
        log.append("end \(item.label)")
        if let failure { throw failure }
    }

    func remove(_ item: AutostartItem) async throws -> RemovalReceipt {
        log.append("remove \(item.label)")
        started.open()
        try await gate?.wait()
        if let failure { throw failure }
        return receipt
    }

    func restore(_ receipt: RemovalReceipt) async throws {
        log.append("restore \(receipt.label)")
        if let failure { throw failure }
    }
}

/// Mit `gate` hält jeder Aufruf nach seinem Beginn an; `started` meldet den Beginn.
private final class FakeSecurity: SecurityControlling {
    private let log: CallLog
    private let failure: (any Error)?
    private let gate: Gate?
    let started = Gate()

    init(log: CallLog, failure: (any Error)? = nil, gate: Gate? = nil) {
        self.log = log
        self.failure = failure
        self.gate = gate
    }

    func perform(_ action: SecurityAction) async throws {
        log.append("security \(action.rawValue)")
        started.open()
        try await gate?.wait()
        log.append("security done \(action.rawValue)")
        if let failure { throw failure }
    }
}

/// Befehl, der erst durch Abbruch endet (wie `softwareupdate --list` ohne Antwort); `started` meldet den Beginn.
private final class BlockingRunner: CommandRunning {
    let started = Gate()
    private let cancelled = Mutex(false)
    var wasCancelled: Bool { cancelled.withLock { $0 } }

    func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> CommandResult {
        started.open()
        do {
            try await Gate().wait()
        } catch {
            cancelled.withLock { $0 = true }
            throw error
        }
        return CommandResult(exitCode: 0, stdout: "")
    }
}

/// Papierkorb-Attrappe ohne Wirkung: Freigabe erteilt, alle Pfade gelten als entfernt. Mit `gate` hält `moveToTrash`
/// nach seinem Beginn an.
private final class FakeTrash: TrashPerforming {
    private let log: CallLog
    private let gate: Gate?
    let started = Gate()

    init(log: CallLog, gate: Gate? = nil) {
        self.log = log
        self.gate = gate
    }

    func requestPermission() async -> TrashPermission { .granted }

    func moveToTrash(
        _ candidates: [LeftoverCandidate], verifying verify: @escaping @Sendable (LeftoverCandidate) -> RemovalVerdict
    ) async -> TrashReport {
        let paths = candidates.map(\.path)
        log.append("trash \(paths.count)")
        started.open()
        try? await gate?.wait()
        log.append("trash done")
        return TrashReport(outcomes: Dictionary(uniqueKeysWithValues: paths.map { ($0, .trashed) }), failure: nil)
    }
}

private struct UnusedHelper: PrivilegedSecurityControlling {
    func protocolVersion() async throws -> Int { HelperXPC.protocolVersion }
    func perform(_ hardening: SecurityHardening) async throws { Issue.record("Helper nicht erwartet") }
}

/// Liefert je Aufruf den nächsten Bericht (der letzte wiederholt sich).
private final class FakeProcesses: ProcessTerminating {
    private let log: CallLog
    private let reports: Mutex<[ProcessTerminationReport]>

    init(log: CallLog, reports: [ProcessTerminationReport]) {
        self.log = log
        self.reports = Mutex(reports)
    }

    func terminate(_ request: ProcessTerminationRequest, force: Bool) async -> ProcessTerminationReport {
        log.append("\(force ? "kill" : "term") \(request.processes.map(\.pid))")
        return reports.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
    }
}

// MARK: - Tests

@Suite struct ActionCoordinatorTests {
    static let receipt = RemovalReceipt(
        label: "com.vendor.agent", backupPath: "/backups/1/LaunchAgents/com.vendor.agent.plist",
        isPrivileged: false, wasEnabled: true, wasLoaded: true
    )

    private let log = CallLog()
    private let clock = ManualClock()

    private func coordinator(
        permissions: (any PermissionResetting)? = nil,
        autostart: (any AutostartControlling)? = nil,
        security: (any SecurityControlling)? = nil,
        processTermination: (any ProcessTerminating)? = nil,
        scanner: any ScanRequesting,
        receipts: ReceiptStore,
        trash: any TrashPerforming = UnavailableTrash(),
        removalGuard: RemovalGuard = RemovalGuard(),
        timeout: Duration = .seconds(30),
        timeoutClock: any Clock<Duration> = TestClock()
    ) -> ActionCoordinator {
        let clock = clock
        return ActionCoordinator(
            permissions: permissions ?? FakePermissions(log: log),
            autostart: autostart ?? FakeAutostart(log: log),
            security: security ?? FakeSecurity(log: log),
            processTermination: processTermination ?? FakeProcesses(log: log, reports: [ProcessTerminationReport()]),
            receipts: receipts,
            scanner: scanner,
            trash: trash,
            removalGuard: removalGuard,
            verificationTimeout: timeout,
            clock: timeoutClock,
            now: { clock.now }
        )
    }

    private func withReceipts<T>(_ body: (ReceiptStore) async throws -> T) async throws -> T {
        try await ScratchDirectory.withCanonical(prefix: "coordinator") { directory in
            try await body(ReceiptStore(url: directory.appending(path: "Receipts.json")))
        }
    }

    // MARK: Zurücksetzen

    @Test func resetIsDoneWhenTheGrantIsGoneInTheFreshSnapshot() async throws {
        try await withReceipts { receipts in
            let scanner = ScriptedScanner(log: log, script: [TestData.snapshot()])
            let outcome = await coordinator(scanner: scanner, receipts: receipts).reset(TestData.grant())
            #expect(outcome == .done)
            #expect(log.all == ["reset us.zoom.xos", "scan"])
            #expect(scanner.requestedDates == [clock.now])
        }
    }

    @Test func resetIsUnverifiedWithDeeplinkWhileTheGrantIsStillThere() async throws {
        try await withReceipts { receipts in
            let grant = TestData.grant()
            let scanner = ScriptedScanner(log: log, script: [TestData.snapshot(grants: [grant])])
            let outcome = await coordinator(scanner: scanner, receipts: receipts).reset(grant)
            #expect(outcome == .doneButUnverified(
                "Die Berechtigung ist noch eingetragen – bitte in den Systemeinstellungen entfernen.",
                settingsURL: PermissionCatalog.service(for: grant.service).settingsURL
            ))
        }
    }

    @Test func resetIsPendingWhenTheSourceFailedInTheFreshSnapshot() async throws {
        try await withReceipts { receipts in
            let grant = TestData.grant()
            let failed = TestData.snapshot(grants: [grant], errors: [SourceError(source: grant.source, message: "x")])
            let outcome = await coordinator(scanner: ScriptedScanner(log: log, script: [failed]), receipts: receipts).reset(grant)
            #expect(outcome == .doneButUnverified(ActionCoordinator.pendingVerification))
        }
    }

    @Test func failedResetStillRescansAndReportsTheReadableError() async throws {
        try await withReceipts { receipts in
            let scanner = ScriptedScanner(log: log, script: [TestData.snapshot(grants: [TestData.grant()])])
            let permissions = FakePermissions(log: log, failure: ActionError.commandFailed("tccutil fehlgeschlagen"))
            let outcome = await coordinator(permissions: permissions, scanner: scanner, receipts: receipts).reset(TestData.grant())
            #expect(outcome == .failed("tccutil fehlgeschlagen"))
            #expect(log.all == ["reset us.zoom.xos", "scan"])
        }
    }

    // MARK: Dienst für alle Apps zurücksetzen

    private static let orphan = TestData.grant("kTCCServiceAccessibility", client: TestData.app("ai.gone", presence: .missing), scope: .system)
    private static let installed = TestData.grant("kTCCServiceAccessibility", scope: .system)

    @Test func serviceResetIsDoneWhenTheOrphansAreGoneInTheFreshSnapshot() async throws {
        try await withReceipts { receipts in
            let reset = try #require(ServiceReset(service: "kTCCServiceAccessibility", in: TestData.snapshot(grants: [Self.orphan, Self.installed])))
            let scanner = ScriptedScanner(log: log, script: [TestData.snapshot()])
            let outcome = await coordinator(scanner: scanner, receipts: receipts).resetService(reset)
            #expect(outcome == .done)
            #expect(log.all == ["reset service kTCCServiceAccessibility", "scan"])
        }
    }

    @Test func serviceResetIsUnverifiedWhileAnOrphanIsStillThere() async throws {
        try await withReceipts { receipts in
            let reset = try #require(ServiceReset(service: "kTCCServiceAccessibility", in: TestData.snapshot(grants: [Self.orphan])))
            let scanner = ScriptedScanner(log: log, script: [TestData.snapshot(grants: [Self.orphan])])
            let outcome = await coordinator(scanner: scanner, receipts: receipts).resetService(reset)
            #expect(outcome == .doneButUnverified(
                "Berechtigungen entfernter Apps sind noch eingetragen.",
                settingsURL: PermissionCatalog.service(for: "kTCCServiceAccessibility").settingsURL
            ))
        }
    }

    @Test func missingFreshSnapshotLeavesTheActionUnverified() async throws {
        try await withReceipts { receipts in
            let outcome = await coordinator(scanner: ScriptedScanner(log: log, script: [nil]), receipts: receipts)
                .reset(TestData.grant())
            #expect(outcome == .doneButUnverified("Überprüfung ausstehend"))
        }
    }

    /// Die Frist läuft auf der injizierten Uhr – ohne echte Wartezeit.
    @Test(.timeLimit(.minutes(1))) func verificationTimesOut() async throws {
        try await withReceipts { receipts in
            let timeoutClock = TestClock()
            let coordinator = coordinator(scanner: ScriptedScanner(log: log, hang: true), receipts: receipts,
                                          timeout: .seconds(30), timeoutClock: timeoutClock)
            let outcome = Task { await coordinator.reset(TestData.grant()) }
            await timeoutClock.waitForSleeper(until: .at(.seconds(30)))
            timeoutClock.advance(by: .seconds(30))
            #expect(await outcome.value == .doneButUnverified("Überprüfung ausstehend"))
        }
    }

    // MARK: Fehler mit Wirkung

    /// Ein gemeldeter Fehler (z. B. XPC-Zeitüberschreitung), obwohl die Änderung im neuen Scan wirksam ist.
    @Test func failedActionWhoseEffectIsVisibleIsDoneButUnverified() async throws {
        try await withReceipts { receipts in
            let effective = "Fehler gemeldet, die Änderung ist aber wirksam."
            let item = TestData.item("com.vendor.agent", isEnabled: false)
            let scanner = ScriptedScanner(log: log, script: [TestData.snapshot(items: [item])])
            let coordinator = coordinator(
                permissions: FakePermissions(log: log, failure: FakeFailure()),
                autostart: FakeAutostart(log: log, failure: FakeFailure()),
                scanner: scanner, receipts: receipts
            )
            #expect(await coordinator.reset(TestData.grant()) == .doneButUnverified(effective))
            #expect(await coordinator.setEnabled(item, false) == .doneButUnverified(effective))
        }
    }

    @Test func failedRemoveWhoseEffectIsVisibleMentionsTheMissingReceipt() async throws {
        try await withReceipts { receipts in
            let autostart = FakeAutostart(log: log, failure: FakeFailure())
            let outcome = await coordinator(autostart: autostart, scanner: ScriptedScanner(log: log), receipts: receipts)
                .remove(TestData.item("com.vendor.agent"))
            #expect(outcome == .doneButUnverified(
                "Fehler gemeldet, die Änderung ist aber wirksam. Kein Wiederherstellungsbeleg vorhanden."
            ))
            let stored = try await receipts.receipts()
            #expect(stored.isEmpty)
        }
    }

    @Test func failedRestoreWhoseEffectIsVisibleKeepsTheReceipt() async throws {
        try await withReceipts { receipts in
            let entry = try await receipts.add(Self.receipt, label: "Agent", removedAt: TestData.date)
            let restored = TestData.snapshot(items: [TestData.item("com.vendor.agent")])
            let autostart = FakeAutostart(log: log, failure: FakeFailure())
            let outcome = await coordinator(autostart: autostart, scanner: ScriptedScanner(log: log, script: [restored]),
                                            receipts: receipts).restore(receiptID: entry.id)
            #expect(outcome == .doneButUnverified("Fehler gemeldet, die Änderung ist aber wirksam."))
            #expect(try await receipts.receipts() == [entry])
        }
    }

    /// Ohne verlässlichen Neu-Scan (ausgeblieben oder Quelle gescheitert) bleibt es beim Fehler.
    @Test func failedActionWithoutReliableRescanStaysFailed() async throws {
        try await withReceipts { receipts in
            let grant = TestData.grant()
            let failedSource = TestData.snapshot(errors: [SourceError(source: grant.source, message: "x")])
            let permissions = FakePermissions(log: log, failure: FakeFailure())
            for script in [[nil], [failedSource]] as [[Snapshot?]] {
                let outcome = await coordinator(permissions: permissions, scanner: ScriptedScanner(log: log, script: script),
                                                receipts: receipts).reset(grant)
                #expect(outcome == .failed("Befehl fehlgeschlagen"))
            }
        }
    }

    // MARK: Aktivieren/Deaktivieren

    @Test func setEnabledIsVerifiedAgainstTheFreshItem() async throws {
        try await withReceipts { receipts in
            let item = TestData.item("com.vendor.agent", isEnabled: true)
            let disabled = TestData.item("com.vendor.agent", isEnabled: false)
            let scanner = ScriptedScanner(log: log, script: [TestData.snapshot(items: [disabled]), TestData.snapshot(items: [item])])
            let coordinator = coordinator(scanner: scanner, receipts: receipts)
            #expect(await coordinator.setEnabled(item, false) == .done)
            #expect(await coordinator.setEnabled(item, false)
                == .doneButUnverified("Die Änderung ist im neuen Scan noch nicht zu sehen."))
        }
    }

    @Test func twoConcurrentActionsRunOneAfterTheOther() async throws {
        try await withReceipts { receipts in
            let gate = Gate()
            let autostart = FakeAutostart(log: log, gate: gate)
            let coordinator = coordinator(autostart: autostart, scanner: ScriptedScanner(log: log), receipts: receipts)

            let first = Task { await coordinator.setEnabled(TestData.item("first"), false) }
            try await autostart.started.wait()
            let second = Task { await coordinator.setEnabled(TestData.item("second"), false) }
            for _ in 0..<50 { await Task.yield() }
            #expect(log.all == ["begin first"])

            gate.open()
            try await autostart.started.wait()
            gate.open()
            _ = await (first.value, second.value)
            #expect(log.all == ["begin first", "end first", "scan", "begin second", "end second", "scan"])
        }
    }

    // MARK: Leeren vor dem Beenden

    /// Beenden während „Entfernen“: `drain()` wartet, bis die Aktion samt Beleg fertig ist, kürzt aber die
    /// Wirkungsprüfung ab (der Scan bliebe hier ganz aus, die Frist liefe nie ab).
    @Test(.timeLimit(.minutes(1))) func drainWaitsForTheRunningRemoveAndItsReceipt() async throws {
        try await withReceipts { receipts in
            let gate = Gate()
            let autostart = FakeAutostart(log: log, gate: gate)
            let coordinator = coordinator(autostart: autostart, scanner: ScriptedScanner(log: log, hang: true),
                                          receipts: receipts, timeout: .seconds(3600))
            let outcome = Task { await coordinator.remove(TestData.item("com.vendor.agent")) }
            try await autostart.started.wait()

            let drained = Mutex(false)
            let drain = Task {
                await coordinator.drain()
                drained.withLock { $0 = true }
            }
            for _ in 0..<50 { await Task.yield() }
            #expect(drained.withLock { $0 } == false)

            gate.open()
            await drain.value
            #expect(try await receipts.receipts().map(\.receipt) == [Self.receipt])
            #expect(await outcome.value == .doneButUnverified("Überprüfung ausstehend"))
        }
    }

    /// Auch eingereihte, noch nicht begonnene Aktionen laufen vor dem Ende von `drain()` vollständig.
    @Test(.timeLimit(.minutes(1))) func drainAlsoWaitsForQueuedActions() async throws {
        try await withReceipts { receipts in
            let gate = Gate()
            let autostart = FakeAutostart(log: log, gate: gate)
            let coordinator = coordinator(autostart: autostart, scanner: ScriptedScanner(log: log), receipts: receipts)
            let first = Task { await coordinator.setEnabled(TestData.item("first"), false) }
            try await autostart.started.wait()
            let second = Task { await coordinator.setEnabled(TestData.item("second"), false) }
            for _ in 0..<50 { await Task.yield() }

            let drain = Task { await coordinator.drain() }
            gate.open()
            try await autostart.started.wait()
            gate.open()
            await drain.value
            #expect(log.all.filter { $0.hasPrefix("end") } == ["end first", "end second"])
            _ = await (first.value, second.value)
        }
    }

    @Test func drainWithoutActionsReturnsAtOnce() async throws {
        try await withReceipts { receipts in
            await coordinator(scanner: ScriptedScanner(log: log), receipts: receipts).drain()
            #expect(log.all.isEmpty)
        }
    }

    @Test func failedSetEnabledStillRescans() async throws {
        try await withReceipts { receipts in
            let autostart = FakeAutostart(log: log, failure: FakeFailure())
            let outcome = await coordinator(autostart: autostart, scanner: ScriptedScanner(log: log), receipts: receipts)
                .setEnabled(TestData.item("x"), true)
            #expect(outcome == .failed("Befehl fehlgeschlagen"))
            #expect(log.all == ["begin x", "end x", "scan"])
        }
    }

    @Test func policyViolationIsReportedReadably() async throws {
        try await withReceipts { receipts in
            let autostart = FakeAutostart(log: log, failure: ActionError.notAllowed(.nonAquaSession))
            let outcome = await coordinator(autostart: autostart, scanner: ScriptedScanner(log: log), receipts: receipts)
                .setEnabled(TestData.item("x"), true)
            #expect(outcome == .failed("Läuft nicht in der Benutzersitzung – Änderung hier nicht möglich"))
        }
    }

    // MARK: Entfernen und Wiederherstellen

    @Test func removeStoresAReceiptAndVerifiesTheItemIsGone() async throws {
        try await withReceipts { receipts in
            let item = TestData.item("com.vendor.agent")
            let coordinator = coordinator(scanner: ScriptedScanner(log: log), receipts: receipts)

            #expect(await coordinator.remove(item) == .done)

            let stored = try await receipts.receipts()
            #expect(stored.map(\.receipt) == [Self.receipt])
            #expect(stored.first?.label == "com.vendor.agent" && stored.first?.removedAt == clock.now)
        }
    }

    @Test func removeIsUnverifiedWhileTheItemIsStillListed() async throws {
        try await withReceipts { receipts in
            let item = TestData.item("com.vendor.agent")
            let scanner = ScriptedScanner(log: log, script: [TestData.snapshot(items: [item])])
            #expect(await coordinator(scanner: scanner, receipts: receipts).remove(item)
                == .doneButUnverified("Der Eintrag ist im neuen Scan noch vorhanden."))
            let stored = try await receipts.receipts()
            #expect(stored.count == 1)
        }
    }

    @Test func failedRemoveStoresNoReceipt() async throws {
        try await withReceipts { receipts in
            let autostart = FakeAutostart(log: log, failure: FakeFailure())
            let stillListed = ScriptedScanner(log: log, script: [TestData.snapshot(items: [TestData.item()])])
            let outcome = await coordinator(autostart: autostart, scanner: stillListed, receipts: receipts)
                .remove(TestData.item())
            #expect(outcome == .failed("Befehl fehlgeschlagen"))
            let stored = try await receipts.receipts()
            #expect(stored.isEmpty)
            #expect(log.all.last == "scan")
        }
    }

    @Test func restoreRemovesTheReceiptAndVerifiesTheItemIsBack() async throws {
        try await withReceipts { receipts in
            let entry = try await receipts.add(Self.receipt, label: "Agent", removedAt: TestData.date)
            let restored = TestData.snapshot(items: [TestData.item("com.vendor.agent")])
            let coordinator = coordinator(scanner: ScriptedScanner(log: log, script: [restored]), receipts: receipts)

            #expect(await coordinator.restore(receiptID: entry.id) == .done)
            #expect(try await receipts.receipts().isEmpty)
            #expect(log.all == ["restore com.vendor.agent", "scan"])
        }
    }

    @Test func restoreIsUnverifiedWhenTheItemIsNotBackYet() async throws {
        try await withReceipts { receipts in
            let entry = try await receipts.add(Self.receipt, label: "Agent", removedAt: TestData.date)
            #expect(await coordinator(scanner: ScriptedScanner(log: log), receipts: receipts).restore(receiptID: entry.id)
                == .doneButUnverified("Wiederhergestellt, aber im neuen Scan noch nicht zu sehen."))
            #expect(try await receipts.receipts().isEmpty)
        }
    }

    @Test func supersededBackupFailsAndKeepsTheReceipt() async throws {
        try await withReceipts { receipts in
            let entry = try await receipts.add(Self.receipt, label: "Agent", removedAt: TestData.date)
            let superseded = BackupError.superseded(Self.receipt.backupPath)
            let autostart = FakeAutostart(log: log, failure: superseded)
            let outcome = await coordinator(autostart: autostart, scanner: ScriptedScanner(log: log), receipts: receipts)
                .restore(receiptID: entry.id)
            #expect(outcome == .failed(superseded.readableDescription))
            #expect(try await receipts.receipts() == [entry])
            #expect(log.all == ["restore com.vendor.agent", "scan"])
        }
    }

    @Test func unknownReceiptFails() async throws {
        try await withReceipts { receipts in
            let outcome = await coordinator(scanner: ScriptedScanner(log: log), receipts: receipts).restore(receiptID: UUID())
            #expect(outcome == .failed("Der Wiederherstellungsbeleg wurde nicht gefunden."))
        }
    }

    @Test func cancellationIsReportedReadably() {
        #expect(ActionCoordinator.message(for: CancellationError())
            == "Die Aktion wurde abgebrochen – ihr Ergebnis ist unbekannt.")
    }

    // MARK: Sicherheit

    private func securitySnapshot(_ facts: SecurityFacts, errors: [SourceError] = []) -> Snapshot {
        var snapshot = TestData.snapshot(errors: errors)
        snapshot.securityChecks = [TestData.evaluatedCheck(facts)]
        return snapshot
    }

    @Test func securityActionIsConfirmedByTheNextScan() async throws {
        try await withReceipts { receipts in
            let scanner = ScriptedScanner(log: log, script: [securitySnapshot(TestData.firewallOn)])
            let outcome = await coordinator(scanner: scanner, receipts: receipts).perform(.enableStealthMode)
            #expect(outcome == .done)
            #expect(log.all == ["security enableStealthMode", "security done enableStealthMode", "scan"])
        }
    }

    @Test func securityActionWithoutEffectIsUnverified() async throws {
        try await withReceipts { receipts in
            let scanner = ScriptedScanner(log: log, script: [securitySnapshot(TestData.stealthOff)])
            let outcome = await coordinator(scanner: scanner, receipts: receipts).perform(.enableStealthMode)
            #expect(outcome == SecurityActionVerification.unconfirmed(.enableStealthMode))
        }
    }

    @Test func securityActionIsPendingWhenTheSecuritySourceFailed() async throws {
        try await withReceipts { receipts in
            let failed = securitySnapshot(TestData.firewallOn, errors: [SourceError(source: .securityPosture, message: "x")])
            let outcome = await coordinator(scanner: ScriptedScanner(log: log, script: [failed]), receipts: receipts)
                .perform(.enableFirewall)
            #expect(outcome == .doneButUnverified(ActionCoordinator.pendingVerification))
        }
    }

    @Test func searchIsConfirmedOnlyByACheckAfterItsStart() async throws {
        try await withReceipts { receipts in
            let later = securitySnapshot(.pendingUpdates(updates: [], lastCheck: clock.now + 1))
            let laterOutcome = await coordinator(scanner: ScriptedScanner(log: log, script: [later]), receipts: receipts)
                .perform(.checkForUpdates)
            #expect(laterOutcome == .done)

            let earlier = securitySnapshot(.pendingUpdates(updates: [], lastCheck: clock.now - 1))
            let earlierOutcome = await coordinator(scanner: ScriptedScanner(log: log, script: [earlier]), receipts: receipts)
                .perform(.checkForUpdates)
            #expect(earlierOutcome == SecurityActionVerification.unconfirmed(.checkForUpdates))
        }
    }

    @Test func failedSecurityActionReportsTheReadableError() async throws {
        try await withReceipts { receipts in
            let scanner = ScriptedScanner(log: log, script: [securitySnapshot(TestData.firewallOff)])
            let security = FakeSecurity(log: log, failure: ActionError.commandFailed("socketfilterfw fehlgeschlagen"))
            let outcome = await coordinator(security: security, scanner: scanner, receipts: receipts).perform(.enableFirewall)
            #expect(outcome == .failed("socketfilterfw fehlgeschlagen"))
            #expect(log.all == ["security enableFirewall", "security done enableFirewall", "scan"])
        }
    }

    @Test func failedSecurityActionThatWorkedAnywayIsReportedHonestly() async throws {
        try await withReceipts { receipts in
            let scanner = ScriptedScanner(log: log, script: [securitySnapshot(TestData.firewallOn)])
            let outcome = await coordinator(security: FakeSecurity(log: log, failure: FakeFailure()), scanner: scanner, receipts: receipts)
                .perform(.enableFirewall)
            #expect(outcome == .doneButUnverified(ActionCoordinator.effectiveDespiteFailure))
        }
    }

    /// Ein ohnehin aktuelles XProtect (grüne Ampel) ist nach einem Fehler keine Wirkung der Aktion.
    @Test func failedXProtectUpdateIsNotRescuedByAGreenLight() async throws {
        try await withReceipts { receipts in
            var snapshot = TestData.snapshot()
            snapshot.securityChecks = [TestData.evaluatedCheck(.xprotect(version: "1", installedAt: clock.now - 3_600), now: clock.now)]
            #expect(snapshot.securityChecks.first?.state == .good)
            let security = FakeSecurity(log: log, failure: ActionError.commandFailed("xprotect fehlgeschlagen"))
            let outcome = await coordinator(security: security, scanner: ScriptedScanner(log: log, script: [snapshot]), receipts: receipts)
                .perform(.updateXProtect)
            #expect(outcome == .failed("xprotect fehlgeschlagen"))
        }
    }

    @Test func failedXProtectUpdateThatInstalledAnywayIsReportedHonestly() async throws {
        try await withReceipts { receipts in
            let snapshot = securitySnapshot(.xprotect(version: "2", installedAt: clock.now + 1))
            let outcome = await coordinator(security: FakeSecurity(log: log, failure: FakeFailure()),
                                            scanner: ScriptedScanner(log: log, script: [snapshot]), receipts: receipts)
                .perform(.updateXProtect)
            #expect(outcome == .doneButUnverified(ActionCoordinator.effectiveDespiteFailure))
        }
    }

    @Test func failedSearchThatHappenedAnywaySaysSo() async throws {
        try await withReceipts { receipts in
            let snapshot = securitySnapshot(.pendingUpdates(updates: [], lastCheck: clock.now + 1))
            let outcome = await coordinator(security: FakeSecurity(log: log, failure: FakeFailure()),
                                            scanner: ScriptedScanner(log: log, script: [snapshot]), receipts: receipts)
                .perform(.checkForUpdates)
            #expect(outcome == .doneButUnverified("Fehler gemeldet, die Suche ist aber erfolgt."))
        }
    }

    /// Beenden während „Jetzt suchen“: Die lesende Suche wird abgebrochen (der Befehl beendet), statt das Beenden bis
    /// zu 3 min aufzuhalten.
    @Test(.timeLimit(.minutes(1))) func drainCancelsARunningSearch() async throws {
        try await withReceipts { receipts in
            let runner = BlockingRunner()
            let coordinator = coordinator(security: SecurityActions(privileged: UnusedHelper(), runner: runner),
                                          scanner: ScriptedScanner(log: log, hang: true), receipts: receipts,
                                          timeout: .seconds(3600))
            let outcome = Task { await coordinator.perform(.checkForUpdates) }
            try await runner.started.wait()

            await coordinator.drain()
            #expect(runner.wasCancelled)
            #expect(await outcome.value == .failed("Die Aktion wurde abgebrochen – ihr Ergebnis ist unbekannt."))
        }
    }

    /// Eine nach `drain()` eingereihte Suche beginnt gar nicht erst.
    @Test(.timeLimit(.minutes(1))) func searchQueuedAfterDrainDoesNotStart() async throws {
        try await withReceipts { receipts in
            let coordinator = coordinator(scanner: ScriptedScanner(log: log), receipts: receipts)
            await coordinator.drain()
            let outcome = await coordinator.perform(.checkForUpdates)
            #expect(outcome == .failed("Die Aktion wurde abgebrochen – ihr Ergebnis ist unbekannt."))
            #expect(!log.all.contains("security checkForUpdates"))
        }
    }

    /// Eingreifende Aktionen laufen beim Beenden weiterhin vollständig durch.
    @Test(.timeLimit(.minutes(1))) func drainLetsARunningHardeningFinish() async throws {
        try await withReceipts { receipts in
            let gate = Gate()
            let security = FakeSecurity(log: log, gate: gate)
            let coordinator = coordinator(security: security, scanner: ScriptedScanner(log: log, hang: true),
                                          receipts: receipts, timeout: .seconds(3600))
            let outcome = Task { await coordinator.perform(.enableFirewall) }
            try await security.started.wait()

            let drained = Mutex(false)
            let drain = Task {
                await coordinator.drain()
                drained.withLock { $0 = true }
            }
            for _ in 0..<50 { await Task.yield() }
            #expect(drained.withLock { $0 } == false)

            gate.open()
            await drain.value
            #expect(log.all.contains("security done enableFirewall"))
            #expect(await outcome.value == .doneButUnverified("Überprüfung ausstehend"))
        }
    }

    // MARK: Entfernen (v3)

    /// Ohne angebundenen Papierkorb (Vorgabe) wird nie gelöscht – auch nicht versehentlich in Tests.
    @Test func defaultTrashNeverDeletes() async throws {
        try await withReceipts { receipts in
            let coordinator = ActionCoordinator(
                permissions: FakePermissions(log: log), autostart: FakeAutostart(log: log), security: FakeSecurity(log: log),
                receipts: receipts, scanner: ScriptedScanner(log: log), clock: TestClock()
            )
            let file = LeftoverCandidate(path: "/Users/test/Library/Caches/com.example.tool", kind: .caches, confidence: .safe)
            let report = await coordinator.performRemoval(RemovalPlan(app: nil, grants: [TestData.grant()], autostartItems: [], files: [file]))
            #expect(report.entries.map(\.result) == [.skipped(UnavailableTrash.reason), .skipped(UnavailableTrash.reason)])
            #expect(log.all == ["scan"], "nichts verändert, danach in jedem Fall ein Scan")
        }
    }

    @Test(.timeLimit(.minutes(1))) func removalWaitsForThePreviousAction() async throws {
        try await withReceipts { receipts in
            let gate = Gate()
            let autostart = FakeAutostart(log: log, gate: gate)
            let coordinator = coordinator(autostart: autostart, scanner: ScriptedScanner(log: log), receipts: receipts)
            async let first = coordinator.setEnabled(TestData.item("first"), false)
            try await autostart.started.wait()
            async let removal = coordinator.performRemoval(RemovalPlan(app: nil, grants: [TestData.grant()], autostartItems: [], files: []))
            for _ in 0..<50 { await Task.yield() }
            gate.open()
            let (_, report) = await (first, removal)
            #expect(log.all == ["begin first", "end first", "scan", "reset us.zoom.xos", "scan"])
            #expect(report.entries.map(\.result) == [.done])
        }
    }

    /// Der Bericht geht an `onExecuted`, sobald der Eingriff erledigt ist – auch wenn der Prüfscan noch hängt.
    @Test(.timeLimit(.minutes(1))) func removalReportsExecutionBeforeWaitingForTheScan() async throws {
        try await withReceipts { receipts in
            let executed = Gate()
            let reported = Mutex<RemovalReport?>(nil)
            let coordinator = coordinator(scanner: ScriptedScanner(log: log, hang: true), receipts: receipts,
                                          timeout: .seconds(3600))
            let plan = RemovalPlan(app: nil, grants: [TestData.grant()], autostartItems: [], files: [])
            let removal = Task {
                await coordinator.performRemoval(plan) { report in
                    reported.withLock { $0 = report }
                    executed.open()
                }
            }
            try await executed.wait()
            #expect(reported.withLock { $0 }?.entries.map(\.result) == [.done])

            await coordinator.drain()
            #expect(await removal.value == reported.withLock { $0 })
        }
    }

    /// Review I1: Aufräumen scannt vor dem Papierkorb neu; was jetzt einer installierten App gehört, bleibt liegen.
    @Test func cleanupChecksAFreshScanBeforeTheTrash() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let cache = try fixture.folder(fixture.userLibrary("Caches/com.example.tool"))
                let file = LeftoverCandidate(path: cache, kind: .caches, confidence: .safe, identity: FileIdentity.of(cache))
                let installed = TestData.appSnapshot([TestData.installedApp("Tool", bundleID: "com.example.tool")])
                let coordinator = coordinator(scanner: ScriptedScanner(log: log, script: [installed]), receipts: receipts,
                                              trash: FakeTrash(log: log), removalGuard: RemovalGuard(layout: fixture.layout))
                let plan = RemovalPlan(app: nil, grants: [], autostartItems: [], files: [file],
                                       orphanClaims: [cache: OrphanClaim(identifiers: ["com.example.tool"])])
                let report = await coordinator.performRemoval(plan)
                #expect(report.entries.map(\.result) == [.skipped(OrphanRecheck.ownedReason(by: "Tool"))])
                #expect(log.all == ["scan", "scan"], "Abgleich vorher, Prüfscan danach – kein Papierkorb")
            }
        }
    }

    /// #100: Auch das Entfernen einer App scannt vor dem Papierkorb neu; ein Gruppencontainer, den inzwischen eine weitere
    /// App desselben Teams mitbenutzt, bleibt liegen.
    @Test func uninstallChecksAFreshScanBeforeTheTrash() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let app = TestData.installedApp("Tool", bundleID: "com.example.tool")
                let team = try #require(app.signing.teamID)
                let container = try fixture.folder(fixture.userLibrary("Group Containers/\(team).com.example.shared"))
                let file = LeftoverCandidate(path: container, kind: .groupContainer, confidence: .safe, identity: FileIdentity.of(container))
                let mate = TestData.installedApp("Mate", bundleID: "com.example.mate")
                let coordinator = coordinator(scanner: ScriptedScanner(log: log, script: [TestData.appSnapshot([app, mate])]),
                                              receipts: receipts, trash: FakeTrash(log: log), removalGuard: RemovalGuard(layout: fixture.layout))
                let report = await coordinator.performRemoval(RemovalPlan(app: app, grants: [], autostartItems: [], files: [file]))
                #expect(report.entries.map(\.result) == [.skipped(AppRemovalRecheck.sharedLeftoverReason("Team-ID auch bei: Mate"))])
                #expect(log.all == ["scan", "scan"], "Abgleich vorher, Prüfscan danach – kein Papierkorb")
            }
        }
    }

    /// #100 mit #102: Hängt der Abgleich vor dem Papierkorb eines reinen Datei-Plans, kürzt der Abbruch ihn ab – nichts
    /// landet im Papierkorb, der Bericht nennt den Abbruch.
    @Test(.timeLimit(.minutes(1))) func cancelCutsShortTheOwnershipScanOfAFilesOnlyUninstall() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let app = TestData.installedApp("Tool", bundleID: "com.example.tool")
                let cache = try fixture.folder(fixture.userLibrary("Caches/com.example.tool"))
                let file = LeftoverCandidate(path: cache, kind: .caches, confidence: .safe, identity: FileIdentity.of(cache))
                let coordinator = coordinator(scanner: ScriptedScanner(log: log, hang: true), receipts: receipts,
                                              trash: FakeTrash(log: log), removalGuard: RemovalGuard(layout: fixture.layout),
                                              timeout: .seconds(3600))
                let plan = RemovalPlan(app: app, grants: [], autostartItems: [], files: [file])
                let removal = Task { await coordinator.performRemoval(plan) }
                while !log.all.contains("scan") { await Task.yield() }

                removal.cancel()
                let report = await removal.value

                #expect(report == .skipping(plan, reason: RemovalExecutor.abortedReason))
                #expect(log.all == ["scan"], "kein Papierkorb, kein Prüfscan danach")
            }
        }
    }

    /// #100: Nach `drain()` (Beenden) entfällt auch der Abgleichsscan – ein App-Plan beginnt dann keinen Eingriff mehr und
    /// nennt den fehlenden Stand als Grund.
    @Test func drainedCoordinatorLeavesAnUninstallUntouched() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let app = TestData.installedApp("Tool", bundleID: "com.example.tool")
                let cache = try fixture.folder(fixture.userLibrary("Caches/com.example.tool"))
                let file = LeftoverCandidate(path: cache, kind: .caches, confidence: .safe, identity: FileIdentity.of(cache))
                let coordinator = coordinator(scanner: ScriptedScanner(log: log), receipts: receipts, trash: FakeTrash(log: log),
                                              removalGuard: RemovalGuard(layout: fixture.layout))
                await coordinator.drain()
                let plan = RemovalPlan(app: app, grants: [], autostartItems: [], files: [file])
                let report = await coordinator.performRemoval(plan)
                #expect(report == .skipping(plan, reason: OrphanRecheck.unavailableReason))
                #expect(log.all.isEmpty, "weder Scan noch Papierkorb")
            }
        }
    }

    /// Beenden während des Papierkorb-Schritts: Der Eingriff läuft zu Ende, nur der Prüfscan entfällt.
    @Test(.timeLimit(.minutes(1))) func drainLetsARunningRemovalFinish() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let cache = try fixture.folder(fixture.userLibrary("Caches/com.example.tool"))
                let file = LeftoverCandidate(path: cache, kind: .caches, confidence: .safe, identity: FileIdentity.of(cache))
                let gate = Gate()
                let trash = FakeTrash(log: log, gate: gate)
                let coordinator = coordinator(scanner: ScriptedScanner(log: log, hang: true), receipts: receipts, trash: trash,
                                              removalGuard: RemovalGuard(layout: fixture.layout), timeout: .seconds(3600))
                let report = Task { await coordinator.performRemoval(RemovalPlan(app: nil, grants: [], autostartItems: [], files: [file])) }
                try await trash.started.wait()

                let drained = Mutex(false)
                let drain = Task {
                    await coordinator.drain()
                    drained.withLock { $0 = true }
                }
                for _ in 0..<50 { await Task.yield() }
                #expect(drained.withLock { $0 } == false)

                gate.open()
                await drain.value
                #expect(log.all.contains("trash done"))
                #expect(await report.value.entries.map(\.result) == [.done])
            }
        }
    }

    /// Issue #102: Wird die Entfernung abgebrochen, während sie am Helper hängt („Neu installieren“), läuft der bereits
    /// gesendete Eingriff zu Ende – weitere Schritte und der Finder-Auftrag beginnen aber nicht mehr. Erledigtes bleibt
    /// samt Beleg im Bericht, nicht Begonnenes gilt als abgebrochen.
    @Test(.timeLimit(.minutes(1))) func cancelledRemovalStartsNoFurtherSteps() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let cache = try fixture.folder(fixture.userLibrary("Caches/com.example.tool"))
                let file = LeftoverCandidate(path: cache, kind: .caches, confidence: .safe, identity: FileIdentity.of(cache))
                let gate = Gate()
                let autostart = FakeAutostart(log: log, gate: gate)
                // Aufräumen: Der Abgleich vorab (erster Scan) lässt beide Autostart-Einträge verwaist.
                let scanner = ScriptedScanner(log: log, script: [TestData.appSnapshot([])])
                let coordinator = coordinator(autostart: autostart, scanner: scanner, receipts: receipts,
                                              trash: FakeTrash(log: log), removalGuard: RemovalGuard(layout: fixture.layout))
                let plan = RemovalPlan(app: nil, grants: [TestData.grant()],
                                       autostartItems: [TestData.item("first"), TestData.item("second")], files: [file])
                let removal = Task { await coordinator.performRemoval(plan) }
                try await autostart.started.wait()

                removal.cancel()
                // Zwei Freigaben: Begänne der zweite Eintrag doch, hinge der Test nicht, sondern schlüge fehl.
                gate.open()
                gate.open()
                let report = await removal.value

                #expect(log.all == ["scan", "reset us.zoom.xos", "remove first"],
                        "Kein Prüfscan danach – eine Aktion nach „Neu installieren“ soll nicht darauf warten")
                #expect(report.entries.map(\.result) == [
                    .done, .done, .skipped(RemovalExecutor.abortedReason), .skipped(RemovalExecutor.abortedReason),
                ])
                #expect(try await receipts.receipts().count == 1, "Der erledigte Schritt behält seinen Wiederherstellungsbeleg")
            }
        }
    }

    /// #97 mit #102: Hängt der Abgleich vor dem Zurücksetzen der Berechtigungen einer App, kürzt der Abbruch ihn ab –
    /// nichts wird zurückgesetzt, der Bericht nennt den Abbruch.
    @Test(.timeLimit(.minutes(1))) func cancelCutsShortTheOwnershipScanOfAnUninstall() async throws {
        try await withReceipts { receipts in
            let app = TestData.installedApp("Tool", bundleID: "com.example.tool")
            let coordinator = coordinator(scanner: ScriptedScanner(log: log, hang: true), receipts: receipts,
                                          timeout: .seconds(3600))
            let plan = RemovalPlan(app: app, grants: [TestData.grant(client: app.identity)], autostartItems: [], files: [])
            let removal = Task { await coordinator.performRemoval(plan) }
            while !log.all.contains("scan") { await Task.yield() }

            removal.cancel()
            let report = await removal.value

            #expect(report.entries.map(\.result) == [.skipped(RemovalExecutor.abortedReason)])
            #expect(log.all == ["scan"], "nichts zurückgesetzt, kein Prüfscan danach")
        }
    }

    /// Issue #102: Ein noch hinter einer anderen Aktion eingereihter Plan, der abgebrochen wird, beginnt gar nicht – keine
    /// Anfrage an Helper oder Finder, kein Prüfscan.
    @Test(.timeLimit(.minutes(1))) func cancelledQueuedRemovalDoesNothing() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let cache = try fixture.folder(fixture.userLibrary("Caches/com.example.tool"))
                let file = LeftoverCandidate(path: cache, kind: .caches, confidence: .safe, identity: FileIdentity.of(cache))
                let gate = Gate()
                let autostart = FakeAutostart(log: log, gate: gate)
                let coordinator = coordinator(autostart: autostart, scanner: ScriptedScanner(log: log), receipts: receipts,
                                              trash: FakeTrash(log: log), removalGuard: RemovalGuard(layout: fixture.layout))
                let plan = RemovalPlan(app: nil, grants: [TestData.grant()], autostartItems: [TestData.item("queued")],
                                       files: [file])
                let first = Task { await coordinator.setEnabled(TestData.item("first"), false) }
                try await autostart.started.wait()
                let removal = Task { await coordinator.performRemoval(plan) }
                for _ in 0..<50 { await Task.yield() }

                removal.cancel()
                gate.open()
                _ = await first.value

                #expect(await removal.value == .skipping(plan, reason: RemovalExecutor.abortedReason))
                #expect(log.all == ["begin first", "end first", "scan"], "nur die vorige Aktion samt ihrem Prüfscan")
            }
        }
    }

    // MARK: Prozess beenden

    private static let nodeProcess = RunningProcess(pid: 4242, uid: 501, executablePath: "/opt/homebrew/bin/node", startTime: 1)
    private static var terminationRequest: ProcessTerminationRequest {
        ProcessTerminationRequest(listener: TestData.listener(), processes: [nodeProcess])
    }

    private func terminate(
        _ reports: [ProcessTerminationReport], snapshot: Snapshot = TestData.networkSnapshot([]), force: Bool = false
    ) async throws -> ProcessTerminationResult {
        try await withReceipts { receipts in
            await coordinator(processTermination: FakeProcesses(log: log, reports: reports),
                              scanner: ScriptedScanner(log: log, script: [snapshot]), receipts: receipts)
                .terminate(Self.terminationRequest, force: force)
        }
    }

    @Test func terminationIsDoneWhenTheListenerIsGone() async throws {
        let result = try await terminate([ProcessTerminationReport(ended: [Self.nodeProcess])])
        #expect(result.outcome == .done && result.forceRequest == nil)
        #expect(result.report == ProcessTerminationReport(ended: [Self.nodeProcess]))
        #expect(log.all == ["term [4242]", "scan"])
    }

    @Test func survivorsOfSIGTERMOfferSIGKILL() async throws {
        let result = try await terminate([ProcessTerminationReport(stillRunning: [Self.nodeProcess])],
                                         snapshot: TestData.networkSnapshot([TestData.listener()]))
        #expect(result.outcome == .doneButUnverified("1 Prozess läuft noch."))
        #expect(result.forceRequest == ProcessTerminationRequest(listener: TestData.listener(), processes: [Self.nodeProcess]))
    }

    @Test func survivorsOfSIGKILLAreNotOfferedAgain() async throws {
        let result = try await terminate([ProcessTerminationReport(stillRunning: [Self.nodeProcess])], force: true)
        #expect(result.outcome == .doneButUnverified("1 Prozess läuft auch nach dem sofortigen Beenden noch."))
        #expect(result.forceRequest == nil)
        #expect(log.all == ["kill [4242]", "scan"])
    }

    @Test func severalSurvivorsAreCounted() async throws {
        let other = RunningProcess(pid: 4243, uid: 501, executablePath: "/opt/homebrew/bin/node", startTime: 1)
        let result = try await terminate([ProcessTerminationReport(stillRunning: [Self.nodeProcess, other])])
        #expect(result.outcome == .doneButUnverified("2 Prozesse laufen noch."))
    }

    @Test func restartedListenerIsUnverified() async throws {
        let result = try await terminate([ProcessTerminationReport(ended: [Self.nodeProcess])],
                                         snapshot: TestData.networkSnapshot([TestData.listener()]))
        #expect(result.outcome == .doneButUnverified(ActionCoordinator.listenerRestarted))
    }

    @Test func nothingTerminatedFailsWithTheFirstMessage() async throws {
        let failure = ProcessTerminationFailure(process: Self.nodeProcess, message: "Keine Berechtigung, Prozess 4242 zu beenden")
        let result = try await terminate([ProcessTerminationReport(failures: [failure])],
                                         snapshot: TestData.networkSnapshot([TestData.listener()]))
        #expect(result.outcome == .failed("Prozess nicht beendet: Keine Berechtigung, Prozess 4242 zu beenden"))
        #expect(result.report.failures == [failure])
    }

    /// Kein Prozess beendet: Fehlt der Lauscher im neuen Scan trotzdem, war das nicht die Aktion – es bleibt beim Fehler.
    @Test func nothingTerminatedStaysFailedWhenTheListenerHappensToBeGone() async throws {
        let failure = ProcessTerminationFailure(process: Self.nodeProcess, message: "Keine Berechtigung, Prozess 4242 zu beenden")
        let result = try await terminate([ProcessTerminationReport(failures: [failure])])
        #expect(result.outcome == .failed("Prozess nicht beendet: Keine Berechtigung, Prozess 4242 zu beenden"))
    }

    @Test func partialFailureIsAWarning() async throws {
        let root = RunningProcess(pid: 20, uid: 0, executablePath: "/opt/homebrew/bin/node", startTime: 1)
        let report = ProcessTerminationReport(ended: [Self.nodeProcess],
                                              failures: [ProcessTerminationFailure(process: root, message: "x")])
        let result = try await terminate([report], snapshot: TestData.networkSnapshot([TestData.listener()]))
        #expect(result.outcome == .doneButUnverified("Nicht alle Prozesse ließen sich beenden."))
    }

    /// Ohne Verdrahtung (`UnavailableProcessTermination`) bekommt kein Prozess ein Signal – belegt an einem eigenen
    /// Kindprozess (Leitplanke 5), der danach noch läuft.
    @Test(.timeLimit(.minutes(1))) func defaultTerminationNeverSignals() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let process = try #require(LibprocProcessInspector().process(child.processIdentifier))
        let request = ProcessTerminationRequest(listener: TestData.listener(), processes: [process])
        let result = try await withReceipts { receipts in
            await ActionCoordinator(
                permissions: FakePermissions(log: log), autostart: FakeAutostart(log: log), security: FakeSecurity(log: log),
                receipts: receipts, scanner: ScriptedScanner(log: log, script: [TestData.networkSnapshot([TestData.listener()])]),
                clock: TestClock()
            ).terminate(request, force: false)
        }
        #expect(result.outcome == .failed("Prozess nicht beendet: \(UnavailableProcessTermination.reason)"))
        #expect(LibprocProcessInspector().process(process.pid) == process)
    }

    /// Beenden läuft seriell wie jede Aktion: Der zweite Aufruf beginnt erst nach dem Prüfscan des ersten.
    @Test func terminationsAreQueued() async throws {
        try await withReceipts { receipts in
            let coordinator = coordinator(
                processTermination: FakeProcesses(log: log, reports: [ProcessTerminationReport(stillRunning: [Self.nodeProcess])]),
                scanner: ScriptedScanner(log: log, script: [TestData.networkSnapshot([TestData.listener()])]), receipts: receipts
            )
            let first = await coordinator.terminate(Self.terminationRequest, force: false)
            let forceRequest = try #require(first.forceRequest)
            _ = await coordinator.terminate(forceRequest, force: true)
            #expect(log.all == ["term [4242]", "scan", "kill [4242]", "scan"])
        }
    }
}

// MARK: - MonitoringEngine als ScanRequesting

/// Auslöser als einfacher Strom: `.launch` beim Start, `.manual` bei jeder Anforderung.
private final class StreamTriggers: ScanTriggering {
    private let stream: AsyncStream<ScanReason>
    private let continuation: AsyncStream<ScanReason>.Continuation

    init() { (stream, continuation) = AsyncStream<ScanReason>.makeStream() }

    func reasons() async -> AsyncStream<ScanReason> {
        continuation.yield(.launch)
        return stream
    }

    func requestScan() async { continuation.yield(.manual) }

    func requestScan(only sources: Set<SourceID>) async { continuation.yield(.sourceRefresh(sources)) }
}

private struct EmptySource: InventorySource {
    let id: SourceID = .launchd
    func collect() async throws -> InventoryContribution { InventoryContribution() }
}

@Suite struct MonitoringEngineScanRequestingTests {
    @Test func waitsForAScanThatStartedNotBeforeTheGivenDate() async throws {
        let dates = ManualClock()
        let engine = MonitoringEngine(
            coordinator: ScanCoordinator(sources: [EmptySource()], now: { dates.now }),
            store: try SwiftDataSnapshotStore.inMemory(),
            notifier: ChangeNotifier(notifier: RecordingNotifier(), clock: TestClock()),
            triggers: StreamTriggers(),
            now: { dates.now }
        )
        await engine.start()
        for await state in await engine.states() where state.lastCheckedAt != nil && !state.isScanning { break }

        dates.advance(by: 60)
        let snapshot = await engine.scan(startedNotBefore: dates.now)

        #expect(snapshot?.takenAt == dates.now)
        await engine.stop()
    }

    @Test func returnsNilWhenTheEngineStops() async throws {
        let dates = ManualClock()
        let engine = MonitoringEngine(
            coordinator: ScanCoordinator(sources: [EmptySource()], now: { dates.now }),
            store: try SwiftDataSnapshotStore.inMemory(),
            notifier: ChangeNotifier(notifier: RecordingNotifier(), clock: TestClock()),
            triggers: StreamTriggers(),
            now: { dates.now }
        )
        await engine.stop()
        #expect(await engine.scan(startedNotBefore: dates.now) == nil)
    }
}
