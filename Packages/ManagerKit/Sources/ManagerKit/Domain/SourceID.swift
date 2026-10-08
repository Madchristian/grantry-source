import Foundation

/// Identifiziert eine Datenquelle (TCC, launchd, BTM, künftige Module).
public struct SourceID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    /// Benutzer-TCC-Datenbank; getrennt von der System-Datenbank, damit ein Ausfall die andere nicht mitreißt.
    public static let tccUser = SourceID(rawValue: "tcc.user")
    /// System-TCC-Datenbank.
    public static let tccSystem = SourceID(rawValue: "tcc.system")
    public static let launchd = SourceID(rawValue: "launchd")
    public static let btm = SourceID(rawValue: "btm")
    /// Sicherheitsstatus (Spec v2).
    public static let securityPosture = SourceID(rawValue: "security.posture")
    /// Installierte Apps (Spec v3).
    public static let apps = SourceID(rawValue: "apps")
    /// Lauschende Netzwerkdienste (#128).
    public static let networkListeners = SourceID(rawValue: "network.listeners")
    /// Agenten-Konfigurationen: MCP-Server und automatische Freigaben (#129).
    public static let agents = SourceID(rawValue: "agents.mcp")
}

/// Fehler einer einzelnen Quelle; die übrigen Quellen bleiben davon unberührt.
public struct SourceError: Hashable, Sendable, Codable {
    public let source: SourceID
    public let message: String
    public init(source: SourceID, message: String) {
        self.source = source
        self.message = message
    }
}

/// Einschränkung einer Quelle, die trotzdem geliefert hat – etwa ausgefallene Signaturprüfungen (Review M2). Anders als
/// ein `SourceError` gilt die Quelle nicht als fehlgeschlagen; ihre Einträge zählen normal.
public struct SourceLimitation: Hashable, Sendable, Codable {
    public let source: SourceID
    public let message: String
    /// Ein erneuter Scan kann die Einschränkung beheben (etwa Zeitüberschreitung, Helper-Abfrage gescheitert, #142);
    /// sonst braucht es einen Eingriff außerhalb von Grantry (kaputte Plist, Netzlaufwerk, Leserechte).
    public let isRetryable: Bool

    public init(source: SourceID, message: String, isRetryable: Bool = false) {
        self.source = source
        self.message = message
        self.isRetryable = isRetryable
    }

    private enum CodingKeys: String, CodingKey {
        case source, message, isRetryable
    }

    /// Ältere Einschränkungen ohne `isRetryable` gelten als nicht durch einen Scan behebbar.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(source: try container.decode(SourceID.self, forKey: .source),
                  message: try container.decode(String.self, forKey: .message),
                  isRetryable: try container.decodeIfPresent(Bool.self, forKey: .isRetryable) ?? false)
    }
}

/// Beitrag einer Quelle zu einem Snapshot.
public struct InventoryContribution: Sendable, Equatable {
    public var grants: [PermissionGrant]
    public var autostartItems: [AutostartItem]
    public var securityChecks: [SecurityCheck]
    public var installedApps: [InstalledApp]
    public var agents: AgentContribution
    /// Ordner, die die Quelle nicht vollständig lesen konnte: Ihre Apps aus dem Vorgänger werden fortgeschrieben, statt
    /// als entfernt zu gelten (`Snapshot.carryingForwardApps`, Review M3). Die Quelle gilt trotzdem als erfolgreich.
    public var incompleteFolders: [String]
    /// launchd-Plists und Plist-Verzeichnisse, die die Quelle nicht auswerten konnte (#139): Ihre bekannten
    /// Autostart-Einträge aus dem Vorgänger werden mit altem Stand fortgeschrieben, statt als entfernt zu gelten
    /// (`Snapshot.carryingForwardAutostartItems`). Die Quelle gilt trotzdem als erfolgreich; den Grund nennt `limitations`.
    public var incompletePlistPaths: [String]
    /// Einschränkungen dieses Beitrags im Klartext (`Snapshot.sourceLimitations`), die erst ein Eingriff behebt.
    public var limitations: [String]
    /// Einschränkungen, die ein erneuter Scan beheben kann (`SourceLimitation.isRetryable`, #142).
    public var retryableLimitations: [String]
    public var networkListeners: [NetworkListener]
    /// Gesetzt, wenn nur Sockets dieses Benutzers lesbar waren: Lauscher anderer Benutzer werden fortgeschrieben.
    public var listenersLimitedToUID: UInt32?
    /// `false` bei einer Zwischenmessung, die nicht den vollen Umfang der Quelle abdeckt (Lauscher: nur eigene Prozesse
    /// zwischen den Helper-Abfragen, #142). Sie ersetzt nicht den Zeitpunkt der vollständigen Lieferung
    /// (`Snapshot.lastDeliveryBySource`), sondern zählt als Zwischenmessung (`Snapshot.lastInterimDeliveryBySource`).
    public var coversFullScope: Bool
    /// Kennung eines vorgemerkten Zustandsübergangs der Quelle, den sie erst in `InventorySource.accept(_:)` festschreibt
    /// (Lauscher: Erfolg einer Helper-Messung, #142); `nil` ohne.
    public var acceptanceToken: UUID?
    /// Von Grantry beendete Lauscher, die nicht wieder gesehen wurden: werden nicht fortgeschrieben
    /// (`ListenerTerminationLedger`).
    public var endedListenerIDs: Set<String>

    public init(
        grants: [PermissionGrant] = [], autostartItems: [AutostartItem] = [], securityChecks: [SecurityCheck] = [],
        installedApps: [InstalledApp] = [], agents: AgentContribution = AgentContribution(),
        incompleteFolders: [String] = [], incompletePlistPaths: [String] = [], limitations: [String] = [],
        retryableLimitations: [String] = [], networkListeners: [NetworkListener] = [], listenersLimitedToUID: UInt32? = nil,
        endedListenerIDs: Set<String> = [], coversFullScope: Bool = true, acceptanceToken: UUID? = nil
    ) {
        self.grants = grants
        self.autostartItems = autostartItems
        self.securityChecks = securityChecks
        self.installedApps = installedApps
        self.agents = agents
        self.incompleteFolders = incompleteFolders
        self.incompletePlistPaths = incompletePlistPaths
        self.limitations = limitations
        self.retryableLimitations = retryableLimitations
        self.networkListeners = networkListeners
        self.listenersLimitedToUID = listenersLimitedToUID
        self.endedListenerIDs = endedListenerIDs
        self.coversFullScope = coversFullScope
        self.acceptanceToken = acceptanceToken
    }
}
