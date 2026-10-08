import Foundation
import os
import Synchronization

/// Fehler bei Aufrufen des root-Helpers.
public enum HelperClientError: LocalizedError, Equatable {
    /// Keine Verbindung (nicht registriert, nicht genehmigt, abgestürzt, Signatur passt nicht).
    case unavailable(String)
    /// Der Helper hat die Operation abgelehnt oder sie ist gescheitert.
    case rejected(String)
    /// Der erreichbare Helper ist zu alt für den Aufruf.
    case outdated

    /// Meldung für einen veralteten Helper, auch für `SecurityActions`.
    static let outdatedMessage = "Helper veraltet – bitte neu installieren"

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): "Helper nicht erreichbar: \(reason)"
        case .rejected(let reason): reason
        case .outdated: Self.outdatedMessage
        }
    }
}

/// Async-Client für den root-Helper. Hält eine Verbindung und baut sie nach Invalidierung, einem
/// Verbindungsfehler oder Leerlauf beim nächsten Aufruf neu auf.
///
/// Eine Verbindung, über die `idleTimeout` lang (Standard 60 s) kein Aufruf lief, schließt der Client. Sonst hielte
/// die dauerhaft laufende App (Menüleiste) den Helper ewig am Leben und dessen Idle-Exit griffe nie. Die Frist
/// beginnt nach dem Ende jedes Aufrufs neu; laufende Aufrufe werden nie abgeschnitten.
///
/// Jeder Aufruf endet genau einmal (`ResumeOnce`) – mit der Antwort des Helpers, über den Fehler-Handler des Proxys,
/// nach Ablauf seiner Frist oder durch Abbruch der aufrufenden Task:
/// - XPC ruft für eine Nachricht an einen Proxy aus `remoteObjectProxyWithErrorHandler(_:)` entweder den Reply-Block
///   oder – bei Unterbrechung oder Invalidierung der Verbindung vor der Antwort – den Fehler-Handler auf.
/// - Ein Helper, der lebt, aber nie antwortet, wird durch die Frist abgefangen (`HelperClientError.unavailable`).
///   Die Fristen liegen über den Befehls-Timeouts des Helpers (je launchctl-Operation Abfrage 10 s + Befehl 30 s,
///   jeweils plus Gnadenfrist; 60 s für `sfltool`), damit dessen eigene, aussagekräftigere Fehlermeldung Vorrang
///   hat. Fürs Absichern gilt je Operation
///   `SecurityHardening.maximumDuration` (Befehlsfrist + Gnadenfrist, mal Zahl der Befehle samt Zustandsabfrage)
///   plus 15 s (`hardeningTimeout(for:)`).
/// - Abbruch wirft `CancellationError` und lässt die Verbindung bestehen; alle anderen Verbindungsfehler und
///   Zeitüberschreitungen verwerfen sie.
///
/// Erreichbarkeit: Vor der ersten Operation über eine neue Verbindung fragt der Client die Protokollversion mit der
/// kurzen `reachabilityTimeout` ab (Standard 5 s). Startet launchd den Helper nicht (`spawn failed`, etwa „needs LWCR
/// update“ nach dem Austausch des App-Bundles), bleiben Nachrichten unbeantwortet – ohne diese Probe hinge jede
/// Operation bis zu ihrer langen Frist (`dumpBTM` 75 s). Scheitert die Probe, beginnt eine Abklingzeit
/// (`unavailableCooldown`, Standard 60 s): Operationen scheitern währenddessen sofort mit `.unavailable` und dem
/// letzten Grund. `protocolVersion()` selbst prüft trotz Abklingzeit (Zustand des Helpers, etwa nach „Neu
/// installieren“), mit kurzer Frist; eine Antwort beendet die Abklingzeit. Nach einer erneuten Registrierung beendet
/// `endCooldown()` sie ebenfalls. Hängt dagegen eine Operation eines erreichbaren Helpers, beginnt keine Abklingzeit.
public actor HelperClient: BTMDumpProviding, PrivilegedAutostartControlling, PrivilegedSecurityControlling {
    typealias ConnectionFactory = @Sendable () -> NSXPCConnection

    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "helper-client")

    private let makeConnection: ConnectionFactory
    private let callTimeout: Duration
    private let removalTimeout: Duration
    private let dumpTimeout: Duration
    private let hardeningTimeout: @Sendable (SecurityHardening) -> Duration
    private let socketTimeout: Duration
    private let reachabilityTimeout: Duration
    private let unavailableCooldown: Duration
    /// Startet eine Stoppuhr auf der Uhr der Abklingzeit; die zurückgegebene Funktion liefert die seither vergangene Zeit.
    private let startStopwatch: @Sendable () -> @Sendable () -> Duration
    private let makeIdleMonitor: @Sendable (_ onIdle: @escaping @Sendable () -> Void) -> IdleMonitor
    private var connection: NSXPCConnection?
    /// Zählt die laufenden Aufrufe über `connection`; gehört zu genau dieser Verbindung.
    private var connectionIdleMonitor: IdleMonitor?
    /// Protokollversion des Helpers hinter `connection`, sobald sie die Erreichbarkeitsprobe bestanden hat; `nil` für
    /// eine noch ungeprüfte Verbindung.
    private var connectionVersion: Int?
    /// Laufende Abklingzeit nach einer gescheiterten Erreichbarkeitsprobe.
    private var cooldown: Cooldown?

    /// Abklingzeit: Grund der gescheiterten Probe und die seither vergangene Zeit.
    private struct Cooldown {
        let reason: String
        let elapsed: @Sendable () -> Duration
    }

    /// Client für den registrierten Helper; vertraut nur einem Helper mit passender Code-Signatur.
    public init() {
        self.init(makeConnection: Self.privilegedConnection)
    }

    /// - Parameters:
    ///   - makeConnection: Erzeugt eine noch nicht gestartete Verbindung zum Helper; Interface und Handler setzt
    ///     der Client.
    ///   - callTimeout: Frist für launchctl-, Datei- und Versionsaufrufe; über der längsten launchctl-Operation des
    ///     Helpers (`HelperService.probeTimeout` + `launchctlTimeout` + zwei Gnadenfristen = 44 s).
    ///   - removalTimeout: Frist für `unloadAndRemovePlist`; über dessen längstem Ablauf im Helper (zwei Abfragen à
    ///     `HelperService.probeTimeout`, `bootout` und Rollback-`bootstrap` à `launchctlTimeout`, je mit Gnadenfrist =
    ///     88 s).
    ///   - dumpTimeout: Frist für `dumpBTM`.
    ///   - hardeningTimeout: Frist je absichernder Operation (`perform(_:)`).
    ///   - socketTimeout: Frist für `listeningSockets()`; kurz, weil der Helper nur wenige Millisekunden liest.
    ///   - idleTimeout: Leerlauf, nach dem die Verbindung geschlossen wird.
    ///   - idleClock: Uhr für `idleTimeout`.
    ///   - reachabilityTimeout: Frist der Erreichbarkeitsprobe und von `protocolVersion()`.
    ///   - unavailableCooldown: Abklingzeit nach gescheiterter Probe.
    ///   - cooldownClock: Uhr für `unavailableCooldown`.
    init(
        makeConnection: @escaping ConnectionFactory,
        callTimeout: Duration = .seconds(60),
        removalTimeout: Duration = .seconds(105),
        dumpTimeout: Duration = .seconds(75),
        hardeningTimeout: @escaping @Sendable (SecurityHardening) -> Duration = HelperClient.hardeningTimeout(for:),
        socketTimeout: Duration = .seconds(10),
        idleTimeout: Duration = .seconds(60),
        idleClock: some Clock<Duration> = ContinuousClock(),
        reachabilityTimeout: Duration = .seconds(5),
        unavailableCooldown: Duration = .seconds(60),
        cooldownClock: some Clock<Duration> = ContinuousClock()
    ) {
        self.makeConnection = makeConnection
        self.callTimeout = callTimeout
        self.removalTimeout = removalTimeout
        self.dumpTimeout = dumpTimeout
        self.hardeningTimeout = hardeningTimeout
        self.socketTimeout = socketTimeout
        self.reachabilityTimeout = reachabilityTimeout
        self.unavailableCooldown = unavailableCooldown
        startStopwatch = {
            let start = cooldownClock.now
            return { start.duration(to: cooldownClock.now) }
        }
        makeIdleMonitor = { onIdle in IdleMonitor(timeout: idleTimeout, clock: idleClock, onIdle: onIdle) }
    }

    isolated deinit {
        connection?.invalidate()
    }

    private static let privilegedConnection: ConnectionFactory = {
        let connection = NSXPCConnection(machServiceName: GrantryIdentity.helperMachServiceName, options: .privileged)
        connection.setCodeSigningRequirement(GrantryIdentity.helperRequirement)
        return connection
    }

    /// Protokollversion des laufenden Helpers; prüft auch während der Abklingzeit (Frist `reachabilityTimeout`).
    public func protocolVersion() async throws -> Int {
        try await probe()
    }

    /// Rohausgabe von `sfltool dumpbtm`.
    ///
    /// - Throws: `BTMSourceError.helperUnavailable` **statt** `HelperClientError.unavailable`, wenn der Helper nicht
    ///   erreichbar ist oder nicht rechtzeitig antwortet (den Grund protokolliert `call`), damit die BTM-Quelle einen
    ///   einheitlichen, verständlichen Fehler meldet. `BTMSourceError.dumpFailed`, wenn der Helper ablehnt oder
    ///   `sfltool` scheitert; `CancellationError` bei Abbruch.
    public func dumpBTM() async throws -> String {
        do {
            return try await call(timeout: dumpTimeout) { proxy, done in proxy.dumpBTM { done(Self.result($0, $1)) } }
        } catch HelperClientError.unavailable {
            throw BTMSourceError.helperUnavailable
        } catch HelperClientError.rejected(let detail) {
            throw BTMSourceError.dumpFailed(detail)
        }
    }

    /// Lauschende Sockets über den Helper (Frist `socketTimeout`). Verlangt mindestens
    /// `HelperXPC.listeningSocketsMinimumVersion`: Ein älterer Helper kennt den Aufruf nicht, NSXPC würde die
    /// Verbindung verwerfen. Die Version stammt aus der Erreichbarkeitsprobe der Verbindung, kostet also keine eigene
    /// Anfrage; die Abklingzeit gilt wie für jede Operation.
    ///
    /// - Throws: `HelperClientError.unavailable`, wenn der Helper nicht erreichbar ist; `.outdated` für einen zu alten
    ///   Helper; `.rejected` bei einer Fehlermeldung des Helpers oder nicht dekodierbarer Antwort.
    public func listeningSockets() async throws -> ListeningSocketScan {
        let data: Data = try await call(timeout: socketTimeout, requiring: HelperXPC.listeningSocketsMinimumVersion) {
            proxy, done in proxy.listListeningSockets { done(Self.result($0, $1)) }
        }
        do {
            return try JSONDecoder().decode(ListeningSocketScan.self, from: data)
        } catch {
            throw HelperClientError.rejected("Antwort nicht lesbar: \(error.readableDescription)")
        }
    }

    /// Beendet einen Prozess über den Helper (`terminateProcess`, Frist `callTimeout`); verlangt mindestens
    /// `HelperXPC.terminateProcessMinimumVersion`.
    public func terminateProcess(pid: Int32, executablePath: String, startTime: UInt64, force: Bool) async throws {
        try await call(timeout: callTimeout, requiring: HelperXPC.terminateProcessMinimumVersion) { proxy, done in
            proxy.terminateProcess(pid: pid, executablePath: executablePath, startTime: startTime, force: force) {
                done(Self.result($0))
            }
        }
    }

    public func setEnabled(plistPath: String, enabled: Bool) async throws {
        try await call(timeout: callTimeout) { proxy, done in
            proxy.setEnabled(plistPath: plistPath, enabled: enabled) { done(Self.result($0)) }
        }
    }

    public func bootout(plistPath: String) async throws {
        try await call(timeout: callTimeout) { proxy, done in proxy.bootout(plistPath: plistPath) { done(Self.result($0)) } }
    }

    public func bootstrap(plistPath: String) async throws {
        try await call(timeout: callTimeout) { proxy, done in proxy.bootstrap(plistPath: plistPath) { done(Self.result($0)) } }
    }

    /// Frist `removalTimeout`; verlangt mindestens `HelperXPC.unloadAndRemovePlistMinimumVersion`.
    public func unloadAndRemovePlist(path: String, expectedFingerprint: FileFingerprint?) async throws -> PrivilegedPlistRemoval {
        let fingerprint = try expectedFingerprint.map { try JSONEncoder().encode($0) }
        return try await call(timeout: removalTimeout, requiring: HelperXPC.unloadAndRemovePlistMinimumVersion) { proxy, done in
            proxy.unloadAndRemovePlist(path: path, expectedFingerprint: fingerprint) { backupPath, unloaded, error in
                done(Self.result(backupPath, error).map { PrivilegedPlistRemoval(backupPath: $0, wasUnloaded: unloaded) })
            }
        }
    }

    public func restorePlist(backupPath: String) async throws -> String {
        try await call(timeout: callTimeout) { proxy, done in
            proxy.restorePlist(backupPath: backupPath) { done(Self.result($0, $1)) }
        }
    }

    /// Standardfrist für `perform(_:)`: längste Laufzeit im Helper + 15 s, damit dessen Meldung Vorrang hat.
    static func hardeningTimeout(for hardening: SecurityHardening) -> Duration {
        hardening.maximumDuration + .seconds(15)
    }

    /// Führt `hardening` im Helper aus; Frist siehe `hardeningTimeout(for:)`.
    public func perform(_ hardening: SecurityHardening) async throws {
        try await call(timeout: hardeningTimeout(hardening)) { proxy, done in
            let reply: @Sendable (String?) -> Void = { done(Self.result($0)) }
            switch hardening {
            case .enableFirewall: proxy.enableFirewall(reply: reply)
            case .enableStealthMode: proxy.enableStealthMode(reply: reply)
            case .enableGatekeeper: proxy.enableGatekeeper(reply: reply)
            case .enableAutomaticUpdates: proxy.enableAutomaticUpdates(reply: reply)
            case .updateXProtect: proxy.updateXProtect(reply: reply)
            }
        }
    }

    // MARK: - Erreichbarkeit

    /// Fragt die Protokollversion mit kurzer Frist ab. Eine Antwort beendet die Abklingzeit, ein Verbindungsfehler oder
    /// eine Zeitüberschreitung startet sie (ein Abbruch nicht).
    private func probe() async throws -> Int {
        // `send` nutzt genau diese Verbindung (kein `await` dazwischen).
        let connection = currentConnection().connection
        do {
            let version: Int = try await send(timeout: reachabilityTimeout) { proxy, done in
                proxy.protocolVersion { done(.success($0)) }
            }
            if cooldown != nil { Self.logger.info("Helper wieder erreichbar") }
            cooldown = nil
            if self.connection === connection { connectionVersion = version }
            return version
        } catch HelperClientError.unavailable(let reason) {
            cooldown = Cooldown(reason: reason, elapsed: startStopwatch())
            Self.logger.error(
                "Helper nicht erreichbar, nächster Versuch frühestens in \(self.unavailableCooldown.formattedSeconds, privacy: .public)"
            )
            throw HelperClientError.unavailable(reason)
        }
    }

    /// Beendet eine laufende Abklingzeit, etwa nach einer erneuten Registrierung des Helpers (`HelperManager.register()`):
    /// Ihr Grund betraf den Helper vor der Registrierung, der nächste Aufruf versucht es daher sofort.
    public func endCooldown() {
        guard cooldown != nil else { return }
        Self.logger.info("Abklingzeit nach erneuter Registrierung beendet")
        cooldown = nil
    }

    /// Scheitert sofort während der Abklingzeit; prüft sonst eine noch ungeprüfte Verbindung mit `probe()`.
    ///
    /// - Returns: Protokollversion des Helpers hinter der Verbindung.
    private func ensureReachable() async throws -> Int {
        if let cooldown {
            guard cooldown.elapsed() >= unavailableCooldown else {
                throw HelperClientError.unavailable(cooldown.reason)
            }
            self.cooldown = nil
        }
        if connection != nil, let connectionVersion { return connectionVersion }
        return try await probe()
    }

    // MARK: - Verbindung

    /// Ob gerade eine Verbindung besteht (für Tests).
    var isConnected: Bool { connection != nil }

    /// Bestehende Verbindung oder eine neu aufgebaute und gestartete, samt ihrem Leerlauf-Monitor.
    private func currentConnection() -> (connection: NSXPCConnection, idleMonitor: IdleMonitor) {
        if let connection, let connectionIdleMonitor { return (connection, connectionIdleMonitor) }
        let fresh = makeConnection()
        connectionVersion = nil
        let id = ObjectIdentifier(fresh)
        fresh.remoteObjectInterface = HelperXPC.makeInterface()
        fresh.invalidationHandler = { [weak self] in
            Task { await self?.discardConnection(id) }
        }
        fresh.resume()
        let idleMonitor = makeIdleMonitor { [weak self] in
            Task { await self?.closeIdleConnection(id) }
        }
        connection = fresh
        connectionIdleMonitor = idleMonitor
        return (fresh, idleMonitor)
    }

    /// Schließt die Verbindung `id` nach Leerlauf – außer, inzwischen hat auf dem Actor ein Aufruf begonnen (dessen
    /// Ende setzt die Frist neu).
    private func closeIdleConnection(_ id: ObjectIdentifier) {
        guard connectionIdleMonitor?.activeCount == 0 else { return }
        Self.logger.info("Helper-Verbindung nach Leerlauf geschlossen")
        discardConnection(id)
    }

    /// Verwirft die gespeicherte Verbindung, sofern sie noch `id` ist (eine inzwischen neu aufgebaute bleibt).
    private func discardConnection(_ id: ObjectIdentifier) {
        guard let connection, ObjectIdentifier(connection) == id else { return }
        self.connection = nil
        connectionIdleMonitor = nil
        connectionVersion = nil
        connection.invalidate()
    }

    /// Ruft den Helper für eine Operation auf, nachdem seine Erreichbarkeit feststeht (`ensureReachable()`).
    ///
    /// Zwischen `ensureReachable()` und `send` kann die Verbindung neu aufgebaut werden; die geprüfte Version gilt dann
    /// für die vorige Verbindung zum selben installierten Helper – unkritisch.
    ///
    /// - Parameter minimumVersion: kleinste Protokollversion, die den Aufruf kennt; ein älterer Helper erhält ihn nicht
    ///   (`HelperClientError.outdated`).
    private func call<Value: Sendable>(
        timeout: Duration,
        requiring minimumVersion: Int? = nil,
        _ body: (any GrantryHelperXPC, @escaping @Sendable (Result<Value, HelperClientError>) -> Void) -> Void
    ) async throws -> Value {
        try Task.checkCancellation()
        let version = try await ensureReachable()
        if let minimumVersion, version < minimumVersion { throw HelperClientError.outdated }
        return try await send(timeout: timeout, body)
    }

    /// Sendet an den Helper. Antwort, Verbindungsfehler, Frist und Abbruch setzen die Continuation genau einmal fort.
    /// Nach einem Verbindungsfehler oder einer Zeitüberschreitung wird die Verbindung verworfen, damit der nächste
    /// Aufruf neu verbindet; nach einem Abbruch bleibt sie bestehen. Als erreichbar gilt die Verbindung erst nach der
    /// Erreichbarkeitsprobe (`probe()`), die ihre Version festhält. Der Aufruf zählt bis zu seinem Ende als Aktivität
    /// des Leerlauf-Monitors der Verbindung.
    private func send<Value: Sendable>(
        timeout: Duration,
        _ body: (any GrantryHelperXPC, @escaping @Sendable (Result<Value, HelperClientError>) -> Void) -> Void
    ) async throws -> Value {
        let (connection, idleMonitor) = currentConnection()
        let activity = idleMonitor.beginActivity()
        defer { activity.end() }
        let once = ResumeOnce<Value>()
        let deadline = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            once.resume(.failure(HelperClientError.unavailable("Zeitüberschreitung nach \(timeout.formattedSeconds)")))
        }
        defer { deadline.cancel() }
        do {
            let value = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    // Abbruch oder Frist vor dem Senden: nichts an den Helper schicken.
                    guard once.install(continuation) else { return }
                    let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                        once.resume(.failure(HelperClientError.unavailable(error.localizedDescription)))
                    }
                    guard let helper = proxy as? any GrantryHelperXPC else {
                        return once.resume(.failure(HelperClientError.unavailable("Unerwarteter Proxy-Typ")))
                    }
                    body(helper) { once.resume($0.mapError { $0 }) }
                }
            } onCancel: {
                once.cancel()
            }
            return value
        } catch HelperClientError.unavailable(let reason) {
            Self.logger.error("Helper-Verbindung gescheitert: \(reason, privacy: .public)")
            discardConnection(ObjectIdentifier(connection))
            throw HelperClientError.unavailable(reason)
        }
    }

    private static func result(_ error: String?) -> Result<Void, HelperClientError> {
        error.map { .failure(.rejected($0)) } ?? .success(())
    }

    private static func result<Value>(_ value: Value?, _ error: String?) -> Result<Value, HelperClientError> {
        if let error { return .failure(.rejected(error)) }
        guard let value else { return .failure(.rejected("Leere Antwort des Helpers")) }
        return .success(value)
    }
}

/// Setzt eine Continuation genau einmal fort; Antwort, Fehler-Handler, Frist und Abbruch dürfen in beliebiger
/// Reihenfolge und auch vor `install(_:)` eintreffen. Das erste Ergebnis gewinnt, alle weiteren werden ignoriert.
final class ResumeOnce<Value: Sendable>: Sendable {
    private enum State {
        /// Noch keine Continuation; ein bereits eingetroffenes Ergebnis wird bis `install(_:)` aufbewahrt.
        case pending(Result<Value, any Error>?)
        case installed(CheckedContinuation<Value, any Error>)
        case done
    }

    private let state = Mutex<State>(.pending(nil))

    init() {}

    /// Hinterlegt die Continuation.
    ///
    /// - Returns: `true`, wenn der Aufruf fortfahren soll. `false`, wenn bereits ein Ergebnis vorlag (Abbruch oder
    ///   Frist vor dem Senden); die Continuation ist dann schon fortgesetzt und nichts darf mehr gesendet werden.
    func install(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
        let early: Result<Value, any Error>? = state.withLock { state in
            guard case .pending(let result) = state else {
                preconditionFailure("ResumeOnce: Continuation mehrfach hinterlegt")
            }
            state = result == nil ? .installed(continuation) : .done
            return result
        }
        guard let early else { return true }
        continuation.resume(with: early)
        return false
    }

    func resume(_ result: Result<Value, any Error>) {
        let continuation: CheckedContinuation<Value, any Error>? = state.withLock { state in
            switch state {
            case .pending(nil):
                state = .pending(result)
                return nil
            case .installed(let continuation):
                state = .done
                return continuation
            case .pending, .done:
                return nil
            }
        }
        continuation?.resume(with: result)
    }

    /// Setzt mit `CancellationError` fort – sofort oder beim späteren `install(_:)`.
    func cancel() {
        resume(.failure(CancellationError()))
    }
}
