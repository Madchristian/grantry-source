import Foundation

/// Speicherort einer TCC-Datenbank.
public struct TCCDatabaseLocation: Sendable, Hashable {
    public let path: String
    public let scope: TCCScope

    public init(path: String, scope: TCCScope) {
        self.path = path
        self.scope = scope
    }

    /// Klassischer Pfad der Benutzer-TCC.db.
    ///
    /// Unter macOS 27 existiert diese Datei nicht mehr: Die Grants des Benutzers liegen in einem geschützten
    /// Container, den Drittanbieter-Apps selbst mit Festplattenvollzugriff nicht lesen können. Der Ort bleibt für
    /// ältere Layouts und spätere Untersuchungen erhalten; die zugehörige Quelle scheitert dort mit `.cannotOpen`.
    public static let user = TCCDatabaseLocation(
        path: NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db", scope: .user
    )
    public static let system = TCCDatabaseLocation(
        path: "/Library/Application Support/com.apple.TCC/TCC.db", scope: .system
    )
}

/// Liest Berechtigungen aus genau einer TCC-Datenbank.
///
/// Pro Datenbank gibt es eine eigene Quelle (`id` folgt dem Bereich), damit eine unlesbare Datenbank nur ihre
/// eigenen Grants als ausgefallen markiert. Der Fehler wird unverändert weitergereicht; `.cannotOpen` belegt allein
/// keinen fehlenden Festplattenvollzugriff.
public struct TCCSource: InventorySource {
    public let database: TCCDatabaseLocation
    private let reader: TCCDatabaseReader
    private let resolver: any AppResolving

    public var id: SourceID { database.scope.sourceID }

    public init(database: TCCDatabaseLocation, reader: TCCDatabaseReader = .init(), resolver: any AppResolving) {
        self.database = database
        self.reader = reader
        self.resolver = resolver
    }

    /// Quelle(n) am Standardort.
    ///
    /// - Parameter includeUserDatabase: Ergänzt die Benutzer-TCC.db vor der System-DB. Standardmäßig `false`:
    ///   v1 scannt nach Nutzerentscheidung nur die System-Datenbank – die Benutzer-DB ist unter macOS 27 ohnehin
    ///   nicht mehr lesbar, selbst mit Festplattenvollzugriff (siehe `TCCDatabaseLocation.user`).
    public static func standard(
        reader: TCCDatabaseReader = .init(), resolver: any AppResolving, includeUserDatabase: Bool = false
    ) -> [any InventorySource] {
        let locations: [TCCDatabaseLocation] = includeUserDatabase ? [.user, .system] : [.system]
        return locations.map { TCCSource(database: $0, reader: reader, resolver: resolver) }
    }

    /// Prüft vor dem blockierenden SQLite-Lesen auf Abbruch, liest danach zuerst die ganze Datenbank, damit ein
    /// Fehler keine unnötigen Auflösungen auslöst. Jeder Client wird pro Durchlauf nur einmal aufgelöst, auch wenn
    /// er in vielen Zeilen vorkommt.
    public func collect() async throws -> InventoryContribution {
        try Task.checkCancellation()
        let rows = try reader.readAccessRows(at: database.path)

        var identities: [ClientKey: AppIdentity] = [:]
        var grants: [PermissionGrant] = []
        grants.reserveCapacity(rows.count)
        for row in rows {
            let key = ClientKey(row)
            let client: AppIdentity
            if let known = identities[key] {
                client = known
            } else {
                client = await resolve(key)
                identities[key] = client
            }
            grants.append(PermissionGrant(
                service: row.service,
                client: client,
                authValue: AuthValue(rawValue: row.authValue),
                scope: database.scope,
                lastModified: row.lastModified,
                clientID: row.client,
                target: row.indirectObject
            ))
        }
        return InventoryContribution(grants: grants)
    }

    private func resolve(_ key: ClientKey) async -> AppIdentity {
        switch key.type {
        case .bundleID: await resolver.resolve(bundleID: key.client)
        case .path: await resolver.resolve(path: key.client)
        }
    }

    /// Roher Client samt Art – bestimmt eindeutig, wie er aufgelöst wird.
    private struct ClientKey: Hashable {
        let client: String
        let type: TCCRow.ClientType

        init(_ row: TCCRow) {
            client = row.client
            type = row.clientType
        }
    }
}
