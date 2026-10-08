import Foundation
import GrantryShared
import os
import ServiceManagement

/// Zustand des privilegierten Helpers aus Sicht der App.
public enum HelperState: Equatable, Sendable {
    /// Nicht registriert.
    case notInstalled
    /// Registriert, wartet auf Genehmigung unter *Anmeldeobjekte & Erweiterungen*.
    case awaitingApproval
    /// Registriert, genehmigt und mit passender Protokollversion erreichbar.
    case ready
    /// Erreichbar, spricht aber eine andere Protokollversion als die App.
    case outdated(installed: Int, expected: Int)
    /// Registriert und genehmigt, antwortet aber nicht (Grund als lesbare Meldung).
    case unreachable(String)
    /// Die launchd-Plist des Helpers fehlt im App-Bundle.
    case missingFromBundle
    /// Der Benutzer ist kein Administrator; der Helper würde seine Verbindungen ablehnen.
    case requiresAdministrator
}

/// Abstraktion über einen per `SMAppService` registrierten LaunchDaemon, damit `HelperManager` ohne echte
/// Registrierung testbar ist.
public protocol DaemonService: Sendable {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

/// `DaemonService` über `SMAppService.daemon(plistName:)`. Hält nur den Plist-Namen (daher `Sendable`) und
/// erzeugt den Dienst pro Zugriff.
public struct SMAppDaemonService: DaemonService {
    public let plistName: String

    public init(plistName: String) {
        self.plistName = plistName
    }

    private var service: SMAppService { SMAppService.daemon(plistName: plistName) }

    public var status: SMAppService.Status { service.status }

    public func register() throws {
        try service.register()
    }

    public func unregister() async throws {
        try await service.unregister()
    }
}

/// Merkt sich in `UserDefaults`, aus welchem Build der App der Helper zuletzt registriert wurde und ob der Dienst in
/// diesem Build zuletzt aktiv (`.enabled`) war.
///
/// Hintergrund: Bei der Registrierung hinterlegt das System für den LaunchDaemon eine Startbedingung zur Signatur des
/// Bundles (LWCR, „lightweight code requirement“). Wird `/Applications/Grantry.app` durch einen neuen Build ersetzt,
/// passt sie nicht mehr: launchd startet den Helper nicht (`launchctl print system/de.cstrube.Grantry.Helper`:
/// `spawn failed`, `last exit code = 78: EX_CONFIG`, Eigenschaft `needs LWCR update`). Erst eine erneute Registrierung
/// aus dem neuen Bundle aktualisiert sie (`HelperManager.registrationRenewal`).
///
/// „Zuletzt aktiv“ unterscheidet nach einem Austausch einen vom Nutzer unter *Anmeldeobjekte* abgeschalteten Dienst
/// (meldet ebenfalls `.requiresApproval`) von einem, den erst der Austausch aus dem Tritt brachte.
public struct HelperRegistrationRecord: Sendable {
    public static let defaultsKey = "helperRegisteredBuild"
    public static let wasEnabledDefaultsKey = "helperWasEnabled"

    /// Ablage der beiden Vermerke.
    struct Storage: Sendable {
        var loadBuild: @Sendable () -> String?
        var saveBuild: @Sendable (String) -> Void
        var loadWasEnabled: @Sendable () -> Bool?
        var saveWasEnabled: @Sendable (Bool) -> Void

        static let userDefaults = Storage(
            loadBuild: { UserDefaults.standard.string(forKey: defaultsKey) },
            saveBuild: { UserDefaults.standard.set($0, forKey: defaultsKey) },
            loadWasEnabled: { UserDefaults.standard.object(forKey: wasEnabledDefaultsKey) as? Bool },
            saveWasEnabled: { UserDefaults.standard.set($0, forKey: wasEnabledDefaultsKey) }
        )
    }

    /// Version und Build-Nummer des laufenden App-Bundles, z. B. „2026.10.3 (412)“.
    public let currentBuild: String
    private let storage: Storage
    private let bundleBuildOnDisk: @Sendable () -> String?

    /// Vermerk in `UserDefaults.standard` für das laufende App-Bundle.
    public init() {
        self.init(
            currentBuild: Self.build(info: Bundle.main.infoDictionary ?? [:]),
            storage: .userDefaults,
            bundleBuildOnDisk: { Self.buildOnDisk(bundleURL: Bundle.main.bundleURL) }
        )
    }

    /// - Parameter bundleBuildOnDisk: Build des App-Bundles, wie es jetzt auf der Platte liegt; `nil`, wenn nicht
    ///   lesbar.
    init(currentBuild: String, storage: Storage, bundleBuildOnDisk: @escaping @Sendable () -> String?) {
        self.currentBuild = currentBuild
        self.storage = storage
        self.bundleBuildOnDisk = bundleBuildOnDisk
    }

    /// Das App-Bundle auf der Platte ist noch das laufende. Nach einem Austausch bei laufender App ist es das nicht
    /// mehr; deren Beobachtungen des Dienstes beschreiben dann den Austausch, nicht den Nutzer.
    public var isBundleOnDiskCurrent: Bool { bundleBuildOnDisk() == currentBuild }

    /// Build, aus dem zuletzt registriert wurde; `nil`, wenn unbekannt (nie oder vor dieser Aufzeichnung registriert).
    public var registeredBuild: String? { storage.loadBuild() }

    /// Ob der Dienst im vermerkten Build zuletzt aktiv war; `nil`, wenn unbekannt (Vermerk aus einem Build ohne diesen
    /// Schlüssel).
    public var wasEnabled: Bool? { storage.loadWasEnabled() }

    /// Der laufende Build hat den Helper registriert.
    public var isCurrent: Bool { registeredBuild == currentBuild }

    /// Vermerkt den laufenden Build als registriert und ob der Dienst danach aktiv ist.
    public func markCurrent(enabled: Bool) {
        storage.saveBuild(currentBuild)
        storage.saveWasEnabled(enabled)
    }

    /// Vermerkt, ob der Dienst im (aktuell vermerkten) Build aktiv ist.
    public func noteEnabled(_ enabled: Bool) {
        storage.saveWasEnabled(enabled)
    }

    /// Build aus `Contents/Info.plist` des Bundles, frisch von der Platte gelesen (`Bundle.infoDictionary` ist
    /// gecacht); `nil`, wenn nicht lesbar.
    static func buildOnDisk(bundleURL: URL) -> String? {
        let url = bundleURL.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return build(info: info)
    }

    /// „CFBundleShortVersionString (CFBundleVersion)“; fehlende Werte als „?“.
    public static func build(info: [String: Any]) -> String {
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let number = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(number))"
    }
}

/// Ob die Registrierung des Helpers nach einem Austausch des App-Bundles zu erneuern ist
/// (`HelperManager.registrationRenewal`).
public enum RegistrationRenewal: Equatable, Sendable {
    /// Neu registrieren (`HelperManager.renewRegistration()`): Der Vermerk weicht ab oder fehlt.
    case renew
    /// Nicht erneuern, mit Grund.
    case skip(SkipReason)

    /// Grund, die Registrierung nicht zu erneuern.
    public enum SkipReason: Equatable, Sendable {
        /// Builds werden nicht vermerkt (`HelperManager` ohne `HelperRegistrationRecord`).
        case noRecord
        /// Kein Administrator; der Helper würde die Verbindungen ohnehin ablehnen.
        case notAdministrator
        /// Der laufende Build hat den Helper registriert.
        case recordCurrent
        /// `.notRegistered`: Der Nutzer hat den Helper bewusst entfernt.
        case notRegistered
        /// `.requiresApproval`/`.notFound`, und im vermerkten Build war der Dienst zuletzt nicht aktiv: Der Nutzer hat
        /// ihn unter *Anmeldeobjekte* abgeschaltet (oder nie genehmigt).
        case disabledByUser
        /// `.notFound` ohne Vermerk: Der Helper wurde nie registriert (z. B. Erstinstallation).
        case neverRegistered
        /// `.notFound` und die launchd-Plist fehlt im App-Bundle.
        case missingFromBundle
        /// Vom System gemeldeter, unbekannter Dienststatus.
        case unknownStatus

        /// Lesbarer Grund für das Protokoll.
        public var description: String {
            switch self {
            case .noRecord: "kein Vermerk-Speicher"
            case .notAdministrator: "kein Administrator"
            case .recordCurrent: "Vermerk aktuell"
            case .notRegistered: "Dienst nicht registriert – vom Nutzer entfernt"
            case .disabledByUser: "vom Nutzer abgeschaltet"
            case .neverRegistered: "Dienst nicht gefunden und nie registriert"
            case .missingFromBundle: "Dienst nicht gefunden, launchd-Plist fehlt im Bundle"
            case .unknownStatus: "unbekannter Dienststatus"
            }
        }
    }
}

/// Entscheidung über das Erneuern der Registrierung samt den Werten, auf denen sie beruht – für das Protokoll beim
/// Start (`description`).
public struct RegistrationRenewalDecision: Equatable, Sendable, CustomStringConvertible {
    public let renewal: RegistrationRenewal
    /// Dienststatus zum Zeitpunkt der Entscheidung.
    public let status: SMAppService.Status
    /// Vermerkter Build der letzten Registrierung; `nil`, wenn unbekannt oder ohne Vermerk-Speicher.
    public let registeredBuild: String?
    /// Laufender Build; `nil` ohne Vermerk-Speicher.
    public let currentBuild: String?

    /// Die Registrierung ist zu erneuern.
    public var shouldRenew: Bool { renewal == .renew }

    public var description: String {
        let outcome = switch renewal {
        case .renew: "erneuern (Vermerk weicht ab oder fehlt)"
        case .skip(let reason): "keine Erneuerung (\(reason.description))"
        }
        return "\(outcome), Status \(status.logName), "
            + "registriert aus \(registeredBuild ?? "unbekannt"), laufend \(currentBuild ?? "unbekannt")"
    }
}

/// Das Erneuern der Registrierung nach einem Austausch des App-Bundles (`HelperManager.renewRegistration()`) ist
/// endgültig gescheitert; nennt Grund und Abhilfe.
public struct HelperRenewalError: LocalizedError {
    /// Fehler des letzten Registrierungsversuchs.
    public let underlying: any Error

    public var errorDescription: String? {
        "Der Helper ließ sich nach dem Update nicht automatisch neu registrieren (\(underlying.readableDescription)). "
            + "Bitte beim Helper „Installieren“ wählen."
    }
}

/// Registriert den Helper und ermittelt seinen Zustand (inkl. Protokollversion und Admin-Voraussetzung).
public struct HelperManager: Sendable {
    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "helper-manager")

    /// Fristen beim (Neu-)Registrieren (`register()`, `reinstall()`).
    ///
    /// Hintergrund (Log von smd/backgroundtaskmanagementd beim Start von Build 269 über 268): `unregister()` kehrte
    /// nach dem Bootout zurück, das 11 ms später folgende `register()` scheiterte aber mit „Job is not allowed to
    /// bootstrap“ – die Hintergrundaufgaben-Verwaltung führte den Eintrag noch als deaktiviert. Eine spätere
    /// Registrierung gelang ohne Dialog.
    struct RegistrationTiming: Sendable {
        /// Wie lange nach `unregister()` höchstens gewartet wird, bis der Dienst nicht mehr registriert ist.
        var unregisterDeadline: Duration
        /// Abstand der Statusabfragen währenddessen.
        var statusPollInterval: Duration
        /// Pause vor dem einzigen erneuten Registrierungsversuch.
        var retryBackoff: Duration
        /// Wartezeiten vor den erneuten Zustandsabfragen, wenn der Helper direkt nach einer gelungenen Registrierung
        /// „nicht erreichbar“ ist (`register()`); leer: keine Wiederholung.
        ///
        /// Hintergrund (#88, Log der Abnahme von 2026.10.4 (276)): Die erste Abfrage direkt nach `register()` scheiterte
        /// mit „Die Kommunikation mit einem Hilfsprogramm ist fehlgeschlagen“, 10 ms später antwortete der Helper. Der
        /// Standard wartet mit wachsendem Abstand insgesamt 2,5 s (zuzüglich der Dauer der Abfragen).
        var reachabilityRetryDelays: [Duration]
        /// Obergrenze für Abfragen und Wartezeiten nach der Registrierung, ab der ersten Abfrage gemessen: Eine weitere
        /// Wartezeit beginnt nur, wenn sie danach noch hineinpasst. Die Wiederholung soll nur den schnellen
        /// Verbindungsfehler eines noch startenden Helpers überbrücken; hängt eine Abfrage dagegen bis zur
        /// Erreichbarkeitsfrist des `HelperClient` (5 s, etwa wenn launchd den Helper nicht startet), wird nicht
        /// wiederholt, und die Registrierung dauert nicht ein Vielfaches dieser Frist.
        var reachabilityRetryBudget: Duration

        static let standard = RegistrationTiming(
            unregisterDeadline: .seconds(5), statusPollInterval: .milliseconds(100), retryBackoff: .seconds(2),
            reachabilityRetryDelays: [
                .milliseconds(100), .milliseconds(200), .milliseconds(400), .milliseconds(800), .seconds(1),
            ],
            reachabilityRetryBudget: .seconds(3)
        )
    }

    private let service: any DaemonService
    private let versionProbe: @Sendable () async throws -> Int
    private let endCooldown: @Sendable () async -> Void
    private let isAdministrator: @Sendable () -> Bool
    private let bundleContainsPlist: @Sendable () -> Bool
    /// `nil`: Builds werden nicht vermerkt, eine Erneuerung ist nie nötig.
    private let registration: HelperRegistrationRecord?
    private let timing: RegistrationTiming
    /// Startet eine Stoppuhr an der Uhr für die Fristen aus `RegistrationTiming`.
    private let startStopwatch: @Sendable () -> @Sendable () -> Duration
    /// Wartet an derselben Uhr.
    private let sleep: @Sendable (Duration) async throws -> Void

    /// Manager für den im App-Bundle eingebetteten Helper; fragt die Protokollversion über `client` ab und vermerkt
    /// registrierende Builds in `registration`.
    ///
    /// - Parameter afterRegistration: läuft mit dem Ende der Abklingzeit nach jeder (Neu-)Registrierung (`register()`,
    ///   auch über `reinstall()` und `renewRegistration()`) – etwa, damit die Lauscher-Quelle den Helper sofort wieder
    ///   fragt (`ListenerHelperSchedule.reset()`).
    public init(
        client: HelperClient = HelperClient(),
        registration: HelperRegistrationRecord = HelperRegistrationRecord(),
        afterRegistration: @escaping @Sendable () -> Void = {}
    ) {
        self.init(
            service: SMAppDaemonService(plistName: GrantryIdentity.helperPlistName),
            versionProbe: { try await client.protocolVersion() },
            endCooldown: {
                await client.endCooldown()
                afterRegistration()
            },
            isAdministrator: { AdminMembership.isAdministrator(getuid()) },
            bundleContainsPlist: { FileManager.default.fileExists(atPath: Self.bundledPlistURL.path) },
            registration: registration
        )
    }

    /// Ort der launchd-Plist des Helpers im App-Bundle (`Contents/Library/LaunchDaemons/`).
    private static var bundledPlistURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Library/LaunchDaemons/\(GrantryIdentity.helperPlistName)")
    }

    /// - Parameters:
    ///   - service: Registrierung und Status des LaunchDaemons.
    ///   - versionProbe: Liefert die Protokollversion des laufenden Helpers.
    ///   - endCooldown: Beendet die Abklingzeit des Clients nach einer erneuten Registrierung.
    ///   - isAdministrator: `true`, wenn der aktuelle Benutzer Administrator ist.
    ///   - bundleContainsPlist: `true`, wenn die launchd-Plist des Helpers im App-Bundle liegt.
    ///   - registration: vermerkt den registrierenden Build.
    ///   - timing: Fristen beim (Neu-)Registrieren.
    ///   - clock: Uhr für die Fristen und Wartezeiten aus `timing`.
    init(
        service: any DaemonService,
        versionProbe: @escaping @Sendable () async throws -> Int,
        endCooldown: @escaping @Sendable () async -> Void = {},
        isAdministrator: @escaping @Sendable () -> Bool,
        bundleContainsPlist: @escaping @Sendable () -> Bool,
        registration: HelperRegistrationRecord? = nil,
        timing: RegistrationTiming = .standard,
        clock: some Clock<Duration> = ContinuousClock()
    ) {
        self.service = service
        self.versionProbe = versionProbe
        self.endCooldown = endCooldown
        self.isAdministrator = isAdministrator
        self.bundleContainsPlist = bundleContainsPlist
        self.registration = registration
        self.timing = timing
        startStopwatch = {
            let start = clock.now
            return { start.duration(to: clock.now) }
        }
        sleep = { try await clock.sleep(for: $0) }
    }

    /// Ob die Registrierung nach einem Austausch des App-Bundles zu erneuern ist: Nach dem Austausch startet launchd
    /// den Helper sonst nicht mehr (siehe `HelperRegistrationRecord`). Erneuert wird mit `renewRegistration()`.
    ///
    /// Nur wenn der Vermerk vom laufenden Build abweicht oder fehlt, und dann je nach Dienststatus:
    /// - `.enabled`: erneuern.
    /// - `.requiresApproval`, `.notFound` (nur mit launchd-Plist im Bundle und mit Build-Vermerk – ohne wurde nie
    ///   registriert, etwa bei der Erstinstallation): Beides kommt direkt nach einem Austausch vor (#96: die
    ///   Hintergrundaufgaben-Verwaltung setzte den Eintrag dabei auf „deaktiviert“), `.requiresApproval` aber auch,
    ///   wenn der Nutzer den Helper unter *Anmeldeobjekte* abgeschaltet hat. Erneuert wird daher nur, wenn der Dienst
    ///   im vermerkten Build zuletzt aktiv war (`HelperRegistrationRecord.wasEnabled`) **oder das unbekannt ist**:
    ///   Builds vor diesem Vermerk speicherten ihn nicht; ohne diese Ausnahme träte #96 beim ersten Update danach
    ///   noch einmal auf. War er zuletzt nicht aktiv, wird das als Entscheidung des Nutzers respektiert.
    /// - `.notRegistered`: nie – der Nutzer hat den Helper entfernt.
    ///
    /// Nie für Nicht-Administratoren.
    public var registrationRenewal: RegistrationRenewalDecision {
        let status = service.status
        let decide = { (renewal: RegistrationRenewal) in
            RegistrationRenewalDecision(
                renewal: renewal, status: status,
                registeredBuild: registration?.registeredBuild, currentBuild: registration?.currentBuild
            )
        }
        guard let registration else { return decide(.skip(.noRecord)) }
        guard isAdministrator() else { return decide(.skip(.notAdministrator)) }
        guard !registration.isCurrent else { return decide(.skip(.recordCurrent)) }
        let renewUnlessDisabledByUser = { registration.wasEnabled == false ? decide(.skip(.disabledByUser)) : decide(.renew) }
        switch status {
        case .enabled: return decide(.renew)
        case .requiresApproval: return renewUnlessDisabledByUser()
        case .notRegistered: return decide(.skip(.notRegistered))
        case .notFound:
            guard bundleContainsPlist() else { return decide(.skip(.missingFromBundle)) }
            guard registration.registeredBuild != nil else { return decide(.skip(.neverRegistered)) }
            return renewUnlessDisabledByUser()
        @unknown default: return decide(.skip(.unknownStatus))
        }
    }

    /// Beim App-Start: ermittelt `registrationRenewal`, vermerkt bei aktuellem Build, ob der Dienst aktiv ist
    /// (`HelperRegistrationRecord.noteEnabled(_:)` – so wird ein Abschalten durch den Nutzer beim nächsten Update
    /// respektiert), und protokolliert die Entscheidung als `notice` (persistiert), auch wenn nicht erneuert wird (#96).
    public func assessRegistrationRenewalAtLaunch() -> RegistrationRenewalDecision {
        let decision = registrationRenewal
        noteEnabledIfCurrent(decision.status)
        Self.logger.notice("Erneuerung der Helper-Registrierung beim Start: \(decision.description, privacy: .public)")
        return decision
    }

    /// Aktueller Zustand. `.ready` nur bei aktivem Dienst **und** passender Protokollversion; für
    /// Nicht-Administratoren immer `.requiresAdministrator`.
    ///
    /// `SMAppService` meldet `.notFound` auch für einen nie registrierten Dienst; nur wenn zusätzlich die Plist im
    /// App-Bundle fehlt, lautet der Zustand `.missingFromBundle`, sonst `.notInstalled`. Die Protokollversion wird
    /// nur bei `.enabled` abgefragt; das kann bis zur Erreichbarkeitsfrist des `HelperClient` (5 s) dauern – die
    /// Oberfläche sollte währenddessen einen Ladezustand zeigen.
    ///
    /// Stammt die Registrierung aus dem laufenden Build, vermerkt jede Abfrage, ob der Dienst aktiv ist
    /// (`HelperRegistrationRecord.wasEnabled`) – so wird ein Abschalten unter *Anmeldeobjekte* auch zur Laufzeit
    /// erfasst und beim nächsten Update respektiert.
    public func state() async -> HelperState {
        guard isAdministrator() else { return .requiresAdministrator }
        let status = service.status
        noteEnabledIfCurrent(status)
        switch status {
        case .notRegistered: return .notInstalled
        case .requiresApproval: return .awaitingApproval
        case .notFound: return bundleContainsPlist() ? .notInstalled : .missingFromBundle
        case .enabled:
            do {
                let installed = try await versionProbe()
                return installed == HelperXPC.protocolVersion
                    ? .ready
                    : .outdated(installed: installed, expected: HelperXPC.protocolVersion)
            } catch {
                return .unreachable(error.readableDescription)
            }
        @unknown default:
            return .unreachable("Unbekannter Dienststatus")
        }
    }

    /// Registriert den Helper und liefert den Zustand danach; ist der Dienst danach registriert, gilt der laufende Build
    /// als registrierend (`HelperRegistrationRecord`). Nicht-Administratoren erhalten `.requiresAdministrator` ohne
    /// Registrierungsversuch.
    ///
    /// `SMAppService.register()` meldet auch dann einen Fehler, wenn der Dienst bereits registriert ist oder noch
    /// genehmigt werden muss (`kSMErrorAlreadyRegistered`, `kSMErrorLaunchDeniedByUser`). Nur diese beiden Fehler
    /// werden toleriert – und nur, wenn der Dienst danach auf `.enabled` oder `.requiresApproval` steht; dann wird
    /// der Zustand geliefert. Alle anderen Fehler werden weitergereicht.
    ///
    /// Ist der Dienst registriert, wird der Zustand mit `stateAfterRegistration()` ermittelt: Ein frisch registrierter
    /// Helper, der noch startet, wird kurz erneut abgefragt, bevor `.unreachable` gemeldet wird (#88). Danach endet die
    /// Abklingzeit des `HelperClient` – auch wenn die Abfragen scheiterten: Der nächste Aufruf (etwa der erste Scan nach
    /// einem Update) versucht es dann erneut, statt 60 s lang sofort „nicht erreichbar“ zu melden (#86). Die Abfragen
    /// selbst prüfen trotz Abklingzeit (`HelperClient.protocolVersion()`).
    public func register() async throws -> HelperState {
        guard isAdministrator() else { return .requiresAdministrator }
        do {
            try service.register()
        } catch where Self.isToleratedRegistrationError(error) && Self.isRegistered(service.status) {
            Self.logger.info("Registrierung meldete \(error.readableDescription, privacy: .public); Dienst ist dennoch registriert")
        }
        guard Self.isRegistered(service.status) else { return await state() }
        registration?.markCurrent(enabled: service.status == .enabled)
        let state = await stateAfterRegistration()
        await endCooldown()
        return state
    }

    /// Zustand direkt nach einer gelungenen Registrierung. Ergibt die Abfrage `.unreachable`, wird sie nach den
    /// Wartezeiten aus `RegistrationTiming.reachabilityRetryDelays` wiederholt, bis ein anderer Zustand vorliegt, die
    /// Wartezeiten erschöpft sind oder die nächste nicht mehr in `RegistrationTiming.reachabilityRetryBudget` passt: Der
    /// frisch registrierte Helper nimmt Verbindungen mitunter erst einige Millisekunden nach `register()` an (#88).
    /// Andere Zustände (etwa `.outdated`, `.awaitingApproval`) gelten sofort. Im ungünstigsten Fall dauert das das
    /// Budget plus eine letzte Abfrage.
    ///
    /// Ein Abbruch der Task beendet die Wiederholungen; dann gilt der zuletzt ermittelte Zustand – die Registrierung
    /// selbst ist gelungen und wird nicht als Fehler gemeldet.
    private func stateAfterRegistration() async -> HelperState {
        let elapsed = startStopwatch()
        var state = await state()
        for (attempt, delay) in timing.reachabilityRetryDelays.enumerated() {
            guard case .unreachable(let reason) = state, !Task.isCancelled else { break }
            guard elapsed() + delay <= timing.reachabilityRetryBudget else {
                Self.logger.info("Keine weitere Wiederholung: Budget nach \(elapsed().formattedSeconds, privacy: .public) erschöpft")
                break
            }
            Self.logger.info("""
                Helper nach der Registrierung nicht erreichbar (\(reason, privacy: .public)); \
                Wiederholung \(attempt + 1, privacy: .public) in \(delay.formattedSeconds, privacy: .public)
                """)
            do {
                try await sleep(delay)
            } catch {
                Self.logger.info("Warten auf den Helper nach der Registrierung abgebrochen")
                break
            }
            state = await self.state()
        }
        if case .unreachable(let reason) = state {
            Self.logger.notice("Helper nach der Registrierung nicht erreichbar: \(reason, privacy: .public)")
        }
        return state
    }

    /// Registriert den Helper neu: erst `unregister()` (beendet den laufenden, alten Helper), dann – sobald der
    /// Dienst nicht mehr registriert ist, höchstens nach `RegistrationTiming.unregisterDeadline` – `register()`;
    /// scheitert das, nach `RegistrationTiming.retryBackoff` ein zweites Mal. Nach einem App-Update bei Zustand
    /// `.outdated` verwenden, damit launchd den Helper aus dem neuen Bundle startet. Nicht-Administratoren erhalten
    /// `.requiresAdministrator` ohne Aufruf am Dienst.
    ///
    /// Scheitert `unregister()` bei einem nicht aktiven Dienst (`.requiresApproval`, `.notFound` – etwa direkt nach
    /// einem Austausch des Bundles), wird das protokolliert und trotzdem registriert; bei `.enabled` bleibt es ein
    /// Fehler, sonst liefe der alte Helper weiter. Nach einem solchen Fehler wird nicht auf die Abmeldung gewartet.
    public func reinstall() async throws -> HelperState {
        guard isAdministrator() else { return .requiresAdministrator }
        let initialStatus = service.status
        do {
            try await unregister()
            try await waitUntilUnregistered()
        } catch where initialStatus != .enabled && !(error is CancellationError) {
            Self.logger.notice("""
                Abmelden des Helpers bei Status \(initialStatus.logName, privacy: .public) gescheitert: \
                \(error.readableDescription, privacy: .public); registriere sofort
                """)
        }
        do {
            return try await register()
        } catch {
            Self.logger.error("""
                Registrierung des Helpers nach dem Abmelden gescheitert: \(error.readableDescription, privacy: .public); \
                neuer Versuch in \(timing.retryBackoff, privacy: .public)
                """)
            try await sleep(timing.retryBackoff)
            do {
                return try await register()
            } catch {
                Self.logger.error("Registrierung des Helpers auch im zweiten Versuch gescheitert: \(error.readableDescription, privacy: .public)")
                throw error
            }
        }
    }

    /// Erneuert die Registrierung nach einem Austausch des App-Bundles (`registrationRenewal`) über `reinstall()`
    /// und protokolliert Anlass und Ergebnis. Scheitert sie endgültig, wirft sie `HelperRenewalError` (Grund und
    /// Abhilfe); der Vermerk des registrierten Builds bleibt dann unverändert.
    public func renewRegistration() async throws -> HelperState {
        Self.logger.notice("Registriere den Helper neu")
        do {
            let state = try await reinstall()
            Self.logger.notice("Neuregistrierung des Helpers erfolgreich, Zustand: \(String(describing: state), privacy: .public)")
            return state
        } catch {
            Self.logger.notice("Neuregistrierung des Helpers gescheitert: \(error.readableDescription, privacy: .public)")
            throw HelperRenewalError(underlying: error)
        }
    }

    /// Vermerkt, ob der Dienst aktiv ist – nur wenn die Registrierung aus dem laufenden Build stammt; bei abweichendem
    /// Build beschreibt `wasEnabled` den vermerkten Build und entscheidet über die Erneuerung. Auch nicht, wenn das
    /// Bundle auf der Platte inzwischen ausgetauscht (oder nicht lesbar) ist: Die noch laufende alte App sähe dann den
    /// vom Austausch deaktivierten Dienst und vermerkte fälschlich ein Abschalten durch den Nutzer.
    private func noteEnabledIfCurrent(_ status: SMAppService.Status) {
        guard let registration, registration.isCurrent else { return }
        guard registration.isBundleOnDiskCurrent else {
            Self.logger.notice("App-Bundle wurde ausgetauscht, Vermerk bleibt")
            return
        }
        registration.noteEnabled(status == .enabled)
    }

    /// Wartet nach `unregister()`, bis der Dienst nicht mehr registriert ist; nach Ablauf der Frist geht es trotzdem
    /// weiter (die Registrierung meldet dann selbst, ob sie gelingt).
    private func waitUntilUnregistered() async throws {
        let elapsed = startStopwatch()
        while Self.isRegistered(service.status) {
            guard elapsed() < timing.unregisterDeadline else {
                Self.logger.error("Helper nach \(timing.unregisterDeadline, privacy: .public) noch nicht abgemeldet; registriere trotzdem")
                return
            }
            try await sleep(timing.statusPollInterval)
        }
    }

    /// Hebt die Registrierung des Helpers auf; ein laufender Helper wird beendet. Ohne eigene Admin-Prüfung – die
    /// Berechtigung dafür prüft das System.
    public func unregister() async throws {
        try await service.unregister()
    }

    /// Fehler von `SMAppService.register()`, die bei bereits registriertem Dienst erwartet sind.
    private static func isToleratedRegistrationError(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == SMAppServiceErrorDomain
            && [kSMErrorAlreadyRegistered, kSMErrorLaunchDeniedByUser].contains(error.code)
    }

    /// Der Dienst ist registriert (genehmigt oder auf Genehmigung wartend).
    private static func isRegistered(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    /// Öffnet *Anmeldeobjekte & Erweiterungen* in den Systemeinstellungen zur Genehmigung.
    @MainActor public static func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

fileprivate extension SMAppService.Status {
    /// Lesbarer Name für das Protokoll (`SMAppService.Status` beschreibt sich nur als Zahl).
    var logName: String {
        switch self {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unbekannt (\(rawValue))"
        }
    }
}
