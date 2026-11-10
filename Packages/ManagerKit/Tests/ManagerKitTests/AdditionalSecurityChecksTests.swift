import Foundation
import Testing
@testable import ManagerKit

/// Automatische Anmeldung aus den Anmeldefenster-Einstellungen (#409).
@Suite struct AutomaticLoginCheckTests {
    @Test(arguments: [
        ("loginwindow-autologin-on.plist", true), ("loginwindow-autologin-off.plist", false),
        ("loginwindow-autologin-empty.plist", false),
    ])
    func parsesAutoLoginUser(fixture: String, enabled: Bool) throws {
        #expect(try SecurityParsers.automaticLogin(preferences: securityFixtureData(fixture)) == .automaticLogin(enabled: enabled))
    }

    /// Ohne Datei gibt es kein `autoLoginUser` – das Anmeldefenster liest ihn nur dort.
    @Test func missingPreferencesMeanOff() throws {
        #expect(try SecurityParsers.automaticLogin(preferences: nil) == .automaticLogin(enabled: false))
    }

    @Test func unparseablePreferencesThrow() {
        #expect(throws: SecurityParseError.unreadablePreferences(path: LoginWindowProbe.preferencesPath)) {
            try SecurityParsers.automaticLogin(preferences: Data("kaputt".utf8))
        }
    }

    @Test func enabledIsCriticalOffIsGood() {
        #expect(SecurityPolicy.standard.evaluate(.automaticLogin(enabled: true), now: TestData.date) == .critical)
        #expect(SecurityPolicy.standard.evaluate(.automaticLogin(enabled: false), now: TestData.date) == .good)
    }

    @Test func sourceEvaluatesTheProbe() async throws {
        let data = try securityFixtureData("loginwindow-autologin-on.plist")
        let source = SecurityPostureSource(probes: [LoginWindowProbe(readPreferences: { data })], now: { TestData.date })
        let check = try #require(try await source.collect().securityChecks.first)
        #expect(check.kind == .automaticLogin && check.state == .critical && check.facts == .automaticLogin(enabled: true))
    }

    /// Nicht lesbar → `unknown` mit Grund und Einschränkung, nie „in Ordnung“.
    @Test func unreadableFileMarksTheCheckUnknown() async throws {
        let source = SecurityPostureSource(
            probes: [LoginWindowProbe(readPreferences: { throw CocoaError(.fileReadNoPermission) })], now: { TestData.date }
        )
        let contribution = try await source.collect()
        let check = try #require(contribution.securityChecks.first)
        #expect(check.kind == .automaticLogin && check.state == .unknown && check.detail != nil)
        #expect(contribution.retryableLimitations.count == 1)
        #expect(contribution.retryableLimitations.first?.hasPrefix("Automatische Anmeldung nicht geprüft") == true)
    }

    @Test func loginWindowPreferencesTriggerAScan() {
        #expect(SecurityPostureSource.watchedFiles.contains(LoginWindowProbe.preferencesPath))
    }
}

/// Aktive Freigabedienste aus den lauschenden Netzwerkdiensten (#409).
@Suite struct SharingServiceDetectionTests {
    private func launchd(_ port: UInt16?, transport: SocketTransport = .tcp, addresses: [String] = ["::", "0.0.0.0"]) -> NetworkListener {
        TestData.listener("/sbin/launchd", uid: 0, transport: transport, port: port, addresses: addresses,
                          signing: SigningInfo(kind: .apple))
    }

    @Test(arguments: [
        (UInt16(5900), SharingService.screenSharing), (445, .fileSharing), (548, .fileSharing), (22, .remoteLogin),
    ])
    func wellKnownPortIsDetected(port: UInt16, service: SharingService) {
        #expect(SharingService.active(in: [launchd(port)]) == [service])
    }

    @Test func severalServicesAtOnce() {
        let listeners = [launchd(22), launchd(445), launchd(5900), TestData.listener(port: 3000)]
        #expect(SharingService.active(in: listeners) == [.remoteLogin, .fileSharing, .screenSharing])
    }

    /// Auch ein Dienst eines Drittanbieters auf dem Port (etwa sshd aus Homebrew) nimmt Verbindungen an.
    @Test func otherProgramOnTheSamePortCounts() {
        #expect(SharingService.active(in: [TestData.listener("/opt/homebrew/sbin/sshd", uid: 0, port: 22)]) == [.remoteLogin])
    }

    @Test func loopbackUDPVariableAndOtherPortsDoNotCount() {
        let listeners = [
            launchd(5900, addresses: ["127.0.0.1", "::1"]), launchd(445, transport: .udp), launchd(nil),
            launchd(5000), launchd(88),
        ]
        #expect(SharingService.active(in: listeners).isEmpty)
    }

    @Test func noneIsGoodAnyIsAHint() {
        #expect(SecurityPolicy.standard.evaluate(.sharingServices(active: []), now: TestData.date) == .good)
        #expect(SecurityPolicy.standard.evaluate(.sharingServices(active: [.remoteLogin]), now: TestData.date) == .warning)
    }
}

/// Ableitung der Prüfung „Freigabedienste“ im Snapshot: kein eigener Scan, nur die vorhandenen Lauscher.
@Suite struct SharingServicesCheckTests {
    private let now = TestData.date
    private let screenSharing = TestData.listener("/sbin/launchd", uid: 0, port: 5900, signing: SigningInfo(kind: .apple))

    private func snapshot(
        _ listeners: [NetworkListener], complete: Bool = true, checks: [SecurityCheck] = [],
        errors: [SourceError] = [], limitations: [SourceLimitation] = []
    ) -> Snapshot {
        Snapshot(takenAt: now, grants: [], autostartItems: [], securityChecks: checks, networkListeners: listeners,
                 sourceErrors: errors, sourceLimitations: limitations, baselineSources: TestData.networkSources,
                 hasCompleteListenerBaseline: complete)
    }

    private func derived(_ snapshot: Snapshot, previous: Snapshot? = nil) -> Snapshot {
        snapshot.derivingSharingServicesCheck(from: previous, policy: .standard, now: now)
    }

    private func sharingCheck(_ snapshot: Snapshot) throws -> SecurityCheck {
        try #require(snapshot.securityChecks.first { $0.kind == .sharingServices })
    }

    @Test func noSharingServiceIsGood() throws {
        let check = try sharingCheck(derived(snapshot([TestData.listener()])))
        #expect(check.state == .good && check.facts == .sharingServices(active: []))
    }

    @Test func screenSharingIsAHint() throws {
        let check = try sharingCheck(derived(snapshot([screenSharing])))
        #expect(check.state == .warning && check.facts == .sharingServices(active: [.screenSharing]))
    }

    /// Ohne vollständige Lauscher-Baseline (nie alle Benutzer gelesen) keine Entwarnung.
    @Test func withoutCompleteListenerBaselineTheCheckIsUnknown() throws {
        let result = derived(snapshot([], complete: false))
        let check = try sharingCheck(result)
        #expect(check.state == .unknown && check.facts == nil)
        #expect(result.sourceLimitations.filter { $0.source == .securityPosture }.map(\.isRetryable) == [true])
        #expect(result.sourceLimitations.first?.message.hasPrefix("Freigabedienste nicht geprüft: ") == true)
    }

    /// Ausgefallene Lauscher-Quelle: `unknown` mit der letzten bekannten Ampel und den Fakten des Vorgängers.
    @Test func failedListenerSourceKeepsTheLastKnownState() throws {
        let previous = derived(snapshot([screenSharing]))
        let failed = snapshot([screenSharing], checks: previous.securityChecks,
                              errors: [SourceError(source: .networkListeners, message: "Zeitüberschreitung")])
        let check = try sharingCheck(derived(failed, previous: previous))
        #expect(check.state == .unknown && check.lastKnownState == .warning)
        #expect(check.facts == .sharingServices(active: [.screenSharing]))
        #expect(check.detail?.contains("Zeitüberschreitung") == true)
    }

    /// Ohne Helper liest die Lauscher-Quelle nur eigene Dienste; die Freigabedienste laufen aber als root.
    @Test func incompleteListenerScanMakesTheCheckUnknown() throws {
        let message = "\(NetworkListenerSource.limitationPrefix) – Helper nicht erreichbar"
        let limited = snapshot([], limitations: [SourceLimitation(source: .networkListeners, message: message, isRetryable: true)])
        let check = try sharingCheck(derived(limited))
        #expect(check.state == .unknown && check.detail == message)
    }

    /// Ein nicht behebbarer Hinweis der Lauscher-Quelle (geschützte Prozesse) macht die Prüfung nicht unbrauchbar.
    @Test func deniedProcessesDoNotBlockTheCheck() throws {
        let denied = snapshot([screenSharing], limitations: [
            SourceLimitation(source: .networkListeners, message: NetworkListenerSource.deniedProcessLimitations(2)[0]),
        ])
        #expect(try sharingCheck(derived(denied)).state == .warning)
    }

    /// Erneutes Ableiten (Teilscan ohne Änderung) ersetzt Prüfung und Einschränkung, statt sie zu verdoppeln.
    @Test func derivingIsIdempotent() {
        let once = derived(snapshot([], complete: false))
        let twice = derived(once, previous: once)
        #expect(twice.securityChecks == once.securityChecks)
        #expect(twice.sourceLimitations == once.sourceLimitations)
        #expect(derived(twice, previous: twice) == twice)
    }

    /// Wieder lesbar: Die Einschränkung der vorigen Ableitung fällt weg.
    @Test func recoveredListenerScanDropsTheLimitation() throws {
        let unknown = derived(snapshot([], complete: false))
        let recovered = derived(snapshot([], checks: unknown.securityChecks, limitations: unknown.sourceLimitations),
                                previous: unknown)
        #expect(try sharingCheck(recovered).state == .good)
        #expect(recovered.sourceLimitations.isEmpty)
    }

    @Test func checksStayInDisplayOrder() {
        let checks = [TestData.evaluatedCheck(.mdmEnrollment(enrolled: false, viaDEP: false)),
                      TestData.evaluatedCheck(.fileVault(.on))]
        let kinds = derived(snapshot([], checks: checks)).securityChecks.map(\.kind)
        #expect(kinds == SecurityCheckKind.allCases.filter(kinds.contains))
    }
}

/// Verdrahtung im `ScanCoordinator` und Laden alter Snapshots.
@Suite struct AdditionalSecurityChecksScanTests {
    private let launchd = TestData.listener("/sbin/launchd", uid: 0, port: 22, signing: SigningInfo(kind: .apple))
    private let fileVault = TestData.evaluatedCheck(.fileVault(.on))

    private func coordinator(listeners: [NetworkListener], includeListeners: Bool = true, at date: Date = TestData.date) -> ScanCoordinator {
        let security = FixedSource(id: .securityPosture, result: .success(InventoryContribution(securityChecks: [fileVault])))
        let network = FixedSource(id: .networkListeners, result: .success(InventoryContribution(networkListeners: listeners)))
        return ScanCoordinator(sources: includeListeners ? [security, network] : [security], currentUID: 501, now: { date })
    }

    @Test func fullScanDerivesTheSharingCheck() async throws {
        let snapshot = try await coordinator(listeners: [launchd]).scan()
        #expect(snapshot.securityChecks.map(\.kind) == [.fileVault, .sharingServices])
        #expect(snapshot.securityChecks.last?.facts == .sharingServices(active: [.remoteLogin]))
    }

    @Test func withoutListenerSourceThereIsNoSharingCheck() async throws {
        let snapshot = try await coordinator(listeners: [], includeListeners: false).scan()
        #expect(snapshot.securityChecks.map(\.kind) == [.fileVault])
    }

    /// Ein Teilscan nur der Lauscher (60-s-Takt) aktualisiert die Prüfung; die Verschlechterung meldet sich.
    @Test func listenerPartialScanUpdatesTheCheckAndNotifies() async throws {
        let full = try await coordinator(listeners: []).scan()
        let partial = try await coordinator(listeners: [launchd], at: TestData.date + 60)
            .scan(previous: full, only: [.networkListeners])
        let check = try #require(partial.securityChecks.first { $0.kind == .sharingServices })
        #expect(check.state == .warning)
        let events = SnapshotDiffer().diff(from: full, to: partial).filter {
            if case .securityCheck = $0.subject { true } else { false }
        }
        #expect(events.map(\.kind) == [.modified])
        #expect(events.allSatisfy(NotificationPolicy().shouldNotify))
    }

    /// Snapshot einer Version vor #409 (ohne die neuen Prüfungen) lädt und dient als Vorgänger des nächsten Scans.
    @Test func snapshotFromBeforeTheNewChecksLoads() async throws {
        let old = try JSONDecoder().decode(Snapshot.self, from: securityFixtureData("snapshot-before-tm409.json"))
        #expect(old.securityChecks.map(\.kind) == [.fileVault, .firewall, .sip, .mdmEnrollment])
        #expect(old.securityChecks.first { $0.kind == .sip }?.lastKnownState == .good)

        let next = try await coordinator(listeners: old.networkListeners, at: TestData.date + 60).scan(previous: old)
        #expect(next.securityChecks.first { $0.kind == .sharingServices }?.facts == .sharingServices(active: [.screenSharing]))
        let added = SnapshotDiffer().diff(from: old, to: next).filter { $0.kind == .added }
        #expect(!added.contains(where: NotificationPolicy().shouldNotify))
    }

    @Test func newFactsRoundTrip() throws {
        let checks = [
            TestData.evaluatedCheck(.automaticLogin(enabled: true)),
            TestData.evaluatedCheck(.sharingServices(active: [.screenSharing, .remoteLogin])),
        ]
        let snapshot = Snapshot(takenAt: TestData.date, grants: [], autostartItems: [], securityChecks: checks, sourceErrors: [])
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.securityChecks == checks)
    }
}

/// Ton und Erklärung der neuen Prüfungen im Bereich „Sicherheit“.
@Suite struct AdditionalSecurityChecksPresentationTests {
    private func row(_ facts: SecurityFacts) -> SecurityCheckPresentation {
        SecurityCheckPresentation(TestData.evaluatedCheck(facts), now: TestData.date)
    }

    @Test func automaticLoginOnIsCriticalAndLinksToUsers() throws {
        let presentation = row(.automaticLogin(enabled: true))
        #expect(presentation.title == "Automatische Anmeldung")
        #expect(presentation.statusText == "Kritisch" && presentation.tone == .critical)
        #expect(presentation.summary.contains("ohne Passwort"))
        let url = try #require(SecuritySettingsLinks.usersAndGroups)
        #expect(presentation.offers == [.link(title: "Benutzer & Gruppen öffnen", url: url)])
    }

    @Test func automaticLoginOff() {
        let presentation = row(.automaticLogin(enabled: false))
        #expect(presentation.tone == .positive && presentation.offers.isEmpty)
        #expect(presentation.summary == "Die automatische Anmeldung ist aus – beim Start fragt der Mac nach dem Passwort.")
    }

    @Test func activeSharingServicesAreNamed() throws {
        let presentation = row(.sharingServices(active: [.screenSharing, .remoteLogin]))
        #expect(presentation.title == "Freigabedienste")
        #expect(presentation.statusText == "Hinweis" && presentation.tone == .warning)
        #expect(presentation.summary == "Aktiv: Bildschirmfreigabe, Entfernte Anmeldung – andere Geräte im Netzwerk können sich verbinden.")
        #expect(presentation.details == ["Bildschirmfreigabe (Port 5900)", "Entfernte Anmeldung (Port 22)"])
        let url = try #require(SecuritySettingsLinks.sharing)
        #expect(presentation.offers == [.link(title: "Freigaben öffnen", url: url)])
    }

    @Test func noSharingService() {
        let presentation = row(.sharingServices(active: []))
        #expect(presentation.tone == .positive && presentation.offers.isEmpty && presentation.details.isEmpty)
        #expect(presentation.summary == "Bildschirmfreigabe, Dateifreigabe und entfernte Anmeldung sind aus.")
    }

    @Test func fileSharingNamesBothPorts() {
        #expect(row(.sharingServices(active: [.fileSharing])).details == ["Dateifreigabe (Port 445, 548)"])
    }
}
