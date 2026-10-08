import Foundation
import ServiceManagement
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

// Nur Attrappen: Kein Test meldet echte Dienste ab, spricht den Finder an oder löscht etwas.

private final class Log: Sendable {
    private let entries = Mutex<[String]>([])
    func append(_ entry: String) { entries.withLock { $0.append(entry) } }
    var all: [String] { entries.withLock { $0 } }
}

/// Helper oder Login-Item: protokolliert das Abmelden; mit `fails` scheitert es. Der Status folgt wie bei
/// `SMAppService` dem Abmelden, sodass eine Wiederholung den schon abgemeldeten Dienst sieht.
private final class FakeService: DaemonService, AppServiceRegistration {
    struct Failure: LocalizedError {
        var errorDescription: String? { "launchd verweigert" }
    }

    private struct State {
        var status: SMAppService.Status
        var fails: Bool
        /// Status nach einem gescheiterten Abmelden (`nil`: unverändert).
        var statusAfterFailure: SMAppService.Status?
    }

    let name: String
    let log: Log
    private let state: Mutex<State>
    /// Läuft mitten in der Abmeldung (z. B. um sie anzuhalten).
    private let duringUnregister: @Sendable () async -> Void

    init(
        name: String, log: Log, status: SMAppService.Status = .enabled, fails: Bool = false,
        statusAfterFailure: SMAppService.Status? = nil, duringUnregister: @escaping @Sendable () async -> Void = {}
    ) {
        self.name = name
        self.log = log
        state = Mutex(State(status: status, fails: fails, statusAfterFailure: statusAfterFailure))
        self.duringUnregister = duringUnregister
    }

    var status: SMAppService.Status { state.withLock(\.status) }
    var fails: Bool {
        get { state.withLock(\.fails) }
        set { state.withLock { $0.fails = newValue } }
    }

    func register() throws { Issue.record("nicht erwartet") }
    func unregister() async throws {
        log.append("unregister \(name)")
        await duringUnregister()
        let failed = state.withLock { state in
            if state.fails {
                state.status = state.statusAfterFailure ?? state.status
                return true
            }
            state.status = .notRegistered
            return false
        }
        if failed { throw Failure() }
    }
}

private struct LoggingPermissions: PermissionResetting {
    struct Failure: LocalizedError {
        var errorDescription: String? { "tccutil verweigert" }
    }

    let log: Log
    var failing: Set<String> = []
    /// Läuft während jedes Resets (z. B. verspäteter Finder-Erfolg).
    var duringReset: @Sendable (PermissionGrant) -> Void = { _ in }
    func reset(_ grant: PermissionGrant) async throws {
        log.append("reset \(grant.service)")
        duringReset(grant)
        if failing.contains(grant.service) { throw Failure() }
    }
    func resetService(_ service: String) async throws { Issue.record("nicht erwartet") }
}

/// Papierkorb-Attrappe: ruft wie `FinderTrash` die letzte Prüfung je Kandidat, lässt bei `cancelled` alles liegen
/// (abgebrochene Passwortabfrage) – ohne etwas anzufassen.
private struct LoggingTrash: TrashPerforming {
    private final class Box: Sendable {
        let value: Mutex<[String: TrashItemOutcome]>
        let tracked = Mutex<[String]>([])
        init(_ value: [String: TrashItemOutcome]) { self.value = Mutex(value) }
    }

    let log: Log
    var permission: TrashPermission = .granted
    var cancelled = false
    /// Pfade, die der Auftrag liegen lässt (Teilabbruch), während die übrigen entsorgt werden.
    var remaining: Set<String> = []
    /// Nachweislich im Papierkorb liegende Originale je Pfad (`settledOutcome`) – vorab gesetzt, ergänzt um alles,
    /// was `moveToTrash` entsorgt, und per `restore` wieder herausnehmbar („Zurücklegen“).
    private let inTrash: Box

    init(
        log: Log, permission: TrashPermission = .granted, cancelled: Bool = false, remaining: Set<String> = [],
        settled: [String: TrashItemOutcome] = [:]
    ) {
        self.log = log
        self.permission = permission
        self.cancelled = cancelled
        self.remaining = remaining
        inTrash = Box(settled)
    }

    /// Der Finder entsorgt ein Original nachträglich (z. B. nach einer Zeitüberschreitung).
    func settleLate(_ path: String) { inTrash.value.withLock { $0[path] = .trashed } }

    func settledOutcome(of candidate: LeftoverCandidate) -> TrashItemOutcome? { inTrash.value.withLock { $0[candidate.path] } }

    func track(_ candidates: [LeftoverCandidate]) { inTrash.tracked.withLock { $0 += candidates.map(\.path) } }
    var tracked: [String] { inTrash.tracked.withLock { $0 } }

    /// Der Nutzer legt ein Original aus dem Papierkorb zurück.
    func restore(_ path: String) { _ = inTrash.value.withLock { $0.removeValue(forKey: path) } }

    func requestPermission() async -> TrashPermission {
        log.append("permission")
        return permission
    }

    func moveToTrash(
        _ candidates: [LeftoverCandidate], verifying verify: @escaping @Sendable (LeftoverCandidate) -> RemovalVerdict
    ) async -> TrashReport {
        log.append("trash \(candidates.count)")
        let outcomes = candidates.map { candidate -> (String, TrashItemOutcome) in
            if case .blocked(let reason) = verify(candidate) { return (candidate.path, .blocked(reason)) }
            let left = cancelled || remaining.contains(candidate.path)
            return (candidate.path, left ? .remaining("Abgebrochen (z. B. Passwortabfrage)") : .trashed)
        }
        for (path, outcome) in outcomes where outcome == .trashed { inTrash.value.withLock { $0[path] = outcome } }
        return TrashReport(outcomes: Dictionary(uniqueKeysWithValues: outcomes), failure: cancelled ? "Abgebrochen" : nil)
    }
}

/// Lässt `path` beim Auftrag liegen, legt es aber unmittelbar danach doch in den Papierkorb (verspäteter Finder-Erfolg
/// nach dem Bericht des Auftrags).
private struct LateAfterTrash: TrashPerforming {
    let base: LoggingTrash
    let path: String

    func requestPermission() async -> TrashPermission { await base.requestPermission() }
    func settledOutcome(of candidate: LeftoverCandidate) -> TrashItemOutcome? { base.settledOutcome(of: candidate) }
    func track(_ candidates: [LeftoverCandidate]) { base.track(candidates) }
    func moveToTrash(
        _ candidates: [LeftoverCandidate], verifying verify: @escaping @Sendable (LeftoverCandidate) -> RemovalVerdict
    ) async -> TrashReport {
        let report = await base.moveToTrash(candidates, verifying: verify)
        base.settleLate(path)
        return report
    }
}

@Suite struct SelfUninstallerTests {
    private let log = Log()

    private func uninstaller(
        _ fixture: LibraryFixture, trash: LoggingTrash? = nil, helperStatus: SMAppService.Status = .enabled,
        loginStatus: SMAppService.Status = .enabled, helperFails: Bool = false, loginFails: Bool = false,
        failingResets: Set<String> = []
    ) -> SelfUninstaller {
        uninstaller(
            fixture, trash: trash, helper: FakeService(name: "helper", log: log, status: helperStatus, fails: helperFails),
            loginItem: FakeService(name: "login", log: log, status: loginStatus, fails: loginFails), failingResets: failingResets
        )
    }

    private func uninstaller(
        _ fixture: LibraryFixture, trash: LoggingTrash? = nil, helper: FakeService, loginItem: FakeService,
        failingResets: Set<String> = []
    ) -> SelfUninstaller {
        SelfUninstaller(
            helper: helper, loginItem: loginItem, permissions: LoggingPermissions(log: log, failing: failingResets),
            trash: trash ?? LoggingTrash(log: log), removalGuard: RemovalGuard(layout: fixture.layout)
        )
    }

    private static let fullDiskAccess = "kTCCServiceSystemPolicyAllFiles"
    private static let automation = PermissionCatalog.automationServiceID

    /// Grantry in den Programmen samt Daten unter `~/Library/Application Support`, Kamera und Finder-Automation.
    private func plan(_ fixture: LibraryFixture, preferences: Bool = false) throws -> SelfUninstallPlan {
        let path = try fixture.app("Grantry", bundleID: "de.cstrube.Grantry")
        let data = try fixture.folder(fixture.userLibrary("Application Support/Grantry"))
        let app = TestData.installedApp("Grantry", bundleID: "de.cstrube.Grantry", path: path)
        var files = [candidate(path, kind: .appBundle), candidate(data, kind: .applicationSupport)]
        if preferences {
            files.append(candidate(try fixture.file(fixture.userLibrary("Preferences/de.cstrube.Grantry.plist")), kind: .preferences))
        }
        return SelfUninstallPlan(
            files: files,
            grants: [TestData.grant(PermissionCatalog.automationServiceID, client: app.identity),
                     TestData.grant("kTCCServiceSystemPolicyAllFiles", client: app.identity)]
        )
    }

    private func candidate(_ path: String, kind: LeftoverKind) -> LeftoverCandidate {
        LeftoverCandidate(path: path, kind: kind, confidence: .safe, identity: FileIdentity.of(path))
    }

    @Test func unregistersAndResetsBeforeTrashingAndAutomationLast() async throws {
        try await LibraryFixture.with { fixture in
            let report = await uninstaller(fixture).run(try plan(fixture))
            #expect(log.all == [
                "permission", "unregister helper", "unregister login", "reset kTCCServiceSystemPolicyAllFiles", "trash 2",
                "reset kTCCServiceAppleEvents",
            ])
            #expect(report.appRemoved)
            #expect(report.entries.allSatisfy { $0.result == .done })
        }
    }

    @Test func withoutFinderAutomationNothingChanges() async throws {
        try await LibraryFixture.with { fixture in
            let report = await uninstaller(fixture, trash: LoggingTrash(log: log, permission: .denied)).run(try plan(fixture))
            #expect(log.all == ["permission"])
            #expect(report.automationDenied)
            #expect(!report.appRemoved)
            #expect(report.entries.count == 6)
            #expect(report.entries.allSatisfy { $0.result == .skipped(RemovalExecutor.automationDeniedReason) })
        }
    }

    /// Abgebrochene Passwortabfrage: Grantry bleibt, und mit ihr die Finder-Freigabe für den erneuten Versuch (#140).
    @Test func cancelledPasswordPromptKeepsTheAppAndItsFinderAutomation() async throws {
        try await LibraryFixture.with { fixture in
            let plan = try plan(fixture)
            let report = await uninstaller(fixture, trash: LoggingTrash(log: log, cancelled: true)).run(plan)
            #expect(!report.appRemoved)
            #expect(report.entries.first { $0.subject == .helper }?.result == .done)
            #expect(!log.all.contains("reset \(Self.automation)"))
            #expect(report.blockedBy == .file(plan.files[0]))
            #expect(report.entries.first { $0.subject == .grant(plan.grants[0]) }?.result == .skipped(SelfUninstaller.blockedReason))
        }
    }

    /// Scheitert die Abmeldung des Helpers, bleibt alles Weitere unangetastet: Das Bundle enthält seine launchd-Plist,
    /// ohne die er sich nicht mehr abmelden ließe (#156, #140).
    @Test func failedHelperUnregistrationStopsBeforePermissionsAndFiles() async throws {
        try await LibraryFixture.with { fixture in
            let plan = try plan(fixture)
            let report = await uninstaller(fixture, helperFails: true).run(plan)
            #expect(log.all == ["permission", "unregister helper"])
            #expect(!report.appRemoved)
            #expect(report.blockedBy == .helper)
            #expect(report.entries.first { $0.subject == .helper }?.result == .failed("launchd verweigert"))
            let remaining = report.entries.filter { $0.subject != .helper }
            #expect(remaining.count == 5)
            #expect(remaining.allSatisfy { $0.result == .skipped(SelfUninstaller.blockedReason) })
        }
    }

    /// Auch ein nicht abmeldbares Login-Item hält an – der Helper ist dann schon abgemeldet, was der Bericht zeigt.
    @Test func failedLoginItemUnregistrationStopsToo() async throws {
        try await LibraryFixture.with { fixture in
            let report = await uninstaller(fixture, loginFails: true).run(try plan(fixture))
            #expect(log.all == ["permission", "unregister helper", "unregister login"])
            #expect(report.entries.first { $0.subject == .helper }?.result == .done)
            #expect(report.entries.first { $0.subject == .loginItem }?.result == .failed("launchd verweigert"))
            #expect(!report.entries.contains { if case .file = $0.subject { $0.result.isDone } else { false } })
            #expect(report.blockedBy == .loginItem)
        }
    }

    /// Auch ein auf Genehmigung wartender Dienst ist registriert: Scheitert seine Abmeldung, hält der Ablauf an.
    @Test func failedUnregistrationOfServiceAwaitingApprovalStopsToo() async throws {
        try await LibraryFixture.with { fixture in
            let report = await uninstaller(fixture, helperStatus: .requiresApproval, helperFails: true).run(try plan(fixture))
            #expect(log.all == ["permission", "unregister helper"])
            #expect(report.blockedBy == .helper)
        }
    }

    /// Wiederholung nach gescheitertem Login-Item: Der schon abgemeldete Helper wird nicht erneut abgemeldet, sondern
    /// gilt als erfüllt; erst jetzt folgen Berechtigungen und Papierkorb (#140).
    @Test func retryBuildsOnServicesAlreadyUnregistered() async throws {
        try await LibraryFixture.with { fixture in
            let plan = try plan(fixture)
            let helper = FakeService(name: "helper", log: log), loginItem = FakeService(name: "login", log: log, fails: true)
            let first = await uninstaller(fixture, helper: helper, loginItem: loginItem).run(plan)
            #expect(first.blockedBy == .loginItem)
            #expect(!first.appRemoved)

            loginItem.fails = false
            let second = await uninstaller(fixture, helper: helper, loginItem: loginItem).run(plan)
            #expect(log.all == [
                "permission", "unregister helper", "unregister login",
                "permission", "unregister login", "reset \(Self.fullDiskAccess)", "trash 2", "reset \(Self.automation)",
            ])
            #expect(second.entries.first { $0.subject == .helper }?.result == .skipped(SelfUninstaller.notRegisteredReason))
            #expect(!second.isAborted)
            #expect(second.appRemoved)
        }
    }

    /// Meldet `SMAppService` einen Fehler, ist der Dienst danach aber nicht mehr registriert, ist die Voraussetzung
    /// erfüllt – der Ablauf geht weiter.
    @Test func serviceGoneDespiteErrorCountsAsUnregistered() async throws {
        try await LibraryFixture.with { fixture in
            let helper = FakeService(name: "helper", log: log, fails: true, statusAfterFailure: .notRegistered)
            let report = await uninstaller(fixture, helper: helper, loginItem: FakeService(name: "login", log: log))
                .run(try plan(fixture))
            #expect(report.entries.first { $0.subject == .helper }?.result == .done)
            #expect(!report.isAborted)
            #expect(report.appRemoved)
        }
    }

    /// `.notFound` nach einem Fehler belegt keine Abmeldung: Der Fehler bleibt, nichts Weiteres läuft (#140).
    @Test func notFoundAfterFailedUnregistrationKeepsTheFailure() async throws {
        try await LibraryFixture.with { fixture in
            let helper = FakeService(name: "helper", log: log, fails: true, statusAfterFailure: .notFound)
            let report = await uninstaller(fixture, helper: helper, loginItem: FakeService(name: "login", log: log))
                .run(try plan(fixture))
            #expect(log.all == ["permission", "unregister helper"])
            #expect(report.entries.first { $0.subject == .helper }?.result == .failed("launchd verweigert"))
            #expect(report.blockedBy == .helper)
            #expect(!report.appRemoved)
        }
    }

    /// Meldet der Helper vorab `.notFound`, wird er trotzdem abgemeldet; scheitert das, hält der Ablauf an.
    @Test func helperNotFoundBeforehandIsStillUnregistered() async throws {
        try await LibraryFixture.with { fixture in
            let report = await uninstaller(fixture, helperStatus: .notFound, helperFails: true).run(try plan(fixture))
            #expect(log.all == ["permission", "unregister helper"])
            #expect(report.blockedBy == .helper)
        }
    }

    /// Lässt sich eine Berechtigung nicht zurücksetzen, bleibt Grantry installiert: Ohne die App ginge das nicht mehr
    /// nachzuholen. Weder Papierkorb noch Automation-Reset folgen (#140).
    @Test func failedPermissionResetStopsBeforeTrash() async throws {
        try await LibraryFixture.with { fixture in
            let plan = try plan(fixture)
            let report = await uninstaller(fixture, failingResets: [Self.fullDiskAccess]).run(plan)
            #expect(log.all == ["permission", "unregister helper", "unregister login", "reset \(Self.fullDiskAccess)"])
            #expect(!report.appRemoved)
            #expect(report.blockedBy == .grant(plan.grants[1]))
            #expect(report.entries.first { $0.subject == .grant(plan.grants[1]) }?.result == .failed("tccutil verweigert"))
            let skipped = report.entries.filter { $0.result == .skipped(SelfUninstaller.blockedReason) }.map(\.subject)
            #expect(Set(skipped) == Set(plan.files.map { .file($0) } + [.grant(plan.grants[0])]))
        }
    }

    /// Ein Automation-Reset nach dem Papierkorb, der scheitert, sperrt nichts mehr – Grantry ist entfernt.
    @Test func failedAutomationResetAfterTrashOnlyReports() async throws {
        try await LibraryFixture.with { fixture in
            let report = await uninstaller(fixture, failingResets: [Self.automation]).run(try plan(fixture))
            #expect(report.appRemoved)
            #expect(!report.isAborted)
        }
    }

    /// Die Einstellungen werden beim Beenden nur geleert, wenn ihre Datei Teil des Plans war und im Papierkorb liegt (#156).
    @Test func preferencesCountAsRemovedOnlyWhenTheirFileWasTrashed() async throws {
        try await LibraryFixture.with { fixture in
            let plan = try plan(fixture, preferences: true)
            let withoutPreferences = SelfUninstallPlan(files: plan.files.filter { $0.kind != .preferences }, grants: plan.grants)

            let kept = await uninstaller(fixture).run(withoutPreferences)
            #expect(kept.appRemoved)
            #expect(!kept.preferencesRemoved)

            let removed = await uninstaller(fixture).run(plan)
            #expect(removed.preferencesRemoved)

            let cancelled = await uninstaller(fixture, trash: LoggingTrash(log: log, cancelled: true)).run(plan)
            #expect(!cancelled.preferencesRemoved)
        }
    }

    @Test func servicesThatWereNotRegisteredAreSkipped() async throws {
        try await LibraryFixture.with { fixture in
            let report = await uninstaller(fixture, helperStatus: .notRegistered, loginStatus: .notFound).run(try plan(fixture))
            #expect(!log.all.contains { $0.hasPrefix("unregister") })
            #expect(report.entries.prefix(2).map(\.result) == [.skipped(SelfUninstaller.notRegisteredReason),
                                                               .skipped(SelfUninstaller.notRegisteredReason)])
        }
    }

    @Test func replacedEntryIsNotTrashed() async throws {
        try await LibraryFixture.with { fixture in
            let plan = try plan(fixture)
            let data = plan.files[1].path
            try FileManager.default.removeItem(atPath: data)
            try fixture.folder(data)
            let report = await uninstaller(fixture).run(plan)
            #expect(log.all.contains("trash 1"))
            #expect(report.entries.first { $0.subject == .file(plan.files[1]) }?.result == .failed("Nicht angefasst: Eintrag wurde ersetzt"))
            #expect(report.appRemoved)
        }
    }

    /// Fortschritt (#143): jeder ausgeführte Schritt meldet Beginn und Ergebnis, in Ablaufreihenfolge.
    @Test func reportsProgressOfEachStepInOrder() async throws {
        try await LibraryFixture.with { fixture in
            let events = Mutex<[SelfUninstallEvent]>([])
            let plan = try plan(fixture)
            _ = await uninstaller(fixture).run(plan) { event in events.withLock { $0.append(event) } }
            let started = events.withLock { $0 }.compactMap { if case .started(let step) = $0 { step } else { nil } }
            #expect(started == [.finderAccess, .services, .services, .permissions, .trash, .finderAutomation])
            let finished = events.withLock { $0 }.compactMap { event -> SelfUninstallStep? in
                if case .finished(let step, _) = event { step } else { nil }
            }
            #expect(finished == started)
        }
    }

    /// Nach einem Fehler melden die ausgelassenen Schritte nur ihr Ergebnis – „nicht ausgeführt“, ohne Beginn.
    @Test func blockedStepsReportOnlyTheirSkippedEntries() async throws {
        try await LibraryFixture.with { fixture in
            let events = Mutex<[SelfUninstallEvent]>([])
            let plan = try plan(fixture)
            _ = await uninstaller(fixture, helperFails: true).run(plan) { event in events.withLock { $0.append(event) } }
            let all = events.withLock { $0 }
            #expect(!all.contains(.started(.trash)))
            #expect(all.contains(.finished(.trash, plan.files.map { .init(subject: .file($0), result: .skipped(SelfUninstaller.blockedReason)) })))
        }
    }

    /// Ohne Finder-Freigabe beginnt nur deren Prüfung; der Bericht nennt den Grund.
    @Test func deniedFinderAccessReportsOnlyTheCheck() async throws {
        try await LibraryFixture.with { fixture in
            let events = Mutex<[SelfUninstallEvent]>([])
            let report = await uninstaller(fixture, trash: LoggingTrash(log: log, permission: .unavailable("Finder antwortet nicht")))
                .run(try plan(fixture)) { event in events.withLock { $0.append(event) } }
            #expect(events.withLock { $0 } == [.started(.finderAccess)])
            #expect(report.finderAccessFailure == "Finder antwortet nicht")
            #expect(!report.automationDenied)
        }
    }

    // MARK: - Wiederholung (#143)

    /// Verspäteter Finder-Erfolg: Der erste Auftrag meldete eine Zeitüberschreitung, legte Grantry aber doch in den
    /// Papierkorb. Die Wiederholung gleicht das ab, statt am fehlenden Pfad zu scheitern – Grantry gilt als entfernt.
    @Test func retryAfterLateFinderSuccessCountsTheTrashedOriginal() async throws {
        try await LibraryFixture.with { fixture in
            let plan = try plan(fixture)
            var progress = SelfUninstallProgress(plan: plan)
            progress.complete(with: await uninstaller(fixture, trash: LoggingTrash(log: log, cancelled: true)).run(plan))
            let (_, retry) = try #require(progress.retrying())
            #expect(retry.files.map(\.path) == plan.files.map(\.path))

            let app = plan.files[0]
            try FileManager.default.removeItem(atPath: app.path)
            let late = LoggingTrash(log: log, settled: [app.path: .trashed])
            let report = await uninstaller(fixture, trash: late).run(retry)
            #expect(report.entries.first { $0.subject == .file(app) }?.result == .done)
            #expect(report.appRemoved)
            #expect(log.all.last == "reset \(Self.automation)")
            #expect(log.all.filter { $0.hasPrefix("trash") } == ["trash 2", "trash 1"], "nur die offene Datei geht erneut an den Finder")
        }
    }

    /// Steht am Pfad inzwischen ein Ersatzobjekt, zählt nur das Original im Papierkorb; der Ersatz geht nicht mit.
    @Test func settledOriginalWithReplacementLeavesTheReplacementAlone() async throws {
        try await LibraryFixture.with { fixture in
            let plan = try plan(fixture)
            let app = plan.files[0]
            let trash = LoggingTrash(log: log, settled: [app.path: .recreated])
            let report = await uninstaller(fixture, trash: trash).run(plan)
            #expect(report.entries.first { $0.subject == .file(app) }?.result == .doneWithWarning(RemovalExecutor.recreatedWarning))
            #expect(log.all.contains("trash 1"))
        }
    }

    /// Liegen Grantry und ihre Einstellungen nachweislich schon im Papierkorb, bleibt das erledigt, auch wenn danach eine
    /// Abmeldung oder ein Berechtigungs-Reset scheitert und die Papierkorb-Stufe deshalb ausgelassen wird (#143).
    @Test(arguments: ["helper", "login", "permission"])
    func settledFilesSurviveAnEarlierFailure(failing: String) async throws {
        try await LibraryFixture.with { fixture in
            let plan = try plan(fixture, preferences: true)
            let app = plan.files[0], data = plan.files[1], preferences = plan.files[2]
            let trash = LoggingTrash(log: log, settled: [app.path: .trashed, preferences.path: .trashed])
            let report = await uninstaller(
                fixture, trash: trash, helperFails: failing == "helper", loginFails: failing == "login",
                failingResets: failing == "permission" ? [Self.fullDiskAccess] : []
            ).run(plan)
            #expect(report.isAborted)
            #expect(!log.all.contains { $0.hasPrefix("trash") })
            #expect(report.entries.first { $0.subject == .file(app) }?.result == .done)
            #expect(report.entries.first { $0.subject == .file(preferences) }?.result == .done)
            #expect(report.entries.first { $0.subject == .file(data) }?.result == .skipped(SelfUninstaller.blockedReason))
            #expect(report.appRemoved)
            #expect(report.clearsPreferences)
        }
    }

    /// Grantry liegt schon im Papierkorb, die Abmeldung des Helpers scheitert: Ohne Wiederholung bliebe ein angemeldeter
    /// privilegierter Dienst verwaist zurück. Angeboten werden „Erneut versuchen“ nur für offene Dienste und
    /// Berechtigungen (keine Dateien), „Beenden“ und der Weg über die Anmeldeobjekte; die Wiederholung schließt ab (#143).
    @Test func orphanedServiceAfterTrashedAppOffersServiceOnlyRetry() async throws {
        try await LibraryFixture.with { fixture in
            let plan = try plan(fixture, preferences: true)
            let app = plan.files[0], data = plan.files[1], preferences = plan.files[2]
            let trash = LoggingTrash(log: log, settled: [app.path: .trashed, preferences.path: .trashed])
            let helper = FakeService(name: "helper", log: log, fails: true), loginItem = FakeService(name: "login", log: log)
            var progress = SelfUninstallProgress(plan: plan)
            progress.complete(with: await uninstaller(fixture, trash: trash, helper: helper, loginItem: loginItem).run(plan))

            let report = try #require(progress.report)
            #expect(report.appRemoved)
            #expect(report.servicesStillRegistered == [.helper, .loginItem])
            // Dateien werden in der Wiederholung nur abgeglichen, nicht erneut an den Finder gegeben.
            #expect(progress.retryPlan == SelfUninstallPlan(files: plan.files, grants: plan.grants, trashesFiles: false))
            let presentation = SelfUninstallProgressPresentation(progress, home: "/Users/test")
            #expect(presentation.quitsApp)
            #expect(presentation.offersRetry)
            #expect(presentation.offersLoginItemsSettings)
            #expect(presentation.title == SelfUninstallProgressTexts.unfinishedTitle)
            #expect(presentation.outcome?.tone == .critical)
            #expect(presentation.outcome?.text.contains("Anmeldeobjekte & Erweiterungen") == true)
            #expect(presentation.outcome?.text.contains("Hintergrunddienst") == true)
            #expect(presentation.outcome?.text.contains(SelfUninstallTexts.removed) == false)

            helper.fails = false
            var (second, retry) = try #require(progress.retrying())
            let before = log.all.count
            second.complete(with: await uninstaller(fixture, trash: trash, helper: helper, loginItem: loginItem).run(retry))
            #expect(Array(log.all.dropFirst(before)) == [
                "unregister helper", "unregister login", "reset \(Self.fullDiskAccess)", "reset \(Self.automation)",
            ])
            let final = try #require(second.report)
            #expect(final.appRemoved)
            #expect(final.clearsPreferences)
            #expect(final.servicesStillRegistered.isEmpty)
            #expect(second.retryPlan == nil)
            // Die Daten fasste die Dienst-Wiederholung nicht an – sie bleiben offen und werden genannt.
            #expect(final.entries.first { $0.subject == .file(data) }?.result == .skipped(SelfUninstaller.notTrashedAgainReason))
            #expect(final.filesLeftBehind == [data])
            #expect(second.state(of: .trash) == .partial)
            #expect(second.state(of: .services) == .done)
            let done = SelfUninstallProgressPresentation(second, home: fixture.home)
            #expect(!done.offersRetry)
            #expect(!done.offersLoginItemsSettings)
            #expect(done.title == SelfUninstallProgressTexts.unfinishedTitle)
            #expect(done.outcome?.tone == .warning)
            #expect(done.outcome?.text.contains(SelfUninstallTexts.filesLeftBehind(["~/Library/Application Support/Grantry"])) == true)
            #expect(done.rows.first { $0.step == .trash }?.statusText == "Teilweise erledigt")
        }
    }

    /// Zeitüberschreitung → Bundle verspätet entsorgt → übrige Dateien offen → beim Wiederholen fehlt die
    /// Finder-Freigabe: Die Meldung nennt Ursache, Stand von Grantry und die zurückgebliebenen Pfade samt manuellem Weg.
    @Test(arguments: [TrashPermission.denied, .unavailable("Der Finder läuft nicht.")])
    func failedFinderAccessAfterLateSuccessStillNamesLeftovers(permission: TrashPermission) async throws {
        try await LibraryFixture.with { fixture in
            let plan = try plan(fixture, preferences: true)
            let app = plan.files[0], data = plan.files[1], preferences = plan.files[2]
            var first = SelfUninstallProgress(plan: plan)
            first.complete(with: await uninstaller(fixture, trash: LoggingTrash(log: log, cancelled: true)).run(plan))
            var (second, retry) = try #require(first.retrying())

            try FileManager.default.removeItem(atPath: app.path)
            let late = LoggingTrash(log: log, permission: permission, settled: [app.path: .trashed])
            second.complete(with: await uninstaller(fixture, trash: late).run(retry))

            let report = try #require(second.report)
            #expect(report.finderAccessFailure != nil)
            #expect(report.appRemoved)
            #expect(report.filesLeftBehind == [data, preferences])
            #expect(report.entries.first { $0.subject == .helper }?.result == .done)
            #expect(second.state(of: .trash) == .partial)
            let presentation = SelfUninstallProgressPresentation(second, home: fixture.home)
            let outcome = try #require(presentation.outcome)
            let paths = [data, preferences].map { PathDisplay.abbreviatingHome($0.path, home: fixture.home) }
            #expect(outcome.text.hasPrefix(try #require(report.finderAccessFailure)))
            #expect(outcome.text.contains(SelfUninstallTexts.inTrash))
            #expect(outcome.text.contains(SelfUninstallTexts.filesLeftBehind(paths)))
            #expect(!outcome.text.contains(SelfUninstallTexts.removed))
            #expect(outcome.tone == .critical)
            #expect(outcome.details.isEmpty, "Die fehlende Freigabe steht einmal in der Meldung, nicht je Eintrag")
            #expect((outcome.settingsURL != nil) == (permission == .denied))
            #expect(presentation.title == SelfUninstallProgressTexts.unfinishedTitle)
            #expect(presentation.quitsApp)
        }
    }

    /// Dateien entsorgt, Dienste abgemeldet, ein Berechtigungs-Reset scheitert, die Automation wird deswegen
    /// ausgelassen: nicht vollständig – Ursache, offene Berechtigungen mit manuellem Weg und eine Wiederholung nur für
    /// die Berechtigungen; die Wiederholung schließt ab (#143).
    @Test func failedResetAfterTrashedFilesIsNotComplete() async throws {
        try await LibraryFixture.with { fixture in
            let plan = try plan(fixture)
            let settled = Dictionary(uniqueKeysWithValues: plan.files.map { ($0.path, TrashItemOutcome.trashed) })
            let trash = LoggingTrash(log: log, settled: settled)
            var progress = SelfUninstallProgress(plan: plan)
            let helper = FakeService(name: "helper", log: log), loginItem = FakeService(name: "login", log: log)
            progress.complete(with: await uninstaller(
                fixture, trash: trash, helper: helper, loginItem: loginItem, failingResets: [Self.fullDiskAccess]
            ).run(plan))

            let report = try #require(progress.report)
            #expect(report.appRemoved)
            #expect(!report.isComplete)
            #expect(report.grantsLeftBehind == [plan.grants[1], plan.grants[0]])
            #expect(progress.state(of: .permissions) == .failed)
            #expect(progress.state(of: .finderAutomation) == .blocked)
            #expect(progress.retryPlan == SelfUninstallPlan(files: plan.files, grants: plan.grants, trashesFiles: false))

            let presentation = SelfUninstallProgressPresentation(progress, home: fixture.home)
            let text = try #require(presentation.outcome?.text)
            #expect(presentation.title == SelfUninstallProgressTexts.unfinishedTitle)
            #expect(presentation.offersRetry)
            #expect(presentation.quitsApp)
            #expect(!presentation.offersLoginItemsSettings)
            #expect(text.hasPrefix(SelfUninstallTexts.blocked(by: .grant(plan.grants[1]))))
            #expect(text.contains(SelfUninstallTexts.inTrash))
            #expect(!text.contains(SelfUninstallTexts.removed))
            #expect(text.contains("Datenschutz & Sicherheit › Festplattenvollzugriff"))
            #expect(text.contains("tccutil reset SystemPolicyAllFiles de.cstrube.Grantry"))
            #expect(text.contains("tccutil reset AppleEvents de.cstrube.Grantry"))

            var (second, retry) = try #require(progress.retrying())
            let before = log.all.count
            second.complete(with: await uninstaller(fixture, trash: trash, helper: helper, loginItem: loginItem).run(retry))
            // Dienste sind schon abgemeldet, Dateien entsorgt: nur die offenen Berechtigungen, ohne Finder.
            #expect(Array(log.all.dropFirst(before)) == ["reset \(Self.fullDiskAccess)", "reset \(Self.automation)"])
            #expect(second.report?.isComplete == true)
            #expect(second.retryPlan == nil)
            #expect(SelfUninstallProgressPresentation(second, home: fixture.home).title == SelfUninstallProgressTexts.finishedTitle)
        }
    }

    /// Der Nutzer legt die im ersten Versuch entsorgte Einstellungsdatei per „Zurücklegen“ zurück: Die Wiederholung
    /// übernimmt ihr altes „erledigt“ nicht, sondern gleicht frisch ab – sie ist wieder offen und geht (Grantry noch
    /// installiert) erneut in den Papierkorb; ohne Finder-Erfolg bleiben die Einstellungen beim Beenden erhalten (#143).
    @Test func restoredPreferencesAreOpenAgainOnRetry() async throws {
        try await LibraryFixture.with { fixture in
            let plan = try plan(fixture, preferences: true)
            let app = plan.files[0], data = plan.files[1], preferences = plan.files[2]
            // Erster Versuch: Daten und Einstellungen im Papierkorb, Grantry nicht (Passwortabfrage abgebrochen).
            var first = SelfUninstallProgress(plan: plan)
            first.complete(with: SelfUninstallReport(entries: [
                .init(subject: .helper, result: .done), .init(subject: .loginItem, result: .done),
                .init(subject: .grant(plan.grants[1]), result: .done),
                .init(subject: .file(app), result: .failed("Abgebrochen (z. B. Passwortabfrage)")),
                .init(subject: .file(data), result: .done), .init(subject: .file(preferences), result: .done),
                .init(subject: .grant(plan.grants[0]), result: .skipped(SelfUninstaller.blockedReason)),
            ], finderAccessFailure: nil, blockedBy: .file(app)))
            var (second, retry) = try #require(first.retrying())
            #expect(retry.files == plan.files, "alle Dateien des bestätigten Plans werden frisch abgeglichen")

            // Daten liegen weiter im Papierkorb, die Einstellungen sind zurückgelegt (am Pfad, nicht im Papierkorb);
            // die Passwortabfrage wird erneut abgebrochen.
            let trash = LoggingTrash(log: log, cancelled: true, settled: [data.path: .trashed])
            second.complete(with: await uninstaller(fixture, trash: trash).run(retry))
            #expect(log.all.contains("trash 2"), "Grantry und die zurückgelegten Einstellungen gehen erneut an den Finder")
            let report = try #require(second.report)
            #expect(report.entries.first { $0.subject == .file(data) }?.result == .done)
            #expect(report.entries.first { $0.subject == .file(preferences) }?.result.isDone == false)
            #expect(!report.preferencesRemoved)
            #expect(!report.clearsPreferences)
            #expect(!report.isComplete)
        }
    }

    /// Bei entsorgtem Bundle gibt die Wiederholung zurückgelegte Dateien nicht erneut an den Finder, meldet sie aber als
    /// offen – auch eine früher entsorgte Einstellungsdatei.
    @Test func restoredPreferencesAfterTrashedAppAreLeftBehind() async throws {
        try await LibraryFixture.with { fixture in
            let plan = try plan(fixture, preferences: true)
            let app = plan.files[0], preferences = plan.files[2]
            var first = SelfUninstallProgress(plan: plan)
            first.complete(with: SelfUninstallReport(entries: [
                .init(subject: .helper, result: .failed("launchd verweigert")),
                .init(subject: .loginItem, result: .skipped(SelfUninstaller.blockedReason)),
                .init(subject: .grant(plan.grants[1]), result: .skipped(SelfUninstaller.blockedReason)),
                .init(subject: .file(app), result: .done), .init(subject: .file(plan.files[1]), result: .done),
                .init(subject: .file(preferences), result: .done),
                .init(subject: .grant(plan.grants[0]), result: .skipped(SelfUninstaller.blockedReason)),
            ], finderAccessFailure: nil, blockedBy: .helper))
            var (second, retry) = try #require(first.retrying())
            #expect(!retry.trashesFiles)

            let trash = LoggingTrash(log: log, settled: [app.path: .trashed, plan.files[1].path: .trashed])
            second.complete(with: await uninstaller(fixture, trash: trash).run(retry))
            #expect(!log.all.contains("permission"))
            #expect(!log.all.contains { $0.hasPrefix("trash") })
            let report = try #require(second.report)
            #expect(report.appRemoved)
            #expect(report.filesLeftBehind == [preferences])
            #expect(!report.clearsPreferences)
            #expect(second.state(of: .trash) == .partial)
        }
    }

    /// Verspäteter Finder-Erfolg während des Automation-Resets: Der Abschlussabgleich meldet die Datei als erledigt
    /// und den Bericht als vollständig – ohne nachträglich etwas auszuführen (#143).
    @Test func lateFinderSuccessDuringAutomationResetCountsAsDone() async throws {
        try await LibraryFixture.with { fixture in
            let plan = try plan(fixture)
            let data = plan.files[1]
            let trash = LoggingTrash(log: log, remaining: [data.path])
            let permissions = LoggingPermissions(log: log, duringReset: { grant in
                if grant.service == Self.automation { trash.settleLate(data.path) }
            })
            let report = await SelfUninstaller(
                helper: FakeService(name: "helper", log: log), loginItem: FakeService(name: "login", log: log),
                permissions: permissions, trash: trash, removalGuard: RemovalGuard(layout: fixture.layout)
            ).run(plan)
            #expect(log.all == [
                "permission", "unregister helper", "unregister login", "reset \(Self.fullDiskAccess)", "trash 2",
                "reset \(Self.automation)",
            ])
            #expect(report.entries.first { $0.subject == .file(data) }?.result == .done)
            #expect(report.isComplete)
        }
    }

    /// Erst beim Abschluss erkannt: Die Automation, die wegen des liegengebliebenen Bundles behalten wurde, bleibt
    /// behalten – der späte Erfolg ändert nur den Bericht (Grantry entfernt, Automation offen, `blockedBy` bleibt).
    @Test func lateSuccessDoesNotJustifySkippedStepsAfterwards() async throws {
        try await LibraryFixture.with { fixture in
            let plan = try plan(fixture)
            let app = plan.files[0]
            let late = LateAfterTrash(base: LoggingTrash(log: log, remaining: [app.path]), path: app.path)
            let report = await SelfUninstaller(
                helper: FakeService(name: "helper", log: log), loginItem: FakeService(name: "login", log: log),
                permissions: LoggingPermissions(log: log), trash: late, removalGuard: RemovalGuard(layout: fixture.layout)
            ).run(plan)
            #expect(!log.all.contains("reset \(Self.automation)"))
            #expect(report.entries.first { $0.subject == .file(app) }?.result == .done)
            #expect(report.appRemoved)
            #expect(report.blockedBy == .file(app), "die Entscheidung des Laufs bleibt")
            #expect(report.entries.first { $0.subject == .grant(plan.grants[0]) }?.result == .skipped(SelfUninstaller.blockedReason))
            #expect(!report.isComplete)
        }
    }

    /// Die Originale werden zu Beginn festgehalten – vor Abmeldung und Berechtigungs-Reset, solange Grantry den
    /// Festplattenvollzugriff noch hat (#143); auch wenn die Papierkorb-Stufe danach gar nicht läuft.
    @Test func originalsAreTrackedBeforeAnythingChanges() async throws {
        try await LibraryFixture.with { fixture in
            let plan = try plan(fixture)
            let trash = LoggingTrash(log: log)
            let trackedWhileUnregistering = Mutex<[String]>([])
            let helper = FakeService(name: "helper", log: log, fails: true, duringUnregister: {
                trackedWhileUnregistering.withLock { $0 = trash.tracked }
            })
            _ = await uninstaller(fixture, trash: trash, helper: helper, loginItem: FakeService(name: "login", log: log)).run(plan)
            #expect(trackedWhileUnregistering.withLock { $0 } == plan.files.map(\.path))
        }
    }

    /// Ein zu Beginn als entsorgt festgestelltes Original wird während des Laufs zurückgelegt (hier: während der
    /// angehaltenen Abmeldung). Der Abgleich am Ende des Laufs erkennt das: Die Datei ist offen, der Bericht
    /// unvollständig und nennt sie; die Einstellungen werden nicht geleert (#143).
    @Test(.timeLimit(.minutes(1))) func originalRestoredDuringTheRunIsOpen() async throws {
        try await LibraryFixture.with { fixture in
            let plan = try plan(fixture, preferences: true)
            let app = plan.files[0], preferences = plan.files[2]
            let all = Dictionary(uniqueKeysWithValues: plan.files.map { ($0.path, TrashItemOutcome.trashed) })
            let trash = LoggingTrash(log: log, settled: all)
            let paused = Gate(), resume = Gate()
            let helper = FakeService(name: "helper", log: log, duringUnregister: {
                paused.open()
                try? await resume.wait()
            })
            let uninstaller = uninstaller(fixture, trash: trash, helper: helper, loginItem: FakeService(name: "login", log: log))
            let running = Task { await uninstaller.run(plan) }
            try await paused.wait()
            trash.restore(preferences.path)
            resume.open()
            let report = await running.value

            #expect(report.entries.first { $0.subject == .file(app) }?.result == .done)
            #expect(report.entries.first { $0.subject == .file(preferences) }?.result == .failed(SelfUninstaller.notInTrashAnymoreReason))
            #expect(!report.isComplete)
            #expect(!report.clearsPreferences)
            #expect(report.filesLeftBehind == [preferences])
            let text = ActionOutcomePresentation.selfUninstall(report, home: fixture.home).text
            #expect(text.contains(SelfUninstallTexts.filesLeftBehind([PathDisplay.abbreviatingHome(preferences.path, home: fixture.home)])))
        }
    }

    /// Ist alles Offene schon im Papierkorb, braucht die Wiederholung keine Finder-Freigabe mehr.
    @Test func everythingSettledNeedsNoFinderAccess() async throws {
        try await LibraryFixture.with { fixture in
            let plan = try plan(fixture)
            let settled = Dictionary(uniqueKeysWithValues: plan.files.map { ($0.path, TrashItemOutcome.trashed) })
            let report = await uninstaller(fixture, trash: LoggingTrash(log: log, permission: .denied, settled: settled)).run(plan)
            #expect(!log.all.contains("permission"))
            #expect(!log.all.contains { $0.hasPrefix("trash") })
            #expect(report.appRemoved)
            #expect(report.finderAccessFailure == nil)
        }
    }

    /// Teilerfolg, dann scheitert beim Wiederholen die Finder-Freigabe: Die frühere Abmeldung und Rücksetzung bleiben
    /// im Bericht erledigt, die Meldung nennt sie, und der Fortschritt zeigt sie weiter als erledigt.
    @Test(arguments: [TrashPermission.denied, .unavailable("Der Finder läuft nicht.")])
    func failedFinderAccessOnRetryKeepsEarlierChanges(permission: TrashPermission) async throws {
        try await LibraryFixture.with { fixture in
            let plan = try plan(fixture)
            var first = SelfUninstallProgress(plan: plan)
            first.complete(with: await uninstaller(fixture, trash: LoggingTrash(log: log, cancelled: true)).run(plan))
            var (second, retry) = try #require(first.retrying())
            second.complete(with: await uninstaller(fixture, trash: LoggingTrash(log: log, permission: permission)).run(retry))

            let report = try #require(second.report)
            #expect(report.finderAccessFailure != nil)
            #expect(report.entries.first { $0.subject == .helper }?.result == .done)
            #expect(report.entries.first { $0.subject == .grant(plan.grants[1]) }?.result == .done)
            #expect(second.state(of: .finderAccess) == .failed)
            #expect(second.state(of: .services) == .done)
            #expect(second.state(of: .permissions) == .done)
            #expect(second.state(of: .trash) == .blocked)
            #expect(second.state(of: .finderAutomation) == .blocked)
            let text = ActionOutcomePresentation.selfUninstall(report, home: "/Users/test").text
            #expect(text.contains("Bereits abgemeldet bzw. zurückgesetzt"))
            #expect(text.contains("Hintergrunddienst"))
            #expect(second.retryPlan == retry)
        }
    }

    @Test func planTakesFilesAndGrantsButNoAutostartItems() {
        let app = TestData.installedApp("Grantry", bundleID: "de.cstrube.Grantry", path: "/Applications/Grantry.app")
        let file = LeftoverCandidate(path: app.path, kind: .appBundle, confidence: .safe)
        let grant = TestData.grant("kTCCServiceSystemPolicyAllFiles", client: app.identity)
        let plan = SelfUninstallPlan(RemovalPlan(app: app, grants: [grant], autostartItems: [TestData.item("helper")], files: [file]))
        #expect(plan.files == [file])
        #expect(plan.grants == [grant])
        #expect(plan.includesApp)
    }
}

@Suite struct SelfUninstallPresentationTests {
    private let app = LeftoverCandidate(path: "/Applications/Grantry.app", kind: .appBundle, confidence: .safe)

    @Test func removedAppQuitsAndNamesWhatFailed() {
        let grant = TestData.grant("kTCCServiceAppleEvents", client: TestData.installedApp("Grantry", bundleID: "de.cstrube.Grantry").identity)
        let report = SelfUninstallReport(entries: [
            .init(subject: .helper, result: .done),
            .init(subject: .loginItem, result: .skipped(SelfUninstaller.notRegisteredReason)),
            .init(subject: .file(app), result: .done),
            .init(subject: .grant(grant), result: .failed("geht nicht")),
        ], automationDenied: false)
        let presentation = ActionOutcomePresentation.selfUninstall(report, home: "/Users/test")
        // Die Automation ist offen: nicht vollständig, Grantry liegt aber im Papierkorb – mit manuellem Weg.
        #expect(!report.isComplete)
        #expect(presentation.text == [
            SelfUninstallTexts.inTrash, SelfUninstallTexts.grantsLeftBehind([grant], home: "/Users/test"), RemovalTexts.restoreHint,
        ].joined(separator: " "))
        #expect(presentation.text.contains("tccutil reset AppleEvents de.cstrube.Grantry"))
        #expect(presentation.tone == .warning)
        #expect(presentation.details == ["Automation-Berechtigung von Grantry: geht nicht"])
    }

    @Test func cancelledTrashNamesWhatWasAlreadyUndone() {
        let grant = TestData.grant("kTCCServiceSystemPolicyAllFiles", client: TestData.installedApp("Grantry", bundleID: "de.cstrube.Grantry").identity)
        let data = LeftoverCandidate(path: "/Users/test/Library/Application Support/Grantry", kind: .applicationSupport, confidence: .safe)
        let report = SelfUninstallReport(entries: [
            .init(subject: .helper, result: .done),
            .init(subject: .loginItem, result: .done),
            .init(subject: .grant(grant), result: .done),
            .init(subject: .file(app), result: .failed("Abgebrochen (z. B. Passwortabfrage)")),
            .init(subject: .file(data), result: .done),
        ], automationDenied: false)
        let presentation = ActionOutcomePresentation.selfUninstall(report, home: "/Users/test")
        let undone = ["Hintergrunddienst", "Beim Anmelden starten", "Festplattenvollzugriff-Berechtigung von Grantry"]
        #expect(presentation.text == [
            SelfUninstallTexts.notRemoved, SelfUninstallTexts.alreadyUndone(undone), SelfUninstallTexts.alreadyTrashed(1),
        ].joined(separator: " "))
        #expect(presentation.tone == .critical)
        #expect(presentation.details == ["/Applications/Grantry.app: Abgebrochen (z. B. Passwortabfrage)"])
    }

    /// Nach gescheiterter Abmeldung zählt nur der Fehler selbst; die deswegen ausgelassenen Schritte sind kein Befund.
    @Test func abortedUninstallNamesOnlyTheFailedService() {
        let grant = TestData.grant("kTCCServiceSystemPolicyAllFiles", client: TestData.installedApp("Grantry", bundleID: "de.cstrube.Grantry").identity)
        let report = SelfUninstallReport(entries: [
            .init(subject: .helper, result: .failed("launchd verweigert")),
            .init(subject: .loginItem, result: .skipped(SelfUninstaller.blockedReason)),
            .init(subject: .grant(grant), result: .skipped(SelfUninstaller.blockedReason)),
            .init(subject: .file(app), result: .skipped(SelfUninstaller.blockedReason)),
        ], automationDenied: false, blockedBy: .helper)
        let presentation = ActionOutcomePresentation.selfUninstall(report, home: "/Users/test")
        #expect(presentation.text == SelfUninstallTexts.blocked(by: .helper) + " " + SelfUninstallTexts.notRemoved)
        #expect(presentation.text.contains("Hintergrunddienst"))
        #expect(presentation.tone == .critical)
        #expect(presentation.details == ["Hintergrunddienst: launchd verweigert"])
    }

    /// Gescheiterte Berechtigung: Die Meldung nennt die schon abgemeldeten Dienste und den blockierenden Fehler (#140).
    @Test func blockedByPermissionNamesDoneStepsAndTheFailure() {
        let grant = TestData.grant("kTCCServiceSystemPolicyAllFiles", client: TestData.installedApp("Grantry", bundleID: "de.cstrube.Grantry").identity)
        let report = SelfUninstallReport(entries: [
            .init(subject: .helper, result: .done),
            .init(subject: .loginItem, result: .skipped(SelfUninstaller.notRegisteredReason)),
            .init(subject: .grant(grant), result: .failed("tccutil verweigert")),
            .init(subject: .file(app), result: .skipped(SelfUninstaller.blockedReason)),
        ], automationDenied: false, blockedBy: .grant(grant))
        let presentation = ActionOutcomePresentation.selfUninstall(report, home: "/Users/test")
        #expect(presentation.text == SelfUninstallTexts.blocked(by: .grant(grant)) + " " + SelfUninstallTexts.notRemoved + " "
            + SelfUninstallTexts.alreadyUndone(["Hintergrunddienst"]))
        #expect(presentation.details == ["Festplattenvollzugriff-Berechtigung von Grantry: tccutil verweigert"])
    }

    @Test func deniedAutomationLinksToTheSettings() {
        let presentation = ActionOutcomePresentation.selfUninstall(SelfUninstallReport(entries: [], automationDenied: true))
        #expect(presentation.settingsURL == TrashPermission.settingsURL)
    }
}
