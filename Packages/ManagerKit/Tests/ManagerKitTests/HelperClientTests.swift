import Testing
import Foundation
import Synchronization
import TestSupport
import HelperCore
@testable import ManagerKit

/// Echte XPC-Round-Trips gegen einen `HelperService` hinter einem anonymen Listener im Testprozess.
@Suite struct HelperClientTests {
    /// Anonymer Listener mit exportiertem Helper-Objekt. Absichtlich nicht `Sendable`
    /// (`NSXPCListener` ist es nicht).
    private final class Harness {
        let listener: NSXPCListener
        let delegate: any NSXPCListenerDelegate

        init(delegate: any NSXPCListenerDelegate) {
            self.delegate = delegate
            listener = NSXPCListener.anonymous()
            listener.delegate = delegate
            listener.resume()
        }

        convenience init(service: HelperService) {
            self.init(delegate: HelperListenerDelegate(service: service, isAuthorized: { _ in true }))
        }

        convenience init(runner: MockCommandRunner) {
            self.init(service: HelperService(runner: runner))
        }

        /// Helper, der nur `protocolVersion` (mit `version`) und – sofern `sockets` gesetzt ist – die Socket-Abfrage
        /// beantwortet und alle anderen Aufrufe hängen lässt.
        static func silent(version: Int = HelperXPC.protocolVersion, sockets: ListeningSocketScan? = nil) -> Harness {
            Harness(delegate: SilentHelperExporter(helper: SilentHelper(version: version, sockets: sockets)))
        }

        /// Helper, dessen Socket-Abfrage `result` liefert.
        convenience init(sockets result: Result<ListeningSocketScan, ListeningSocketError>) {
            self.init(service: HelperService(runner: MockCommandRunner(), socketEnumerator: FixedSockets(result: result)))
        }

        /// Der exportierte `SilentHelper` eines mit `silent()` erzeugten Harness.
        var silentHelper: SilentHelper? { (delegate as? SilentHelperExporter)?.helper }

        deinit { listener.invalidate() }

        func client(
            callTimeout: Duration = .seconds(45),
            removalTimeout: Duration = .seconds(105),
            dumpTimeout: Duration = .seconds(75),
            hardeningTimeout: @escaping @Sendable (SecurityHardening) -> Duration = HelperClient.hardeningTimeout(for:),
            socketTimeout: Duration = .seconds(10),
            connections: ConnectionCounter? = nil,
            idleClock: TestClock = TestClock()
        ) -> HelperClient {
            let endpoint = listener.endpoint
            return HelperClient(makeConnection: {
                connections?.increment()
                return NSXPCConnection(listenerEndpoint: endpoint)
            }, callTimeout: callTimeout, removalTimeout: removalTimeout, dumpTimeout: dumpTimeout, hardeningTimeout: hardeningTimeout,
               socketTimeout: socketTimeout, idleTimeout: .seconds(60), idleClock: idleClock)
        }
    }

    /// Endpoint eines nie gestarteten Listeners: Nachrichten dorthin bleiben unbeantwortet liegen – wie bei einem
    /// Helper, den launchd nicht starten kann (`spawn failed`, etwa „needs LWCR update“ nach einem App-Austausch).
    private final class UnresponsiveEndpoint {
        private let listener = NSXPCListener.anonymous()
        var endpoint: NSXPCListenerEndpoint { listener.endpoint }
        deinit { listener.invalidate() }
    }

    /// Zählt, wie oft die Verbindungsfabrik aufgerufen wurde.
    private final class ConnectionCounter: Sendable {
        private let count = Mutex(0)
        var value: Int { count.withLock { $0 } }
        func increment() { count.withLock { $0 += 1 } }
    }

    /// Exportiert einen `SilentHelper` auf jeder angenommenen Verbindung.
    private final class SilentHelperExporter: NSObject, NSXPCListenerDelegate {
        let helper: SilentHelper

        init(helper: SilentHelper) { self.helper = helper }

        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            connection.exportedInterface = HelperXPC.makeInterface()
            connection.exportedObject = helper
            connection.resume()
            return true
        }
    }

    /// Lebender, aber hängender Helper: Antwortet nur auf `protocolVersion` und – mit `sockets` – auf
    /// `listListeningSockets`. Alle anderen Reply-Blöcke werden festgehalten (nie aufgerufen, nie freigegeben), damit
    /// XPC keine Antwort erzeugt.
    private final class SilentHelper: NSObject, GrantryHelperXPC, Sendable {
        private let pendingReplies = Mutex<[any Sendable]>([])
        private let version: Int
        private let sockets: ListeningSocketScan?
        private let versionQueryCount = Mutex(0)

        init(version: Int, sockets: ListeningSocketScan?) {
            self.version = version
            self.sockets = sockets
        }

        /// Anzahl empfangener Versionsabfragen.
        var versionQueries: Int { versionQueryCount.withLock { $0 } }

        /// Anzahl empfangener Operationen (alles außer `protocolVersion`).
        var receivedOperations: Int { pendingReplies.withLock { $0.count } }

        private func hold(_ reply: any Sendable) { pendingReplies.withLock { $0.append(reply) } }

        func protocolVersion(reply: @escaping @Sendable (Int) -> Void) {
            versionQueryCount.withLock { $0 += 1 }
            reply(version)
        }
        func dumpBTM(reply: @escaping @Sendable (String?, String?) -> Void) { hold(reply) }
        func listListeningSockets(reply: @escaping @Sendable (Data?, String?) -> Void) {
            guard let sockets else { return hold(reply) }
            reply(try? JSONEncoder().encode(sockets), nil)
        }
        func setEnabled(plistPath: String, enabled: Bool, reply: @escaping @Sendable (String?) -> Void) { hold(reply) }
        func bootout(plistPath: String, reply: @escaping @Sendable (String?) -> Void) { hold(reply) }
        func bootstrap(plistPath: String, reply: @escaping @Sendable (String?) -> Void) { hold(reply) }
        func unloadAndRemovePlist(path: String, expectedFingerprint: Data?, reply: @escaping @Sendable (String?, Bool, String?) -> Void) {
            hold(reply)
        }
        func restorePlist(backupPath: String, reply: @escaping @Sendable (String?, String?) -> Void) { hold(reply) }
        func enableFirewall(reply: @escaping @Sendable (String?) -> Void) { hold(reply) }
        func enableStealthMode(reply: @escaping @Sendable (String?) -> Void) { hold(reply) }
        func enableGatekeeper(reply: @escaping @Sendable (String?) -> Void) { hold(reply) }
        func enableAutomaticUpdates(reply: @escaping @Sendable (String?) -> Void) { hold(reply) }
        func updateXProtect(reply: @escaping @Sendable (String?) -> Void) { hold(reply) }
        func terminateProcess(
            pid: Int32, executablePath: String, startTime: UInt64, force: Bool, reply: @escaping @Sendable (String?) -> Void
        ) { hold(reply) }
    }

    /// Endpoint eines bereits invalidierten Listeners: Verbindungen dorthin scheitern sofort. Der Listener muss vor dem
    /// Invalidieren gestartet sein – sonst bleiben Nachrichten an den Endpoint unbeantwortet liegen.
    private static func deadEndpoint() -> NSXPCListenerEndpoint {
        let listener = NSXPCListener.anonymous()
        listener.resume()
        let endpoint = listener.endpoint
        listener.invalidate()
        return endpoint
    }

    private static func isRejected(_ error: any Error) -> Bool {
        if case .rejected = error as? HelperClientError { true } else { false }
    }

    private static func isUnavailable(_ error: any Error) -> Bool {
        if case .unavailable = error as? HelperClientError { true } else { false }
    }

    @Test func protocolVersionMatchesHelper() async throws {
        let harness = Harness(runner: MockCommandRunner())
        #expect(try await harness.client().protocolVersion() == HelperXPC.protocolVersion)
    }

    @Test func dumpBTMReturnsHelperOutput() async throws {
        let harness = Harness(runner: MockCommandRunner([
            "/usr/bin/sfltool dumpbtm": CommandResult(exitCode: 0, stdout: "Records for UID 501"),
        ]))
        #expect(try await harness.client().dumpBTM() == "Records for UID 501")
    }

    @Test func failingDumpBecomesDumpFailed() async {
        let harness = Harness(runner: MockCommandRunner([
            "/usr/bin/sfltool dumpbtm": CommandResult(exitCode: 1, stdout: "", stderr: "boom"),
        ]))
        await #expect(throws: BTMSourceError.dumpFailed("sfltool dumpbtm fehlgeschlagen (Exit 1): boom")) {
            _ = try await harness.client().dumpBTM()
        }
    }

    @Test func listeningSocketsDecodesHelperScan() async throws {
        let expected = ListeningSocketScan(sockets: [ListeningSocket(
            pid: 7, uid: 0, executablePath: "/usr/local/bin/mcp", transport: .tcp, localAddress: "0.0.0.0", localPort: 8080
        )], deniedProcessCount: 1)
        let harness = Harness(sockets: .success(expected))
        #expect(try await harness.client().listeningSockets() == expected)
    }

    @Test func failingSocketScanIsRejectedWithHelperMessage() async {
        let failure = ListeningSocketError(code: EPERM)
        let harness = Harness(sockets: .failure(failure))
        await #expect(throws: HelperClientError.rejected(failure.errorDescription ?? "")) {
            _ = try await harness.client().listeningSockets()
        }
    }

    private static let someSockets = ListeningSocketScan(sockets: [ListeningSocket(
        pid: 7, uid: 501, executablePath: "/usr/local/bin/mcp", transport: .tcp, localAddress: "127.0.0.1", localPort: 3000
    )])

    @Test func outdatedHelperIsNotAskedForSockets() async throws {
        let harness = Harness.silent(version: HelperXPC.listeningSocketsMinimumVersion - 1)
        await #expect(throws: HelperClientError.outdated) { _ = try await harness.client().listeningSockets() }
        #expect(try #require(harness.silentHelper).receivedOperations == 0)
        #expect(HelperClientError.outdated.localizedDescription == "Helper veraltet – bitte neu installieren")
    }

    // MARK: Prozess beenden (Protokoll 4)

    @Test func outdatedHelperIsNotAskedToTerminate() async {
        let harness = Harness.silent(version: HelperXPC.terminateProcessMinimumVersion - 1)
        await #expect(throws: HelperClientError.outdated) {
            try await harness.client().terminateProcess(
                pid: 4242, executablePath: "/usr/local/sbin/listener", startTime: 1, force: false
            )
        }
        #expect(harness.silentHelper?.receivedOperations == 0)
    }

    private static func terminatingService(_ processes: [RunningProcess], signaler: RecordingSignaler, ownPID: pid_t = 555)
        -> HelperService {
        HelperService(
            runner: MockCommandRunner(),
            terminationPolicy: ProcessTerminationPolicy(
                inspector: FixedProcessInspector(processes), appleSignature: FixedAppleSignature(.notApple),
                ownPID: ownPID, protectedBundlePaths: []
            ),
            processSignaler: signaler
        )
    }

    @Test func terminateProcessRoundTrip() async throws {
        let signaler = RecordingSignaler()
        let target = RunningProcess(pid: 4242, uid: 0, executablePath: "/usr/local/sbin/listener", startTime: 1)
        let harness = Harness(service: Self.terminatingService([target], signaler: signaler))
        try await harness.client().terminateProcess(
            pid: 4242, executablePath: target.executablePath, startTime: target.startTime, force: true
        )
        #expect(signaler.sent == [.init(signal: .kill, pid: 4242)])
    }

    /// Der echte Aufrufer (`NSXPCConnection.current()`) ist geschützt – hier der Testprozess selbst. `ownPID` ist
    /// bewusst eine andere PID, damit allein die Aufrufer-Prüfung greift; der `RecordingSignaler` sendet nie wirklich.
    @Test func callerOfTheConnectionIsProtected() async {
        let signaler = RecordingSignaler()
        let me = RunningProcess(pid: getpid(), uid: getuid(), executablePath: "/tmp/grantry-test-runner", startTime: 1)
        let harness = Harness(service: Self.terminatingService([me], signaler: signaler, ownPID: 2))
        await #expect(throws: HelperClientError.rejected("Prozess \(getpid()) ist geschützt und wird nicht beendet")) {
            try await harness.client().terminateProcess(
                pid: getpid(), executablePath: me.executablePath, startTime: me.startTime, force: false
            )
        }
        #expect(signaler.sent.isEmpty)
    }

    /// Ein Lesezugriff funktioniert auch mit einem neueren Helper.
    @Test func newerHelperIsAskedForSockets() async throws {
        let harness = Harness.silent(version: HelperXPC.protocolVersion + 1, sockets: Self.someSockets)
        #expect(try await harness.client().listeningSockets() == Self.someSockets)
    }

    /// Über eine bereits geprüfte Verbindung fragt der Client die Version nicht erneut ab.
    @Test func socketQueriesReuseTheConnectionsVersion() async throws {
        let harness = Harness.silent(sockets: Self.someSockets)
        let client = harness.client()
        _ = try await client.listeningSockets()
        _ = try await client.listeningSockets()
        #expect(try #require(harness.silentHelper).versionQueries == 1)
    }

    @Test func stuckSocketQueryUsesItsOwnTimeout() async {
        let harness = Harness.silent()
        let client = harness.client(callTimeout: .seconds(45), socketTimeout: .milliseconds(200))
        let start = ContinuousClock.now
        await #expect(throws: HelperClientError.unavailable("Zeitüberschreitung nach 0,2 s")) {
            _ = try await client.listeningSockets()
        }
        #expect(ContinuousClock.now - start < LatencyBound.wellBeforeLongTimeouts)
    }

    @Test func setEnabledRunsLaunchctlForValidatedDaemon() async throws {
        try await ScratchDirectory.with { dir in
            let daemons = dir.appending(path: "LaunchDaemons")
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: daemons)
            let runner = MockCommandRunner([
                "/bin/launchctl print system/com.example.daemon": CommandResult(exitCode: 113, stdout: "", stderr: "Could not find service"),
                "/bin/launchctl disable system/com.example.daemon": CommandResult(exitCode: 0, stdout: ""),
            ])
            // Ohne Apples echtes LaunchDaemons-Verzeichnis, damit der Test nur das Scratch-Verzeichnis liest.
            let harness = Harness(service: HelperService(runner: runner, launchDaemonsDirectory: daemons.path, additionalDaemonDirectories: []))

            try await harness.client().setEnabled(plistPath: plist.path, enabled: false)

            #expect(runner.calls == ["/bin/launchctl print system/com.example.daemon", "/bin/launchctl disable system/com.example.daemon"])
        }
    }

    @Test(arguments: SecurityHardening.allCases)
    func hardeningRunsFixedCommandsThroughHelper(_ hardening: SecurityHardening) async throws {
        let runner = SecurityHardeningStubs.runnerRequiringAction(for: hardening)
        let harness = Harness(runner: runner)

        try await harness.client().perform(hardening)

        #expect(runner.calls == SecurityHardeningStubs.commandLinesRequiringAction(for: hardening))
    }

    /// Frist = (Befehlsfrist + Gnadenfrist des Runners) × Befehle samt Zustandsabfrage + 15 s.
    @Test func hardeningTimeoutCoversTheHelpersWorstCase() {
        #expect(HelperClient.hardeningTimeout(for: .enableFirewall) == .seconds(79))
        #expect(HelperClient.hardeningTimeout(for: .enableGatekeeper) == .seconds(79))
        #expect(HelperClient.hardeningTimeout(for: .enableAutomaticUpdates) == .seconds(175))
        #expect(HelperClient.hardeningTimeout(for: .updateXProtect) == .seconds(137))
        for hardening in SecurityHardening.allCases {
            #expect(HelperClient.hardeningTimeout(for: hardening) == hardening.maximumDuration + .seconds(15))
        }
    }

    @Test func stuckHardeningUsesTheHardeningTimeout() async {
        let harness = Harness.silent()
        let asked = Mutex<[SecurityHardening]>([])
        let client = harness.client(callTimeout: .seconds(60), hardeningTimeout: { hardening in
            asked.withLock { $0.append(hardening) }
            return .milliseconds(200)
        })
        let start = ContinuousClock.now

        await #expect(throws: HelperClientError.unavailable("Zeitüberschreitung nach 0,2 s")) {
            try await client.perform(.enableFirewall)
        }
        #expect(ContinuousClock.now - start < LatencyBound.wellBeforeLongTimeouts)
        #expect(asked.withLock { $0 } == [.enableFirewall])
    }

    @Test func failedHardeningIsRejectedWithHelperMessage() async {
        let runner = MockCommandRunner([
            "/usr/sbin/spctl --status": CommandResult(exitCode: 0, stdout: "assessments disabled\n"),
            "/usr/sbin/spctl --global-enable": CommandResult(exitCode: 1, stdout: "", stderr: "This operation is no longer supported"),
        ])
        let harness = Harness(runner: runner)
        await #expect(throws: HelperClientError.rejected(
            "/usr/sbin/spctl --global-enable fehlgeschlagen (Exit 1): This operation is no longer supported"
        )) {
            try await harness.client().perform(.enableGatekeeper)
        }
    }

    /// #156, Codex-Runde 3: Der Fingerabdruck aus dem Scan übersteht den Weg über XPC unverändert – mit ihm löscht der
    /// Helper, nach einem Umschreiben der Plist lehnt er ab und lässt sie stehen. #166: Ob der Helper entladen hat,
    /// kommt ebenso an.
    @Test func unloadAndRemovePlistCarriesTheScanFingerprintToTheHelper() async throws {
        try await ScratchDirectory.with { dir in
            let daemons = dir.appending(path: "LaunchDaemons")
            let backups = PlistBackupStore(root: dir.appending(path: "Backups"), managedDirectories: [daemons.path])
            let kept = try LaunchdPlistFixture.write(label: "com.example.kept", in: daemons)
            let removed = try LaunchdPlistFixture.write(label: "com.example.removed", in: daemons)
            let removedPath = removed.resolvingSymlinksInPath().path
            let runner = MockCommandRunner([
                "/bin/launchctl print system/com.example.kept": CommandResult(exitCode: 113, stdout: "", stderr: "Could not find service"),
                "/bin/launchctl print system/com.example.removed": CommandResult(
                    exitCode: 0, stdout: "system/com.example.removed = {\n\tpath = \(removedPath)\n}\n"
                ),
                "/bin/launchctl bootout system \(removedPath)": CommandResult(exitCode: 0, stdout: ""),
            ])
            let harness = Harness(service: HelperService(
                runner: runner, backups: backups, launchDaemonsDirectory: daemons.path, additionalDaemonDirectories: []
            ))
            let keptFingerprint = try #require(FileFingerprint(of: kept.path))
            try LaunchdPlistFixture.overwriteInPlace(kept, payload: ["Label": "com.example.kept", "New": true])
            await #expect(throws: HelperClientError.self) {
                _ = try await harness.client().unloadAndRemovePlist(path: kept.path, expectedFingerprint: keptFingerprint)
            }
            #expect(FileManager.default.fileExists(atPath: kept.path))

            let fingerprint = try #require(FileFingerprint(of: removed.path))
            let removal = try await harness.client().unloadAndRemovePlist(path: removed.path, expectedFingerprint: fingerprint)
            #expect(removal.wasUnloaded)
            #expect(!FileManager.default.fileExists(atPath: removed.path))
        }
    }

    /// #166, Codex-Runde 5: Hängt der Auftrag in der Warteschlange des Helpers und läuft die Frist des Clients ab, ist der
    /// Ausgang unbekannt – der Helper könnte die Plist später noch löschen. Die App lädt den bereits entladenen
    /// Systemagenten dann **nicht** wieder, sondern meldet „Ergebnis unbekannt – bitte neu scannen“.
    @Test func timedOutRemovalAfterBootoutIsNotRolledBack() async throws {
        try await ScratchDirectory.with { dir in
            let plist = try LaunchdPlistFixture.write(label: "com.vendor.agent", in: dir).path
            let probe = "/bin/launchctl print gui/501/com.vendor.agent"
            let bootout = "/bin/launchctl bootout gui/501 \(plist)"
            let runner = MockCommandRunner([
                probe: CommandResult(exitCode: 0, stdout: "gui/501/com.vendor.agent = {\n\tpath = \(plist)\n}\n"),
                bootout: CommandResult(exitCode: 0, stdout: ""),
            ])
            let harness = Harness.silent()
            let actions = AutostartActions(
                runner: runner, privileged: harness.client(removalTimeout: .milliseconds(200)), userBackups: .user(home: dir.path), uid: 501,
                launchAgentDirectories: [dir.path]
            )
            let agent = AutostartItem(
                kind: .launchAgent, domain: .system, label: "com.vendor.agent", program: "/usr/local/bin/agent", programPresence: .present,
                isEnabled: true, isLoaded: true, plistPath: plist, owner: nil, source: .launchd
            )

            await #expect(throws: UnloadedRemovalOutcomeUnknown.self) { _ = try await actions.remove(agent) }
            #expect(runner.calls == [probe, bootout])
            #expect(harness.silentHelper?.receivedOperations == 1)
            #expect(FileManager.default.fileExists(atPath: plist))
        }
    }

    /// Einem Helper vor Protokoll 8 schickt der Client `unloadAndRemovePlist` nicht, sondern meldet ihn als veraltet.
    @Test func unloadAndRemovePlistRequiresACurrentHelper() async throws {
        let harness = Harness.silent(version: HelperXPC.unloadAndRemovePlistMinimumVersion - 1)
        await #expect(throws: HelperClientError.outdated) {
            _ = try await harness.client().unloadAndRemovePlist(path: "/Library/LaunchDaemons/x.plist", expectedFingerprint: nil)
        }
        #expect(harness.silentHelper?.receivedOperations == 0)
    }

    @Test func bootoutOutsideLaunchDaemonsIsRejected() async throws {
        try await ScratchDirectory.with { dir in
            let daemons = dir.appending(path: "LaunchDaemons")
            let outside = try LaunchdPlistFixture.write(label: "com.example.daemon", in: dir.appending(path: "Elsewhere"))
            let runner = MockCommandRunner()
            let harness = Harness(service: HelperService(runner: runner, launchDaemonsDirectory: daemons.path))

            await #expect(throws: HelperClientError.self) {
                do { try await harness.client().bootout(plistPath: outside.path) } catch {
                    #expect(Self.isRejected(error))
                    throw error
                }
            }
            #expect(runner.calls.isEmpty)
        }
    }

    @Test func bootoutOfAppleLabelIsRejected() async throws {
        try await ScratchDirectory.with { dir in
            let daemons = dir.appending(path: "LaunchDaemons")
            let plist = try LaunchdPlistFixture.write(label: "com.apple.screensharing", named: "innocent.plist", in: daemons)
            let runner = MockCommandRunner()
            let harness = Harness(service: HelperService(runner: runner, launchDaemonsDirectory: daemons.path))

            await #expect(throws: HelperClientError.self) {
                do { try await harness.client().bootout(plistPath: plist.path) } catch {
                    #expect(Self.isRejected(error))
                    throw error
                }
            }
            #expect(runner.calls.isEmpty)
        }
    }

    @Test func unreachableHelperBecomesUnavailable() async {
        let endpoint = Self.deadEndpoint()
        let client = HelperClient(makeConnection: { NSXPCConnection(listenerEndpoint: endpoint) })
        await #expect(throws: HelperClientError.self) {
            do { _ = try await client.protocolVersion() } catch {
                #expect(Self.isUnavailable(error))
                throw error
            }
        }
    }

    @Test func unreachableHelperMakesBTMDumpFailAsHelperUnavailable() async {
        let endpoint = Self.deadEndpoint()
        let provider: any BTMDumpProviding = HelperClient(makeConnection: { NSXPCConnection(listenerEndpoint: endpoint) })
        await #expect(throws: BTMSourceError.helperUnavailable) { _ = try await provider.dumpBTM() }
    }

    @Test func reconnectsAfterConnectionIsInvalidated() async throws {
        let harness = Harness(runner: MockCommandRunner())
        // Erste Verbindung geht ins Leere (wird invalidiert), jede weitere erreicht den Helper.
        let endpoints = (dead: Self.deadEndpoint(), live: harness.listener.endpoint)
        let connections = ConnectionCounter()
        let client = HelperClient(makeConnection: {
            let isFirst = connections.value == 0
            connections.increment()
            return NSXPCConnection(listenerEndpoint: isFirst ? endpoints.dead : endpoints.live)
        })

        await #expect(throws: HelperClientError.self) { _ = try await client.protocolVersion() }
        #expect(try await client.protocolVersion() == HelperXPC.protocolVersion)
        #expect(connections.value == 2)
    }

    @Test func reusesHealthyConnection() async throws {
        let harness = Harness(runner: MockCommandRunner())
        let connections = ConnectionCounter()
        let client = harness.client(connections: connections)

        _ = try await client.protocolVersion()
        _ = try await client.protocolVersion()
        #expect(connections.value == 1)
    }

    @Test func conformsToHelperProtocols() {
        let client = HelperClient()
        #expect((client as Any) is any BTMDumpProviding)
        #expect((client as Any) is any PrivilegedAutostartControlling)
        #expect((client as Any) is any PrivilegedSecurityControlling)
        #expect((client as Any) is any ListeningSocketProviding)
    }

    @Test func stuckHelperTimesOutAsUnavailableAndReconnects() async throws {
        let harness = Harness.silent()
        let connections = ConnectionCounter()
        let client = harness.client(callTimeout: .milliseconds(200), connections: connections)
        let start = ContinuousClock.now

        await #expect(throws: HelperClientError.unavailable("Zeitüberschreitung nach 0,2 s")) {
            try await client.bootout(plistPath: "/Library/LaunchDaemons/x.plist")
        }

        #expect(ContinuousClock.now - start < LatencyBound.wellBeforeLongTimeouts)
        #expect(try await client.protocolVersion() == HelperXPC.protocolVersion)
        #expect(connections.value == 2)
    }

    // MARK: - Erreichbarkeit

    /// Startet launchd den Helper nicht, scheitert der Aufruf nach der kurzen Erreichbarkeitsfrist statt nach der Frist
    /// der Operation; danach scheitern Aufrufe während der Abklingzeit sofort, ohne neue Verbindung. Erst nach ihrem
    /// Ablauf wird es erneut versucht.
    @Test(.timeLimit(.minutes(1))) func unresponsiveHelperFailsFastAndCoolsDown() async throws {
        let unresponsive = UnresponsiveEndpoint()
        let endpoint = unresponsive.endpoint
        let connections = ConnectionCounter()
        let clock = TestClock()
        let client = HelperClient(makeConnection: {
            connections.increment()
            return NSXPCConnection(listenerEndpoint: endpoint)
        }, dumpTimeout: .seconds(60), reachabilityTimeout: .milliseconds(200), unavailableCooldown: .seconds(60),
           cooldownClock: clock)
        let start = ContinuousClock.now

        await #expect(throws: BTMSourceError.helperUnavailable) { _ = try await client.dumpBTM() }
        #expect(ContinuousClock.now - start < LatencyBound.wellBeforeLongTimeouts)
        #expect(connections.value == 1)

        await #expect(throws: HelperClientError.self) {
            do { try await client.bootout(plistPath: "/Library/LaunchDaemons/x.plist") } catch {
                #expect(Self.isUnavailable(error))
                #expect(error.localizedDescription.contains("Zeitüberschreitung nach 0,2 s"))
                throw error
            }
        }
        await #expect(throws: BTMSourceError.helperUnavailable) { _ = try await client.dumpBTM() }
        #expect(connections.value == 1)

        clock.advance(by: .seconds(60))
        await #expect(throws: BTMSourceError.helperUnavailable) { _ = try await client.dumpBTM() }
        #expect(connections.value == 2)
    }

    /// Während der Abklingzeit scheitert die Socket-Abfrage sofort, ohne den Helper erneut anzufragen – anders als
    /// `protocolVersion()`.
    @Test(.timeLimit(.minutes(1))) func socketQueryRespectsCooldown() async throws {
        let unresponsive = UnresponsiveEndpoint()
        let endpoint = unresponsive.endpoint
        let connections = ConnectionCounter()
        let client = HelperClient(makeConnection: {
            connections.increment()
            return NSXPCConnection(listenerEndpoint: endpoint)
        }, reachabilityTimeout: .milliseconds(200), unavailableCooldown: .seconds(60), cooldownClock: TestClock())

        await #expect(throws: HelperClientError.self) { _ = try await client.listeningSockets() }
        #expect(connections.value == 1)

        let start = ContinuousClock.now
        await #expect(throws: HelperClientError.self) {
            do { _ = try await client.listeningSockets() } catch {
                #expect(Self.isUnavailable(error))
                throw error
            }
        }
        #expect(ContinuousClock.now - start < .milliseconds(100))
        #expect(connections.value == 1)
    }

    /// Nach einer erneuten Registrierung (`endCooldown()`) gilt das alte Urteil nicht mehr: Der nächste Aufruf versucht
    /// es sofort, ohne den Ablauf der Abklingzeit abzuwarten.
    @Test(.timeLimit(.minutes(1))) func endCooldownLetsTheNextCallTryAgain() async throws {
        let unresponsive = UnresponsiveEndpoint()
        let endpoint = unresponsive.endpoint
        let connections = ConnectionCounter()
        let client = HelperClient(makeConnection: {
            connections.increment()
            return NSXPCConnection(listenerEndpoint: endpoint)
        }, reachabilityTimeout: .milliseconds(200), unavailableCooldown: .seconds(60), cooldownClock: TestClock())

        await #expect(throws: BTMSourceError.helperUnavailable) { _ = try await client.dumpBTM() }
        await #expect(throws: BTMSourceError.helperUnavailable) { _ = try await client.dumpBTM() }
        #expect(connections.value == 1)

        await client.endCooldown()
        await #expect(throws: BTMSourceError.helperUnavailable) { _ = try await client.dumpBTM() }
        #expect(connections.value == 2)
    }

    /// Die Versionsabfrage (Zustand des Helpers, etwa nach „Neu installieren“) prüft trotz Abklingzeit; antwortet der
    /// Helper wieder, endet die Abklingzeit sofort.
    @Test func protocolVersionProbesDespiteCooldownAndEndsIt() async throws {
        let harness = Harness(runner: MockCommandRunner([
            "/usr/bin/sfltool dumpbtm": CommandResult(exitCode: 0, stdout: "Records"),
        ]))
        let endpoints = (dead: Self.deadEndpoint(), live: harness.listener.endpoint)
        let connections = ConnectionCounter()
        let client = HelperClient(makeConnection: {
            let isFirst = connections.value == 0
            connections.increment()
            return NSXPCConnection(listenerEndpoint: isFirst ? endpoints.dead : endpoints.live)
        }, cooldownClock: TestClock())

        await #expect(throws: BTMSourceError.helperUnavailable) { _ = try await client.dumpBTM() }
        #expect(try await client.protocolVersion() == HelperXPC.protocolVersion)
        #expect(try await client.dumpBTM() == "Records")
        #expect(connections.value == 2)
    }

    /// Hängt eine Operation bei erreichbarem Helper, beginnt keine Abklingzeit: Der nächste Aufruf geht wieder an ihn.
    @Test func stuckOperationOfReachableHelperDoesNotCoolDown() async {
        let harness = Harness.silent()
        let client = harness.client(callTimeout: .milliseconds(200))
        for _ in 0..<2 {
            await #expect(throws: HelperClientError.self) {
                try await client.bootout(plistPath: "/Library/LaunchDaemons/x.plist")
            }
        }
        #expect(harness.silentHelper?.receivedOperations == 2)
    }

    @Test func stuckBTMDumpUsesItsOwnTimeout() async {
        let harness = Harness.silent()
        let client = harness.client(callTimeout: .seconds(60), dumpTimeout: .milliseconds(200))
        let start = ContinuousClock.now

        await #expect(throws: BTMSourceError.helperUnavailable) { _ = try await client.dumpBTM() }
        #expect(ContinuousClock.now - start < LatencyBound.wellBeforeLongTimeouts)
    }

    @Test func cancellationEndsCallPromptlyAndKeepsConnection() async throws {
        let harness = Harness.silent()
        let connections = ConnectionCounter()
        let client = harness.client(connections: connections)
        let start = ContinuousClock.now

        let call = Task { try await client.setEnabled(plistPath: "/Library/LaunchDaemons/x.plist", enabled: false) }
        try await Task.sleep(for: .milliseconds(100))
        call.cancel()

        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(ContinuousClock.now - start < LatencyBound.wellBeforeLongTimeouts)
        #expect(try await client.protocolVersion() == HelperXPC.protocolVersion)
        #expect(connections.value == 1)
    }

    @Test func alreadyCancelledCallThrowsWithoutSendingToHelper() async throws {
        let harness = Harness.silent()
        let client = harness.client()
        let call = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await client.bootstrap(plistPath: "/Library/LaunchDaemons/x.plist")
        }
        await #expect(throws: CancellationError.self) { try await call.value }

        // Nachrichten einer Verbindung kommen der Reihe nach an: Nach dieser Antwort hätte der Helper eine zuvor
        // gesendete Operation bereits empfangen.
        #expect(try await client.protocolVersion() == HelperXPC.protocolVersion)
        #expect(harness.silentHelper?.receivedOperations == 0)
    }

    // MARK: - Leerlauf

    /// Wartet, bis der Client seine Verbindung nach Leerlauf geschlossen hat (das Schließen läuft asynchron auf dem Actor).
    private static func waitUntilDisconnected(_ client: HelperClient) async {
        while await client.isConnected, !Task.isCancelled { await Task.yield() }
    }

    @Test(.timeLimit(.minutes(1))) func idleConnectionIsClosedAndReopenedOnNextCall() async throws {
        let harness = Harness(runner: MockCommandRunner())
        let clock = TestClock()
        let connections = ConnectionCounter()
        let client = harness.client(connections: connections, idleClock: clock)

        _ = try await client.protocolVersion()
        await clock.waitForSleeper(until: .at(.seconds(60)))
        #expect(clock.advance(by: .seconds(60)) == 1)
        await Self.waitUntilDisconnected(client)

        #expect(try await client.protocolVersion() == HelperXPC.protocolVersion)
        #expect(connections.value == 2)
    }

    @Test(.timeLimit(.minutes(1))) func eachCallRestartsIdleTimeout() async throws {
        let harness = Harness(runner: MockCommandRunner())
        let clock = TestClock()
        let connections = ConnectionCounter()
        let client = harness.client(connections: connections, idleClock: clock)

        _ = try await client.protocolVersion()
        await clock.waitForSleeper(until: .at(.seconds(60)))
        clock.advance(by: .seconds(30))
        _ = try await client.protocolVersion()
        await clock.waitForSleeper(until: .at(.seconds(90)))
        // Der zweite Aufruf hat die alte Frist (60 s) abgebrochen: Bis dahin vorzustellen weckt niemanden, also kann
        // auch kein Schließen mehr unterwegs sein.
        #expect(clock.advance(by: .seconds(30)) == 0)
        #expect(await client.isConnected)

        #expect(clock.advance(by: .seconds(30)) == 1)
        await Self.waitUntilDisconnected(client)
        _ = try await client.protocolVersion()
        #expect(connections.value == 2)
    }

    @Test(.timeLimit(.minutes(1))) func longRunningCallIsNotCutOffByIdleTimeout() async throws {
        let harness = Harness.silent()
        let clock = TestClock()
        let connections = ConnectionCounter()
        let client = harness.client(connections: connections, idleClock: clock)

        _ = try await client.protocolVersion()
        await clock.waitForSleeper(until: .at(.seconds(60)))
        let call = Task { try await client.setEnabled(plistPath: "/Library/LaunchDaemons/x.plist", enabled: false) }
        while harness.silentHelper?.receivedOperations != 1 { await Task.yield() }
        // Der laufende Aufruf hat die Frist abgebrochen: Vorstellen weckt niemanden, kein Schließen ist unterwegs.
        #expect(clock.advance(by: .seconds(600)) == 0)
        #expect(await client.isConnected)

        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(try await client.protocolVersion() == HelperXPC.protocolVersion)
        #expect(connections.value == 1)

        await clock.waitForSleeper(until: .at(.seconds(660)))
        #expect(clock.advance(by: .seconds(60)) == 1)
        await Self.waitUntilDisconnected(client)
    }

    @Test func resumeOnceResumesExactlyOnce() async throws {
        let once = ResumeOnce<Int>()
        let value: Int = try await withCheckedThrowingContinuation { continuation in
            #expect(once.install(continuation))
            once.resume(.success(1))
            once.resume(.failure(HelperClientError.unavailable("zu spät")))
            once.cancel()
            once.resume(.success(2))
        }
        #expect(value == 1)
    }

    @Test func resumeOnceCancelledBeforeInstallResumesAtInstall() async {
        let once = ResumeOnce<Int>()
        once.cancel()
        once.resume(.success(1))
        await #expect(throws: CancellationError.self) {
            _ = try await withCheckedThrowingContinuation { #expect(!once.install($0)) }
        }
    }

    @Test func errorDescriptionsAreReadable() {
        #expect(HelperClientError.unavailable("weg").localizedDescription == "Helper nicht erreichbar: weg")
        #expect(HelperClientError.rejected("Pfad nicht erlaubt").localizedDescription == "Pfad nicht erlaubt")
    }
}
