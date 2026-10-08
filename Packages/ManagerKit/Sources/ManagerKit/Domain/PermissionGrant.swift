import Foundation

/// Wert der Spalte `auth_value` in der TCC-Datenbank.
public enum AuthValue: Hashable, Sendable, Codable {
    case denied, allowed, limited
    case unknown(Int)

    public init(rawValue: Int) {
        switch rawValue {
        case 0: self = .denied
        case 2: self = .allowed
        case 3: self = .limited
        default: self = .unknown(rawValue)
        }
    }

    /// TCC-`auth_value` für diesen Fall: `denied` 0, `allowed` 2, `limited` 3, `unknown` der Rohwert.
    public var rawValue: Int {
        switch self {
        case .denied: return 0
        case .allowed: return 2
        case .limited: return 3
        case .unknown(let value): return value
        }
    }

    /// Zugriff, der tatsächlich möglich ist (`allowed`, `limited`); `denied` und unbekannte Rohwerte zählen nicht.
    public var isGranted: Bool { self == .allowed || self == .limited }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Benutzer- oder System-TCC-Datenbank.
public enum TCCScope: String, Hashable, Sendable, Codable {
    case user, system

    /// Quelle, die die Datenbank dieses Bereichs liest.
    public var sourceID: SourceID {
        switch self {
        case .user: .tccUser
        case .system: .tccSystem
        }
    }
}

/// Eine Datenschutz-Berechtigung (Zeile der TCC-Tabelle `access`).
public struct PermissionGrant: InventoryRecord, Codable {
    public var service: String
    public var client: AppIdentity
    public var authValue: AuthValue
    public var scope: TCCScope
    public var lastModified: Date
    /// Roher `client`-Wert aus TCC; stabil, auch wenn sich die Auflösung der App ändert.
    public var clientID: String
    /// Zielobjekt bei Automation (`indirect_object_identifier`), sonst `nil`.
    public var target: String?

    public init(
        service: String, client: AppIdentity, authValue: AuthValue, scope: TCCScope, lastModified: Date,
        clientID: String? = nil, target: String? = nil
    ) {
        self.service = service
        self.client = client
        self.authValue = authValue
        self.scope = scope
        self.lastModified = lastModified
        self.clientID = clientID ?? client.identifier
        self.target = target
    }

    /// `scope|service|clientID`, bei Automation ergänzt um `|target`. IDs ohne Ziel bleiben dadurch unverändert.
    public var id: String {
        let base = "\(scope.rawValue)|\(service)|\(clientID)"
        return target.map { "\(base)|\($0)" } ?? base
    }
    public var source: SourceID { scope.sourceID }

    public func hasSignificantChanges(comparedTo other: PermissionGrant) -> Bool {
        authValue != other.authValue
    }

    /// Berechtigung einer entfernten App (fehlt nachweislich oder vermutlich), ohne Apple-Komponenten. Einzeln lässt
    /// sie sich nicht zurücksetzen (`tccutil` braucht die installierte App), nur mit dem ganzen Dienst (`ServiceReset`).
    public var isOrphaned: Bool {
        [.missing, .probablyMissing].contains(client.presence) && !AppleComponent.contains(self)
    }
}
