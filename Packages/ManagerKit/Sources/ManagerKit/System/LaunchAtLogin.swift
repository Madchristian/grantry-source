import ServiceManagement

/// Zustand des Login-Items der App („Beim Anmelden starten“).
public enum LoginItemStatus: Hashable, Sendable {
    /// Registriert; die App startet beim Anmelden.
    case enabled
    /// Nicht registriert.
    case disabled
    /// Registriert, aber unter *Anmeldeobjekte & Erweiterungen* vom Benutzer nicht erlaubt.
    case requiresApproval

    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        // `.notFound` meldet `SMAppService.mainApp` auch für eine nie registrierte App.
        case .notRegistered, .notFound: self = .disabled
        @unknown default: self = .disabled
        }
    }

    /// `true`, wenn die App als Login-Item registriert ist (auch wenn es noch erlaubt werden muss).
    public var isRegistered: Bool { self != .disabled }
}

/// Registrierung eines Dienstes über `SMAppService`; abstrahiert, damit `LaunchAtLogin` ohne echte Registrierung
/// testbar ist.
public protocol AppServiceRegistration: Sendable {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

/// Die App selbst als Login-Item (`SMAppService.mainApp`).
public struct MainAppServiceRegistration: AppServiceRegistration {
    public init() {}

    public var status: SMAppService.Status { SMAppService.mainApp.status }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() async throws {
        try await SMAppService.mainApp.unregister()
    }
}

/// „Beim Anmelden starten“: liest und ändert die Registrierung der App als Login-Item.
public struct LaunchAtLogin: Sendable {
    private let service: any AppServiceRegistration

    public init(service: any AppServiceRegistration = MainAppServiceRegistration()) {
        self.service = service
    }

    public var status: LoginItemStatus { LoginItemStatus(service.status) }

    /// Registriert die App (`enabled == true`) oder hebt die Registrierung auf und liefert den Zustand danach.
    /// Ist der gewünschte Zustand schon erreicht, bleibt der Dienst unangetastet.
    public func setEnabled(_ enabled: Bool) async throws -> LoginItemStatus {
        guard enabled != status.isRegistered else { return status }
        if enabled {
            try service.register()
        } else {
            try await service.unregister()
        }
        return status
    }

    /// Öffnet *Anmeldeobjekte & Erweiterungen* in den Systemeinstellungen.
    @MainActor public static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
