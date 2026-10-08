import Foundation

/// Aktionen für Datenschutz-Berechtigungen (Spec §5).
///
/// - Warnung: `tccutil reset AppleEvents <bundleID>` setzt bei Automation-Berechtigungen **alle** Ziel-Apps
///   dieser App zurück, nicht nur das über `target` ausgewählte einzelne Ziel – `tccutil` kennt keine
///   Einschränkung auf ein einzelnes `indirect_object_identifier`. Die Aktion bleibt trotzdem verfügbar (die
///   Alternative wäre, Automation-Zurücksetzen ganz zu sperren), die aufrufende Schicht muss das dem Nutzer
///   aber deutlich machen, bevor sie bestätigt wird.
public struct PermissionActions: Sendable {
    static let tccutil = "/usr/bin/tccutil"
    private let runner: any CommandRunning
    private let policy: ActionPolicy

    public init(runner: any CommandRunning = ProcessCommandRunner(), policy: ActionPolicy = ActionPolicy()) {
        self.runner = runner
        self.policy = policy
    }

    /// Setzt die Berechtigung per `tccutil reset` zurück; die App fragt beim nächsten Zugriff erneut.
    public func reset(_ grant: PermissionGrant) async throws {
        if case .readOnly(let reason) = policy.availability(for: grant) { throw ActionError.notAllowed(reason) }
        guard let bundleID = grant.client.bundleID else { throw ActionError.notAllowed(.noBundleIdentifier) }
        let serviceName = PermissionCatalog.service(for: grant.service).displayName
        try await runner.runChecked(
            Self.tccutil, ["reset", Self.tccutilServiceName(grant.service), bundleID],
            failureMessage: "\(serviceName)-Berechtigung für \(grant.client.displayName) konnte nicht zurückgesetzt werden"
        )
    }

    /// Setzt den Dienst für **alle** Apps zurück (`tccutil reset <Dienst>`, siehe `ServiceReset`). Lehnt Dienstnamen ab,
    /// die mehr träfen als diesen einen Dienst – `tccutil reset All` setzt sämtliche Berechtigungen zurück.
    public func resetService(_ service: String) async throws {
        let name = Self.tccutilServiceName(service)
        guard service.hasPrefix("kTCCService"), !name.isEmpty, name != "All" else {
            throw ActionError.notAllowed(.noSingleService)
        }
        try await runner.runChecked(
            Self.tccutil, ["reset", name],
            failureMessage: "\(PermissionCatalog.service(for: service).displayName) konnte nicht für alle Apps zurückgesetzt werden"
        )
    }

    /// Deeplink in die passende Seite der Systemeinstellungen.
    public func settingsURL(for grant: PermissionGrant) -> URL? {
        PermissionCatalog.service(for: grant.service).settingsURL
    }

    /// `kTCCServiceCamera` → `Camera`; `tccutil` erwartet den Service-Namen ohne das Präfix.
    public static func tccutilServiceName(_ service: String) -> String {
        service.hasPrefix("kTCCService") ? String(service.dropFirst("kTCCService".count)) : service
    }
}
