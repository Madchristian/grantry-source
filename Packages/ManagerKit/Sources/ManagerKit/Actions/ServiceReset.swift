/// Setzt einen Datenschutz-Dienst für **alle** Apps zurück (`tccutil reset <Dienst>` ohne Bundle-ID).
///
/// Der einzige Weg, Berechtigungen entfernter Apps loszuwerden: `tccutil reset <Dienst> <Bundle-ID>` löst die
/// Bundle-ID über Launch Services auf und scheitert, sobald die App fehlt (`OSStatus -10814`); die TCC-Datenbank selbst
/// schützt SIP, und die Systemeinstellungen blenden Einträge entfernter Apps aus. Der Preis: Auch alle installierten
/// Apps verlieren die Berechtigung (`collateral`) – die Bestätigung muss sie deshalb nennen.
public struct ServiceReset: Hashable, Sendable, Identifiable {
    /// TCC-Dienst, z. B. `kTCCServiceAccessibility`.
    public let service: String
    /// Quelle der verwaisten Einträge; an ihr wird die Wirkung geprüft.
    public let source: SourceID
    /// Berechtigungen entfernter Apps (`PermissionGrant.isOrphaned`) – um sie geht es.
    public let orphans: [PermissionGrant]
    /// Alle übrigen Einträge des Dienstes: Sie gehen ebenfalls verloren.
    public let collateral: [PermissionGrant]

    /// `nil`, wenn der Dienst in `snapshot` keine Berechtigung einer entfernten App hat – dann gibt es nichts aufzuräumen.
    public init?(service: String, in snapshot: Snapshot) {
        let grants = snapshot.grants.filter { $0.service == service }
        let orphans = grants.filter(\.isOrphaned)
        guard let first = orphans.first else { return nil }
        self.service = service
        source = first.source
        self.orphans = orphans
        collateral = grants.filter { !$0.isOrphaned }
    }

    public var id: String { Self.recordID(for: service) }

    /// `ActionRunner.runningRecordID`, solange der Dienst zurückgesetzt wird.
    public static func recordID(for service: String) -> String { "service-reset|\(service)" }

    public var serviceName: String { PermissionCatalog.service(for: service).displayName }

    /// Namen der entfernten Apps, sortiert und ohne Doppelte (Automation führt eine Zeile je Ziel).
    public var orphanNames: [String] { Self.names(orphans) }

    /// Namen der übrigen Apps, die die Berechtigung verlieren.
    public var collateralNames: [String] { Self.names(collateral) }

    /// Ob auch die App mit `bundleID` (in der App Grantry selbst) die Berechtigung verliert.
    public func affects(bundleID: String?) -> Bool {
        bundleID.map { id in collateral.contains { $0.client.bundleID == id } } ?? false
    }

    private static func names(_ grants: [PermissionGrant]) -> [String] {
        Set(grants.map(\.client.displayName)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
