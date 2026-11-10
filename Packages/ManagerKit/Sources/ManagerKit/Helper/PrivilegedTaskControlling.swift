import Foundation
import Security

/// Task-Manager-Aktionen über den root-Helper (TM9); in der App `HelperClient`. Jede verlangt eine frische
/// Admin-Bestätigung (`authorization`, `ActionAuthorization.issue()`), die der Helper selbst abfragt. Scheitert ein Aufruf
/// nach dem Senden, ist das Ergebnis unbekannt (wie `PrivilegedProcessTerminating`).
public protocol PrivilegedTaskControlling: Sendable {
    func terminateTaskProcess(pid: Int32, executablePath: String, startTime: UInt64, force: Bool,
                              authorization: Data) async throws
    func setTaskProcessPriority(pid: Int32, executablePath: String, startTime: UInt64, priority: ProcessPriority,
                                authorization: Data) async throws
}

/// Sensoren über den Helper (TM-9.4); in der App `HelperClient`.
public protocol PrivilegedSensorReading: Sendable {
    func sensorReading() async throws -> SensorReading
}

extension HelperClient: PrivilegedTaskControlling, PrivilegedSensorReading {}

/// Fehler beim Anlegen der Admin-Bestätigung in der App.
public struct ActionAuthorizationError: LocalizedError, Equatable {
    public let status: OSStatus

    public var errorDescription: String? { "Admin-Bestätigung nicht vorbereitet (\(status))" }
}

/// Eine frische, leere `AuthorizationRef` für **eine** Aktion (Plan TM9, Helper-Entwurf): ohne Rechte und ohne Dialog
/// angelegt, als `AuthorizationExternalForm` an den Helper. Wird mit `.destroyRights` freigegeben, sobald das Objekt
/// verschwindet – nach der Antwort des Helpers.
public final class IssuedAuthorization: @unchecked Sendable {
    /// Die 32 Byte für den Helper.
    public let externalForm: Data
    private let reference: AuthorizationRef?

    init(externalForm: Data, reference: AuthorizationRef?) {
        self.externalForm = externalForm
        self.reference = reference
    }

    deinit {
        if let reference { AuthorizationFree(reference, [.destroyRights]) }
    }
}

/// Legt je Aktion eine `IssuedAuthorization` an; in Tests ein Fake.
public protocol ActionAuthorizationIssuing: Sendable {
    func issue() throws -> IssuedAuthorization
}

/// Authorization Services ohne Rechte (`AuthorizationCreate(nil, nil, [], …)`): Den Dialog öffnet erst der Helper.
public struct ActionAuthorization: ActionAuthorizationIssuing {
    public init() {}

    public func issue() throws -> IssuedAuthorization {
        var reference: AuthorizationRef?
        let created = AuthorizationCreate(nil, nil, [], &reference)
        guard created == errAuthorizationSuccess, let reference else { throw ActionAuthorizationError(status: created) }
        var form = AuthorizationExternalForm()
        let exported = AuthorizationMakeExternalForm(reference, &form)
        guard exported == errAuthorizationSuccess else {
            AuthorizationFree(reference, [.destroyRights])
            throw ActionAuthorizationError(status: exported)
        }
        let data = withUnsafeBytes(of: form.bytes) { Data($0) }
        return IssuedAuthorization(externalForm: data, reference: reference)
    }

    /// Feste Bestätigung ohne Ref – nur für Tests und Vorschauen.
    public static func placeholder() -> IssuedAuthorization {
        IssuedAuthorization(externalForm: Data(count: TaskActionViolation.authorizationLength), reference: nil)
    }
}

/// „Task beenden“ für Prozesse anderer Benutzer: Brücke vom `ProcessTerminator` (`PrivilegedProcessTerminating`) zum
/// Task-Manager-Befehl des Helpers mit frischer Admin-Bestätigung je Prozess.
public struct HelperTaskTerminator: PrivilegedProcessTerminating {
    private let helper: any PrivilegedTaskControlling
    private let authorization: any ActionAuthorizationIssuing

    public init(helper: any PrivilegedTaskControlling,
                authorization: any ActionAuthorizationIssuing = ActionAuthorization()) {
        self.helper = helper
        self.authorization = authorization
    }

    public func terminateProcess(pid: Int32, executablePath: String, startTime: UInt64, force: Bool) async throws {
        let issued = try authorization.issue()
        defer { withExtendedLifetime(issued) {} }
        try await helper.terminateTaskProcess(pid: pid, executablePath: executablePath, startTime: startTime,
                                              force: force, authorization: issued.externalForm)
    }
}
