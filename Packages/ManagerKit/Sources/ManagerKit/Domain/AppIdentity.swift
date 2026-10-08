/// Eine App oder ein Programm, das eine Berechtigung hält oder einen Autostart-Eintrag besitzt.
public struct AppIdentity: Hashable, Sendable, Codable {
    public var bundleID: String?
    public var path: String?
    public var displayName: String
    public var signing: SigningInfo
    /// Ob Bundle/Programm auf der Platte vorhanden ist; `unknown`, wenn sich das nicht feststellen lässt.
    public var presence: Presence

    public init(bundleID: String?, path: String?, displayName: String, signing: SigningInfo, presence: Presence) {
        self.bundleID = bundleID
        self.path = path
        self.displayName = displayName
        self.signing = signing
        self.presence = presence
    }

    /// Stabile Kennung: Bundle-ID, sonst Pfad, sonst Anzeigename.
    public var identifier: String { bundleID ?? path ?? displayName }
}

extension AppIdentity {
    private enum CodingKeys: String, CodingKey {
        case bundleID, path, displayName, signing, presence
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case exists
    }

    /// Liest auch Snapshots von vor der Einführung von `presence`, die nur `exists` speichern.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        displayName = try container.decode(String.self, forKey: .displayName)
        signing = try container.decode(SigningInfo.self, forKey: .signing)
        if let presence = try container.decodeIfPresent(Presence.self, forKey: .presence) {
            self.presence = presence
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            presence = Presence(legacyExists: try legacy.decode(Bool.self, forKey: .exists))
        }
    }
}
