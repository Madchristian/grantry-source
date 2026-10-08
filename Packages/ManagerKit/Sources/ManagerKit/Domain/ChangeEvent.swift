import Foundation

/// Der Gegenstand einer Änderung.
public enum ChangeSubject: Hashable, Sendable, Codable {
    case grant(PermissionGrant)
    case autostartItem(AutostartItem)
    case securityCheck(SecurityCheck)
    case installedApp(InstalledApp)
    case networkListener(NetworkListener)
    case mcpServer(MCPServerEntry)
    case agentAutoApproval(AgentAutoApproval)

    /// `id` des betroffenen Eintrags.
    public var recordID: String {
        switch self {
        case .grant(let grant): grant.id
        case .autostartItem(let item): item.id
        case .securityCheck(let check): check.id
        case .installedApp(let app): app.id
        case .networkListener(let listener): listener.id
        case .mcpServer(let server): server.id
        case .agentAutoApproval(let approval): approval.id
        }
    }
}

/// Eine erkannte Änderung zwischen zwei Snapshots.
public struct ChangeEvent: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case added, removed, modified
    }

    public let kind: Kind
    public let before: ChangeSubject?
    public let after: ChangeSubject?
    public let detectedAt: Date

    public init(kind: Kind, before: ChangeSubject?, after: ChangeSubject?, detectedAt: Date) {
        precondition(before != nil || after != nil, "ChangeEvent braucht before oder after")
        self.kind = kind
        self.before = before
        self.after = after
        self.detectedAt = detectedAt
    }

    private enum CodingKeys: String, CodingKey {
        case kind, before, after, detectedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let before = try container.decodeIfPresent(ChangeSubject.self, forKey: .before)
        let after = try container.decodeIfPresent(ChangeSubject.self, forKey: .after)
        guard before != nil || after != nil else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "ChangeEvent braucht before oder after"
                )
            )
        }
        self.kind = try container.decode(Kind.self, forKey: .kind)
        self.before = before
        self.after = after
        self.detectedAt = try container.decode(Date.self, forKey: .detectedAt)
    }

    /// Aktueller Zustand, bei `.removed` der letzte bekannte.
    public var subject: ChangeSubject { after ?? before! }
}
