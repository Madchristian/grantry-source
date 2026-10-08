import Testing
import Foundation
import ServiceManagement
import Synchronization
import GrantryShared
@testable import ManagerKit
import TestSupport

@Suite struct HelperManagerTests {
    /// Protokolliert Aufrufe, ohne `SMAppService` anzufassen. Nach `unregister()` wechselt der Status wie bei
    /// `SMAppService` auf `statusAfterUnregister` – auf Wunsch erst nach einigen Statusabfragen (verzögerte Abmeldung).
    private final class FakeDaemonService: DaemonService {
        private struct State {
            var status: SMAppService.Status
            var statusAfterRegister: SMAppService.Status?
            var registerError: (any Error)?
            /// Fehler, die die nächsten `register()`-Aufrufe der Reihe nach werfen (ohne Statuswechsel).
            var pendingRegisterErrors: [any Error]
            var statusAfterUnregister: SMAppService.Status?
            var unregisterError: (any Error)?
            var unregisterSettlesAfterReads: Int
            /// Ausstehender Statuswechsel nach `unregister()`: verbleibende Abfragen bis dahin und neuer Status.
            var pendingUnregister: (reads: Int, status: SMAppService.Status)?
            var calls: [String] = []
            /// Status zum Zeitpunkt jedes `register()`-Aufrufs.
            var statusAtRegister: [SMAppService.Status] = []
        }

        private let state: Mutex<State>

        init(
            status: SMAppService.Status,
            statusAfterRegister: SMAppService.Status? = nil,
            registerError: (any Error)? = nil,
            registerErrorsOnce: [any Error] = [],
            statusAfterUnregister: SMAppService.Status? = .notRegistered,
            unregisterError: (any Error)? = nil,
            unregisterSettlesAfterReads: Int = 0
        ) {
            state = Mutex(State(
                status: status, statusAfterRegister: statusAfterRegister, registerError: registerError,
                pendingRegisterErrors: registerErrorsOnce, statusAfterUnregister: statusAfterUnregister,
                unregisterError: unregisterError, unregisterSettlesAfterReads: unregisterSettlesAfterReads
            ))
        }

        var status: SMAppService.Status {
            state.withLock { state in
                if let pending = state.pendingUnregister {
                    if pending.reads <= 0 {
                        state.status = pending.status
                        state.pendingUnregister = nil
                    } else {
                        state.pendingUnregister = (pending.reads - 1, pending.status)
                    }
                }
                return state.status
            }
        }

        var calls: [String] { state.withLock { $0.calls } }
        var statusAtRegister: [SMAppService.Status] { state.withLock { $0.statusAtRegister } }

        func register() throws {
            try state.withLock { state in
                state.calls.append("register")
                state.statusAtRegister.append(state.status)
                // Eine noch ausstehende Abmeldung überholt die Registrierung nicht mehr.
                if let pending = state.pendingUnregister {
                    state.status = pending.status
                    state.pendingUnregister = nil
                }
                if !state.pendingRegisterErrors.isEmpty { throw state.pendingRegisterErrors.removeFirst() }
                if let next = state.statusAfterRegister { state.status = next }
                if let error = state.registerError { throw error }
            }
        }

        func unregister() async throws {
            try state.withLock { state in
                state.calls.append("unregister")
                if let error = state.unregisterError { throw error }
                guard let next = state.statusAfterUnregister else { return }
                state.pendingUnregister = (state.unregisterSettlesAfterReads, next)
            }
        }
    }

    /// Zählt Aufrufe der Versionsabfrage.
    private final class ProbeCounter: Sendable {
        private let count = Mutex(0)
        func increment() { count.withLock { $0 += 1 } }
        var value: Int { count.withLock { $0 } }
    }

    /// Reihenfolge von Versionsabfragen („probe“) und aufgehobenen Abklingzeiten („endCooldown“).
    private final class ClientCalls: Sendable {
        private let calls = Mutex<[String]>([])
        func append(_ call: String) { calls.withLock { $0.append(call) } }
        var value: [String] { calls.withLock { $0 } }
    }

    private struct ProbeFailure: LocalizedError {
        var errorDescription: String? { "Verbindung abgelehnt" }
    }

    private struct UnrelatedFailure: Error, Equatable {}

    private static func serviceError(_ code: Int) -> NSError {
        NSError(domain: SMAppServiceErrorDomain, code: code)
    }

    private func manager(
        _ service: FakeDaemonService,
        version: Int = HelperXPC.protocolVersion,
        probeFails: Bool = false,
        failingProbes: Int = 0,
        probeCounter: ProbeCounter = ProbeCounter(),
        clientCalls: ClientCalls = ClientCalls(),
        onProbe: @escaping @Sendable () -> Void = {},
        isAdministrator: Bool = true,
        bundleContainsPlist: Bool = true,
        registration: HelperRegistrationRecord? = nil,
        timing: HelperManager.RegistrationTiming = Self.fastTiming,
        clock: some Clock<Duration> = ContinuousClock()
    ) -> HelperManager {
        let remainingFailures = Mutex(failingProbes)
        return HelperManager(
            service: service,
            versionProbe: {
                probeCounter.increment()
                clientCalls.append("probe")
                onProbe()
                if probeFails { throw ProbeFailure() }
                let fails = remainingFailures.withLock { remaining in
                    defer { remaining = max(remaining - 1, 0) }
                    return remaining > 0
                }
                if fails { throw ProbeFailure() }
                return version
            },
            endCooldown: { clientCalls.append("endCooldown") },
            isAdministrator: { isAdministrator },
            bundleContainsPlist: { bundleContainsPlist },
            registration: registration,
            timing: timing,
            clock: clock
        )
    }

    /// Kurze Fristen, damit Warten und Wiederholen die Tests nicht ausbremsen. Tests, deren Dienst sich sicher abmeldet,
    /// verwenden `patientTiming`, damit eine ausgelastete Testmaschine die Frist nicht reißt.
    private static let fastTiming = HelperManager.RegistrationTiming(
        unregisterDeadline: .milliseconds(200), statusPollInterval: .milliseconds(1), retryBackoff: .milliseconds(1),
        reachabilityRetryDelays: [.milliseconds(1), .milliseconds(1)], reachabilityRetryBudget: .seconds(60)
    )
    private static let patientTiming = HelperManager.RegistrationTiming(
        unregisterDeadline: .seconds(60), statusPollInterval: .milliseconds(1), retryBackoff: .milliseconds(1),
        reachabilityRetryDelays: [.milliseconds(1), .milliseconds(1)], reachabilityRetryBudget: .seconds(60)
    )

    /// Vermerk im Speicher; der aktuelle Build ist „2026.10.3 (412)“. `wasEnabled` `nil`: Schlüssel fehlt.
    /// `bundleOnDisk`: Build des App-Bundles auf der Platte (Standard: der laufende).
    private static func withRecord(
        registered: String? = nil,
        wasEnabled: Bool? = nil,
        bundleOnDisk: String? = "2026.10.3 (412)",
        _ body: (HelperRegistrationRecord) async throws -> Void
    ) async rethrows {
        let build = Mutex(registered)
        let enabled = Mutex(wasEnabled)
        try await body(HelperRegistrationRecord(
            currentBuild: "2026.10.3 (412)",
            storage: HelperRegistrationRecord.Storage(
                loadBuild: { build.withLock { $0 } },
                saveBuild: { value in build.withLock { $0 = value } },
                loadWasEnabled: { enabled.withLock { $0 } },
                saveWasEnabled: { value in enabled.withLock { $0 = value } }
            ),
            bundleBuildOnDisk: { bundleOnDisk }
        ))
    }

    @Test(arguments: [
        (SMAppService.Status.notRegistered, HelperState.notInstalled),
        (.requiresApproval, .awaitingApproval),
        (.enabled, .ready),
    ])
    func mapsServiceStatus(status: SMAppService.Status, expected: HelperState) async {
        #expect(await manager(FakeDaemonService(status: status)).state() == expected)
    }

    @Test func notFoundWithPlistInBundleMeansNotInstalled() async {
        #expect(await manager(FakeDaemonService(status: .notFound), bundleContainsPlist: true).state() == .notInstalled)
    }

    @Test func notFoundWithoutPlistInBundleMeansMissingFromBundle() async {
        #expect(await manager(FakeDaemonService(status: .notFound), bundleContainsPlist: false).state() == .missingFromBundle)
    }

    @Test(arguments: [SMAppService.Status.notRegistered, .requiresApproval, .notFound])
    func probesVersionOnlyWhenEnabled(status: SMAppService.Status) async {
        let counter = ProbeCounter()
        _ = await manager(FakeDaemonService(status: status), probeCounter: counter).state()
        #expect(counter.value == 0)
    }

    @Test func enabledWithOtherProtocolVersionIsOutdated() async {
        let state = await manager(FakeDaemonService(status: .enabled), version: HelperXPC.protocolVersion + 1).state()
        #expect(state == .outdated(installed: HelperXPC.protocolVersion + 1, expected: HelperXPC.protocolVersion))
    }

    @Test func enabledButProbeFailingIsUnreachable() async {
        let state = await manager(FakeDaemonService(status: .enabled), probeFails: true).state()
        #expect(state == .unreachable("Verbindung abgelehnt"))
    }

    @Test func nonAdministratorRequiresAdministratorWithoutRegistering() async throws {
        let service = FakeDaemonService(status: .notRegistered)
        let manager = manager(service, isAdministrator: false)
        #expect(await manager.state() == .requiresAdministrator)
        #expect(try await manager.register() == .requiresAdministrator)
        #expect(try await manager.reinstall() == .requiresAdministrator)
        #expect(service.calls.isEmpty)
    }

    @Test func registerRegistersAndReportsNewState() async throws {
        let service = FakeDaemonService(status: .notRegistered, statusAfterRegister: .requiresApproval)
        #expect(try await manager(service).register() == .awaitingApproval)
        #expect(service.calls == ["register"])
    }

    /// Eine neue Registrierung macht ein früheres „nicht erreichbar“ hinfällig: Nach der Zustandsabfrage endet die
    /// Abklingzeit des Clients – auch wenn diese Abfrage scheiterte, weil der Helper gerade erst startet –, damit der
    /// nächste Aufruf (etwa der erste Scan nach einem Update) es erneut versucht.
    @Test func registerEndsCooldownAfterDeterminingState() async throws {
        let calls = ClientCalls()
        let service = FakeDaemonService(status: .notRegistered, statusAfterRegister: .enabled)
        _ = try await manager(service, clientCalls: calls).register()
        #expect(calls.value == ["probe", "endCooldown"])
    }

    // MARK: - Erreichbarkeit nach der Registrierung (#88)

    /// Wiederholungen nach einer Registrierung, deren erste Zustandsabfrage „nicht erreichbar“ ergab: nach 100 ms,
    /// dann 200 ms später (insgesamt 300 ms), innerhalb von höchstens 1 s.
    private static let reachabilityTiming = HelperManager.RegistrationTiming(
        unregisterDeadline: .milliseconds(200), statusPollInterval: .milliseconds(1), retryBackoff: .milliseconds(1),
        reachabilityRetryDelays: [.milliseconds(100), .milliseconds(200)], reachabilityRetryBudget: .seconds(1)
    )

    /// Startet `register()` im Hintergrund an einer `TestClock`.
    private func registering(
        _ service: FakeDaemonService, probeFails: Bool = false, failingProbes: Int = 0,
        clientCalls: ClientCalls, clock: TestClock
    ) -> Task<HelperState, any Error> {
        let manager = manager(
            service, probeFails: probeFails, failingProbes: failingProbes, clientCalls: clientCalls,
            timing: Self.reachabilityTiming, clock: clock
        )
        return Task { try await manager.register() }
    }

    /// Der frisch registrierte Helper antwortet in der ersten Abfrage noch nicht, kurz darauf schon: `register()`
    /// wiederholt die Abfrage nach den Wartezeiten und meldet `.ready` statt „nicht erreichbar“.
    @Test(.timeLimit(.minutes(1))) func registerRetriesUnreachableStateUntilHelperAnswers() async throws {
        let calls = ClientCalls()
        let clock = TestClock()
        let service = FakeDaemonService(status: .notRegistered, statusAfterRegister: .enabled)
        let task = registering(service, failingProbes: 2, clientCalls: calls, clock: clock)
        await clock.waitForSleeper(until: .at(.milliseconds(100)))
        clock.advance(by: .milliseconds(100))
        await clock.waitForSleeper(until: .at(.milliseconds(300)))
        clock.advance(by: .milliseconds(200))
        #expect(try await task.value == .ready)
        #expect(calls.value == ["probe", "probe", "probe", "endCooldown"])
    }

    /// Bleibt der Helper über alle Wiederholungen unerreichbar, meldet `register()` `.unreachable`; die Abklingzeit
    /// endet auch nach der letzten Abfrage (#86), damit der nächste Aufruf es erneut versucht.
    @Test(.timeLimit(.minutes(1))) func registerReportsUnreachableAfterAllRetries() async throws {
        let calls = ClientCalls()
        let clock = TestClock()
        let service = FakeDaemonService(status: .notRegistered, statusAfterRegister: .enabled)
        let task = registering(service, probeFails: true, clientCalls: calls, clock: clock)
        await clock.waitForSleeper(until: .at(.milliseconds(100)))
        clock.advance(by: .milliseconds(100))
        await clock.waitForSleeper(until: .at(.milliseconds(300)))
        clock.advance(by: .milliseconds(200))
        #expect(try await task.value == .unreachable("Verbindung abgelehnt"))
        #expect(calls.value == ["probe", "probe", "probe", "endCooldown"])
    }

    /// Hängt die Abfrage bis zur Erreichbarkeitsfrist des Clients (hier 5 s, länger als das Budget), wird nicht
    /// wiederholt: Die Registrierung soll nicht ein Vielfaches dieser Frist dauern.
    @Test(.timeLimit(.minutes(1))) func registerDoesNotRetryWhenProbeExhaustsBudget() async throws {
        let calls = ClientCalls()
        let clock = TestClock()
        let manager = manager(
            FakeDaemonService(status: .notRegistered, statusAfterRegister: .enabled), probeFails: true,
            clientCalls: calls, onProbe: { clock.advance(by: .seconds(5)) }, timing: Self.reachabilityTiming,
            clock: clock
        )
        #expect(try await manager.register() == .unreachable("Verbindung abgelehnt"))
        #expect(calls.value == ["probe", "endCooldown"])
    }

    /// Eine Wartezeit beginnt nur, wenn sie noch ins Budget passt: Nach 100 ms ginge die nächste (200 ms) über 250 ms
    /// hinaus, also bleibt es bei einer Wiederholung.
    @Test(.timeLimit(.minutes(1))) func registerStopsRetryingWhenNextDelayExceedsBudget() async throws {
        let calls = ClientCalls()
        let clock = TestClock()
        var timing = Self.reachabilityTiming
        timing.reachabilityRetryBudget = .milliseconds(250)
        let manager = manager(
            FakeDaemonService(status: .notRegistered, statusAfterRegister: .enabled), probeFails: true,
            clientCalls: calls, timing: timing, clock: clock
        )
        let task = Task { try await manager.register() }
        await clock.waitForSleeper(until: .at(.milliseconds(100)))
        clock.advance(by: .milliseconds(100))
        #expect(try await task.value == .unreachable("Verbindung abgelehnt"))
        #expect(calls.value == ["probe", "probe", "endCooldown"])
    }

    /// Auch das Neu-Registrieren (etwa beim Erneuern nach einem Update) überbrückt einen noch startenden Helper.
    @Test func reinstallRetriesUnreachableStateAfterRegistering() async throws {
        let calls = ClientCalls()
        let service = FakeDaemonService(status: .enabled, statusAfterRegister: .enabled)
        let manager = manager(service, failingProbes: 1, clientCalls: calls, timing: Self.patientTiming)
        #expect(try await manager.reinstall() == .ready)
        #expect(service.calls == ["unregister", "register"])
        #expect(calls.value == ["probe", "probe", "endCooldown"])
    }

    /// Ein Abbruch während der Wartezeit beendet die Wiederholungen: `register()` liefert den zuletzt ermittelten
    /// Zustand, statt weiter zu warten – die Registrierung selbst ist ja gelungen.
    @Test(.timeLimit(.minutes(1))) func registerStopsRetryingWhenCancelled() async throws {
        let calls = ClientCalls()
        let clock = TestClock()
        let service = FakeDaemonService(status: .notRegistered, statusAfterRegister: .enabled)
        let task = registering(service, probeFails: true, clientCalls: calls, clock: clock)
        await clock.waitForSleeper(until: .at(.milliseconds(100)))
        task.cancel()
        #expect(try await task.value == .unreachable("Verbindung abgelehnt"))
        #expect(calls.value == ["probe", "endCooldown"])
        #expect(clock.advance(by: .seconds(10)) == 0)
    }

    /// Nur „nicht erreichbar“ wird wiederholt: Ein erreichbarer Helper mit anderer Protokollversion oder ein auf
    /// Genehmigung wartender Dienst liefern ihren Zustand sofort (eine wartende `TestClock` ließe den Test sonst hängen).
    @Test(.timeLimit(.minutes(1))) func registerDoesNotRetryOtherStates() async throws {
        let clock = TestClock()
        let outdated = manager(
            FakeDaemonService(status: .notRegistered, statusAfterRegister: .enabled),
            version: HelperXPC.protocolVersion + 1, timing: Self.reachabilityTiming, clock: clock
        )
        #expect(try await outdated.register()
            == .outdated(installed: HelperXPC.protocolVersion + 1, expected: HelperXPC.protocolVersion))
        let awaiting = manager(
            FakeDaemonService(status: .notRegistered, statusAfterRegister: .requiresApproval),
            timing: Self.reachabilityTiming, clock: clock
        )
        #expect(try await awaiting.register() == .awaitingApproval)
    }

    /// Gewöhnliche Zustandsabfragen warten nicht: `state()` meldet „nicht erreichbar“ nach einer einzigen Abfrage.
    @Test(.timeLimit(.minutes(1))) func stateDoesNotRetryUnreachableHelper() async {
        let counter = ProbeCounter()
        let manager = manager(
            FakeDaemonService(status: .enabled), failingProbes: 1, probeCounter: counter,
            timing: Self.reachabilityTiming, clock: TestClock()
        )
        #expect(await manager.state() == .unreachable("Verbindung abgelehnt"))
        #expect(counter.value == 1)
    }

    @Test func failedRegistrationKeepsCooldown() async {
        let calls = ClientCalls()
        let service = FakeDaemonService(status: .notRegistered, registerError: UnrelatedFailure())
        await #expect(throws: UnrelatedFailure()) { try await manager(service, clientCalls: calls).register() }
        #expect(calls.value.isEmpty)
    }

    @Test func registerToleratesLaunchDeniedWhileAwaitingApproval() async throws {
        let service = FakeDaemonService(
            status: .notRegistered, statusAfterRegister: .requiresApproval,
            registerError: Self.serviceError(kSMErrorLaunchDeniedByUser)
        )
        #expect(try await manager(service).register() == .awaitingApproval)
    }

    /// Wartet der Dienst auf Genehmigung, meldet `register()` `kSMErrorLaunchDeniedByUser`; der Build gilt trotzdem als
    /// registriert.
    @Test func launchDeniedWhileAwaitingApprovalRecordsBuild() async throws {
        try await Self.withRecord(registered: Self.otherBuild, wasEnabled: true) { record throws in
            let service = FakeDaemonService(
                status: .requiresApproval, registerError: Self.serviceError(kSMErrorLaunchDeniedByUser)
            )
            #expect(try await manager(service, registration: record).register() == .awaitingApproval)
            #expect(record.registeredBuild == Self.currentBuild)
            #expect(record.wasEnabled == false)
        }
    }

    @Test func registerToleratesAlreadyRegisteredWhenEnabled() async throws {
        let service = FakeDaemonService(status: .enabled, registerError: Self.serviceError(kSMErrorAlreadyRegistered))
        #expect(try await manager(service).register() == .ready)
    }

    @Test func registerRethrowsUnrelatedErrorEvenWhenEnabled() async {
        let service = FakeDaemonService(status: .enabled, registerError: UnrelatedFailure())
        await #expect(throws: UnrelatedFailure()) { try await manager(service).register() }
    }

    @Test func registerRethrowsKnownErrorWhenNotRegisteredAfterwards() async {
        let error = Self.serviceError(kSMErrorAlreadyRegistered)
        let service = FakeDaemonService(status: .notRegistered, registerError: error)
        await #expect(throws: error) { try await manager(service).register() }
    }

    @Test func registerRethrowsOtherServiceErrors() async {
        let error = Self.serviceError(kSMErrorInvalidSignature)
        let service = FakeDaemonService(status: .requiresApproval, registerError: error)
        await #expect(throws: error) { try await manager(service).register() }
    }

    @Test func reinstallUnregistersThenRegisters() async throws {
        let service = FakeDaemonService(status: .enabled, statusAfterRegister: .requiresApproval)
        #expect(try await manager(service).reinstall() == .awaitingApproval)
        #expect(service.calls == ["unregister", "register"])
    }

    // MARK: - Erneuern nach App-Austausch

    private static let otherBuild = "2026.10.2 (400)"
    private static let currentBuild = "2026.10.3 (412)"

    /// Seit der Registrierung wurde das App-Bundle ausgetauscht (anderer oder unbekannter Build): Erneuert wird bei
    /// `.enabled` immer, bei `.requiresApproval` und – mit Plist im Bundle – `.notFound` nur, wenn der Dienst im
    /// vermerkten Build zuletzt aktiv war oder das unbekannt ist (Übergang von Builds ohne diesen Vermerk). Nie bei
    /// `.notRegistered` (entfernt), bei vom Nutzer abgeschaltetem Dienst oder aktuellem Vermerk.
    /// Status × Build-Vermerk × „zuletzt aktiv“ für einen Administrator, Plist im Bundle.
    @Test(arguments: [
        (SMAppService.Status.enabled, "2026.10.2 (400)" as String?, nil as Bool?, RegistrationRenewal.renew),
        (.enabled, "2026.10.2 (400)", true, .renew),
        (.enabled, "2026.10.2 (400)", false, .renew),
        (.enabled, nil, nil, .renew),
        (.enabled, "2026.10.3 (412)", true, .skip(.recordCurrent)),
        (.requiresApproval, "2026.10.2 (400)", true, .renew),
        (.requiresApproval, "2026.10.2 (400)", nil, .renew),
        (.requiresApproval, "2026.10.2 (400)", false, .skip(.disabledByUser)),
        (.requiresApproval, nil, nil, .renew),
        (.requiresApproval, "2026.10.3 (412)", false, .skip(.recordCurrent)),
        (.notFound, "2026.10.2 (400)", true, .renew),
        (.notFound, "2026.10.2 (400)", nil, .renew),
        (.notFound, "2026.10.2 (400)", false, .skip(.disabledByUser)),
        (.notFound, nil, nil, .skip(.neverRegistered)),
        (.notFound, "2026.10.3 (412)", true, .skip(.recordCurrent)),
        (.notRegistered, "2026.10.2 (400)", true, .skip(.notRegistered)),
        (.notRegistered, "2026.10.2 (400)", nil, .skip(.notRegistered)),
        (.notRegistered, nil, nil, .skip(.notRegistered)),
        (.notRegistered, "2026.10.3 (412)", true, .skip(.recordCurrent)),
    ])
    func registrationRenewalAfterBundleChange(
        status: SMAppService.Status, registered: String?, wasEnabled: Bool?, expected: RegistrationRenewal
    ) async {
        await Self.withRecord(registered: registered, wasEnabled: wasEnabled) { record in
            let decision = manager(FakeDaemonService(status: status), registration: record).registrationRenewal
            #expect(decision.renewal == expected)
            #expect(decision.status == status)
            #expect(decision.registeredBuild == registered)
            #expect(decision.currentBuild == Self.currentBuild)
        }
    }

    @Test(arguments: [SMAppService.Status.enabled, .requiresApproval, .notFound, .notRegistered])
    func nonAdministratorNeverRenews(status: SMAppService.Status) async {
        await Self.withRecord(registered: Self.otherBuild) { record in
            let manager = manager(FakeDaemonService(status: status), isAdministrator: false, registration: record)
            #expect(manager.registrationRenewal.renewal == .skip(.notAdministrator))
        }
    }

    /// `.notFound` ohne launchd-Plist im Bundle: Registrieren könnte nicht gelingen.
    @Test func notFoundWithoutPlistInBundleIsNotRenewed() async {
        await Self.withRecord(registered: Self.otherBuild) { record in
            let manager = manager(FakeDaemonService(status: .notFound), bundleContainsPlist: false, registration: record)
            #expect(manager.registrationRenewal.renewal == .skip(.missingFromBundle))
        }
    }

    /// `.notFound` ohne Vermerk und ohne Plist: Die fehlende Plist ist der Grund.
    @Test func notFoundWithoutRecordAndWithoutPlistIsMissingFromBundle() async {
        await Self.withRecord { record in
            let manager = manager(FakeDaemonService(status: .notFound), bundleContainsPlist: false, registration: record)
            #expect(manager.registrationRenewal.renewal == .skip(.missingFromBundle))
        }
    }

    /// Beim Start mit aktuellem Vermerk wird festgehalten, ob der Dienst aktiv ist – schaltet der Nutzer ihn unter
    /// *Anmeldeobjekte* ab (`.requiresApproval`), respektiert das nächste Update das.
    @Test(arguments: [
        (SMAppService.Status.enabled, true),
        (.requiresApproval, false),
        (.notFound, false),
        (.notRegistered, false),
    ])
    func launchAssessmentNotesWhetherServiceIsEnabled(status: SMAppService.Status, expected: Bool) async {
        await Self.withRecord(registered: Self.currentBuild) { record in
            let decision = manager(FakeDaemonService(status: status), registration: record).assessRegistrationRenewalAtLaunch()
            #expect(decision.renewal == .skip(.recordCurrent))
            #expect(record.wasEnabled == expected)
        }
    }

    /// Auch jede Zustandsabfrage hält bei aktuellem Vermerk fest, ob der Dienst aktiv ist – so wird ein Abschalten
    /// unter *Anmeldeobjekte* zur Laufzeit erfasst.
    @Test(arguments: [
        (SMAppService.Status.enabled, true),
        (.requiresApproval, false),
        (.notFound, false),
        (.notRegistered, false),
    ])
    func stateNotesWhetherServiceIsEnabled(status: SMAppService.Status, expected: Bool) async {
        await Self.withRecord(registered: Self.currentBuild, wasEnabled: !expected) { record in
            _ = await manager(FakeDaemonService(status: status), registration: record).state()
            #expect(record.wasEnabled == expected)
        }
    }

    /// Läuft noch die alte App, während ihr Bundle auf der Platte schon ausgetauscht ist (oder nicht lesbar), meldet
    /// der Dienst womöglich nur wegen des Austauschs `.requiresApproval`; das darf nicht als Abschalten durch den
    /// Nutzer gelten.
    @Test(arguments: ["2026.10.4 (420)" as String?, nil])
    func staleInstanceDoesNotNoteEnabled(bundleOnDisk: String?) async {
        await Self.withRecord(registered: Self.currentBuild, wasEnabled: true, bundleOnDisk: bundleOnDisk) { record in
            let manager = manager(FakeDaemonService(status: .requiresApproval), registration: record)
            _ = await manager.state()
            _ = manager.assessRegistrationRenewalAtLaunch()
            #expect(record.wasEnabled == true)
        }
    }

    /// Bei abweichendem Build ändert die Zustandsabfrage „zuletzt aktiv“ nicht – sonst verfälschte sie die
    /// Erneuerungsentscheidung.
    @Test func stateKeepsWasEnabledForOtherBuild() async {
        await Self.withRecord(registered: Self.otherBuild, wasEnabled: true) { record in
            _ = await manager(FakeDaemonService(status: .requiresApproval), registration: record).state()
            #expect(record.wasEnabled == true)
        }
    }

    /// Weicht der Vermerk ab, bleibt „zuletzt aktiv“ unverändert – es beschreibt den vermerkten Build.
    @Test func launchAssessmentKeepsWasEnabledForOtherBuild() async {
        await Self.withRecord(registered: Self.otherBuild, wasEnabled: true) { record in
            let decision = manager(FakeDaemonService(status: .requiresApproval), registration: record)
                .assessRegistrationRenewalAtLaunch()
            #expect(decision.renewal == .renew)
            #expect(record.wasEnabled == true)
        }
    }

    /// Nach jeder erfolgreichen Registrierung gilt „zuletzt aktiv“ = Status danach ist `.enabled`.
    @Test(arguments: [(SMAppService.Status.enabled, true), (.requiresApproval, false)])
    func registrationNotesWhetherServiceIsEnabled(statusAfter: SMAppService.Status, expected: Bool) async throws {
        try await Self.withRecord(registered: Self.otherBuild) { record throws in
            let service = FakeDaemonService(status: .notRegistered, statusAfterRegister: statusAfter)
            _ = try await manager(service, registration: record).register()
            #expect(record.registeredBuild == Self.currentBuild)
            #expect(record.wasEnabled == expected)
        }
    }

    @Test func withoutRecordNothingNeedsRenewal() {
        let decision = manager(FakeDaemonService(status: .enabled)).registrationRenewal
        #expect(decision.renewal == .skip(.noRecord))
        #expect(decision.registeredBuild == nil)
        #expect(decision.currentBuild == nil)
    }

    /// Die Entscheidung ist für das Protokoll lesbar: Ergebnis, Grund, Status, registrierter und laufender Build.
    @Test func renewalDecisionDescribesReasonStatusAndBuilds() async {
        await Self.withRecord(registered: Self.otherBuild) { record in
            let skipped = manager(FakeDaemonService(status: .notRegistered), registration: record).registrationRenewal
            #expect(skipped.description == """
                keine Erneuerung (Dienst nicht registriert – vom Nutzer entfernt), Status notRegistered, \
                registriert aus 2026.10.2 (400), laufend 2026.10.3 (412)
                """)
        }
        await Self.withRecord { record in
            let renewed = manager(FakeDaemonService(status: .requiresApproval), registration: record).registrationRenewal
            #expect(renewed.description == """
                erneuern (Vermerk weicht ab oder fehlt), Status requiresApproval, \
                registriert aus unbekannt, laufend 2026.10.3 (412)
                """)
        }
    }

    /// Erneuern = neu registrieren (`unregister` + `register`); danach gilt der aktuelle Build als registriert.
    @Test func renewingRegistrationReinstallsAndRecordsBuild() async throws {
        try await Self.withRecord(registered: "2026.10.2 (400)") { record throws in
            let service = FakeDaemonService(status: .enabled, statusAfterRegister: .enabled)
            let manager = manager(service, registration: record)
            #expect(try await manager.reinstall() == .ready)
            #expect(service.calls == ["unregister", "register"])
            #expect(record.registeredBuild == "2026.10.3 (412)")
            #expect(manager.registrationRenewal.renewal == .skip(.recordCurrent))
        }
    }

    /// Verlangt das System nach dem Neu-Registrieren eine Genehmigung, ist der Build trotzdem registriert – die
    /// Genehmigung führt die Einrichtung herbei, nicht ein weiteres Erneuern.
    @Test func registrationAwaitingApprovalRecordsBuild() async throws {
        try await Self.withRecord { record throws in
            let service = FakeDaemonService(status: .notRegistered, statusAfterRegister: .requiresApproval)
            #expect(try await manager(service, registration: record).register() == .awaitingApproval)
            #expect(record.registeredBuild == "2026.10.3 (412)")
        }
    }

    @Test func failedRegistrationDoesNotRecordBuild() async {
        await Self.withRecord(registered: "2026.10.2 (400)") { record in
            let service = FakeDaemonService(status: .enabled, registerError: UnrelatedFailure())
            await #expect(throws: UnrelatedFailure()) { try await manager(service, registration: record).register() }
            #expect(record.registeredBuild == "2026.10.2 (400)")
        }
    }

    // MARK: - Neu registrieren: auf Abmeldung warten, einmal wiederholen

    /// `SMAppService.unregister()` kann zurückkehren, bevor der Dienst als abgemeldet gilt; registriert wird erst danach.
    @Test func reinstallWaitsUntilServiceIsUnregisteredBeforeRegistering() async throws {
        let service = FakeDaemonService(status: .enabled, statusAfterRegister: .enabled, unregisterSettlesAfterReads: 3)
        #expect(try await manager(service, timing: Self.patientTiming).reinstall() == .ready)
        #expect(service.calls == ["unregister", "register"])
        #expect(service.statusAtRegister == [.notRegistered])
    }

    /// Bleibt der Dienst über die Frist hinaus registriert, wird trotzdem registriert (statt endlos zu warten).
    @Test func reinstallRegistersAfterDeadlineWhenServiceStaysRegistered() async throws {
        let service = FakeDaemonService(status: .enabled, statusAfterRegister: .enabled, statusAfterUnregister: nil)
        #expect(try await manager(service).reinstall() == .ready)
        #expect(service.calls == ["unregister", "register"])
        #expect(service.statusAtRegister == [.enabled])
    }

    /// Unmittelbar nach dem Abmelden lehnt das System die Registrierung mitunter ab („Job is not allowed to
    /// bootstrap“); nach kurzer Pause gelingt sie. Erst dann gilt der laufende Build als registriert.
    @Test func reinstallRetriesFailedRegistrationOnce() async throws {
        try await Self.withRecord(registered: "2026.10.2 (400)") { record throws in
            let service = FakeDaemonService(
                status: .enabled, statusAfterRegister: .enabled, registerErrorsOnce: [Self.serviceError(1)]
            )
            #expect(try await manager(service, registration: record).reinstall() == .ready)
            #expect(service.calls == ["unregister", "register", "register"])
            #expect(record.registeredBuild == "2026.10.3 (412)")
        }
    }

    /// Nach einem Bundle-Austausch kann der Dienst auf Genehmigung warten oder nicht gefunden werden; auch dann wird
    /// neu registriert und der laufende Build vermerkt.
    @Test(arguments: [SMAppService.Status.requiresApproval, .notFound])
    func reinstallFromInactiveServiceRegistersAndRecordsBuild(status: SMAppService.Status) async throws {
        try await Self.withRecord(registered: Self.otherBuild) { record throws in
            let service = FakeDaemonService(status: status, statusAfterRegister: .enabled)
            #expect(try await manager(service, registration: record, timing: Self.patientTiming).reinstall() == .ready)
            #expect(service.calls == ["unregister", "register"])
            #expect(record.registeredBuild == Self.currentBuild)
        }
    }

    /// Ein nicht aktiver Dienst lässt sich mitunter nicht abmelden (etwa `.notFound`); das verhindert die neue
    /// Registrierung nicht.
    @Test(arguments: [SMAppService.Status.requiresApproval, .notFound])
    func reinstallToleratesFailedUnregisterOfInactiveService(status: SMAppService.Status) async throws {
        let service = FakeDaemonService(
            status: status, statusAfterRegister: .enabled, statusAfterUnregister: nil, unregisterError: UnrelatedFailure()
        )
        let clock = ContinuousClock()
        let start = clock.now
        #expect(try await manager(service, timing: Self.patientTiming).reinstall() == .ready)
        #expect(service.calls == ["unregister", "register"])
        // Nicht bis zur Abmeldefrist (60 s) warten: Der Dienst wurde ja nicht abgemeldet.
        #expect(clock.now - start < .seconds(10))
    }

    /// Bei aktivem Dienst bleibt ein gescheitertes Abmelden ein Fehler – der alte Helper liefe sonst weiter.
    @Test func reinstallRethrowsFailedUnregisterOfEnabledService() async {
        let service = FakeDaemonService(status: .enabled, unregisterError: UnrelatedFailure())
        await #expect(throws: UnrelatedFailure()) { try await manager(service).reinstall() }
        #expect(service.calls == ["unregister"])
    }

    @Test func reinstallGivesUpAfterSecondFailedRegistration() async {
        await Self.withRecord(registered: "2026.10.2 (400)") { record in
            let service = FakeDaemonService(
                status: .enabled, statusAfterRegister: .enabled, registerErrorsOnce: [UnrelatedFailure(), UnrelatedFailure()]
            )
            await #expect(throws: UnrelatedFailure()) { try await manager(service, registration: record).reinstall() }
            #expect(service.calls == ["unregister", "register", "register"])
            #expect(record.registeredBuild == "2026.10.2 (400)")
        }
    }

    /// Erneuern nach App-Austausch: Scheitert es endgültig, nennt der Fehler Grund und Abhilfe („Installieren“).
    @Test func failedRenewalExplainsReasonAndRemedy() async {
        await Self.withRecord(registered: "2026.10.2 (400)") { record in
            let service = FakeDaemonService(
                status: .enabled, statusAfterRegister: .enabled, registerErrorsOnce: [ProbeFailure(), ProbeFailure()]
            )
            do {
                _ = try await manager(service, registration: record).renewRegistration()
                Issue.record("Erneuern hätte scheitern müssen")
            } catch {
                #expect(error is HelperRenewalError)
                #expect(error.readableDescription.contains("Verbindung abgelehnt"))
                #expect(error.readableDescription.contains("„Installieren“"))
            }
            #expect(record.registeredBuild == "2026.10.2 (400)")
        }
    }

    @Test func renewalReinstallsAndRecordsBuild() async throws {
        try await Self.withRecord(registered: "2026.10.2 (400)") { record throws in
            let service = FakeDaemonService(
                status: .enabled, statusAfterRegister: .enabled, registerErrorsOnce: [Self.serviceError(1)],
                unregisterSettlesAfterReads: 2
            )
            let manager = manager(service, registration: record, timing: Self.patientTiming)
            #expect(try await manager.renewRegistration() == .ready)
            #expect(service.calls == ["unregister", "register", "register"])
            #expect(record.registeredBuild == "2026.10.3 (412)")
            #expect(manager.registrationRenewal.renewal == .skip(.recordCurrent))
        }
    }

    @Test func currentBuildCombinesVersionAndBuildNumber() {
        #expect(HelperRegistrationRecord.build(info: ["CFBundleShortVersionString": "2026.10.3", "CFBundleVersion": "412"])
            == "2026.10.3 (412)")
        #expect(HelperRegistrationRecord.build(info: [:]) == "? (?)")
    }

    /// Der Build auf der Platte stammt aus `Contents/Info.plist`; ohne lesbare Datei `nil`.
    @Test func buildOnDiskReadsInfoPlist() throws {
        let bundle = FileManager.default.temporaryDirectory.appending(path: "HelperManagerTests-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: bundle) }
        #expect(HelperRegistrationRecord.buildOnDisk(bundleURL: bundle) == nil)
        let contents = bundle.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundleShortVersionString": "2026.10.4", "CFBundleVersion": "420"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        #expect(HelperRegistrationRecord.buildOnDisk(bundleURL: bundle) == "2026.10.4 (420)")
    }

    @Test func unregisterForwardsToService() async throws {
        let service = FakeDaemonService(status: .enabled)
        try await manager(service).unregister()
        #expect(service.calls == ["unregister"])
    }
}
