/// Wohin ein Klick auf eine Benachrichtigung führt. Die Meldung trägt das Ziel in ihrer `userInfo` (`userInfo`),
/// die App liest es beim Klick wieder aus (`init(userInfo:)`). Einzelmeldungen zu einer Sicherheitsprüfung führen zu
/// dieser Prüfung, Einzelmeldungen zu einer vorhandenen App zu ihr (Bereich Apps, `InstalledApp.id`), solche zu einem
/// laufenden Netzwerkdienst zu ihm (`NetworkListener.id`), alles andere – auch jede Sammelmeldung – in den Verlauf;
/// eine Meldung ohne lesbares Ziel (etwa aus einer älteren Version) ebenfalls.
/// Update-Meldungen führen in die Übersicht, Einzelmeldungen zu einem MCP-Server oder einer Freigabe in den Bereich Agenten.
public enum NotificationDestination: Hashable, Sendable {
    case history
    case securityCheck(SecurityCheckKind)
    case installedApp(String)
    case networkListener(String)
    /// MCP-Server oder Freigabe im Bereich Agenten, `id` des Eintrags.
    case agent(String)
    /// Neue Grantry-Version verfügbar; führt zur Übersicht mit dem Update-Hinweis.
    case update

    static let userInfoKey = "destination"
    private static let historyRawValue = "history"
    private static let updateRawValue = "update"
    private static let securityCheckPrefix = "securityCheck:"
    private static let installedAppPrefix = "installedApp:"
    private static let networkListenerPrefix = "networkListener:"
    private static let agentPrefix = "agent:"

    /// Ziel der Einzelmeldung zu `event`. Entfernte Einträge gibt es nur noch im Verlauf.
    public init(for event: ChangeEvent) {
        guard event.kind != .removed else {
            self = .history
            return
        }
        switch event.subject {
        case .securityCheck(let check): self = .securityCheck(check.kind)
        case .installedApp(let app): self = .installedApp(app.id)
        case .networkListener(let listener): self = .networkListener(listener.id)
        case .mcpServer(let server): self = .agent(server.id)
        case .agentAutoApproval(let approval): self = .agent(approval.id)
        case .grant, .autostartItem: self = .history
        }
    }

    /// Liest das Ziel aus der `userInfo` einer Benachrichtigung; `nil`, wenn keines oder ein unbekanntes hinterlegt ist.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo[Self.userInfoKey] as? String else { return nil }
        if raw == Self.historyRawValue {
            self = .history
        } else if raw == Self.updateRawValue {
            self = .update
        } else if raw.hasPrefix(Self.securityCheckPrefix),
                  let kind = SecurityCheckKind(rawValue: String(raw.dropFirst(Self.securityCheckPrefix.count))) {
            self = .securityCheck(kind)
        } else if raw.hasPrefix(Self.installedAppPrefix), raw.count > Self.installedAppPrefix.count {
            self = .installedApp(String(raw.dropFirst(Self.installedAppPrefix.count)))
        } else if raw.hasPrefix(Self.networkListenerPrefix), raw.count > Self.networkListenerPrefix.count {
            self = .networkListener(String(raw.dropFirst(Self.networkListenerPrefix.count)))
        } else if raw.hasPrefix(Self.agentPrefix), raw.count > Self.agentPrefix.count {
            self = .agent(String(raw.dropFirst(Self.agentPrefix.count)))
        } else {
            return nil
        }
    }

    /// Inhalt für die `userInfo` der Benachrichtigung.
    public var userInfo: [String: String] { [Self.userInfoKey: rawValue] }

    private var rawValue: String {
        switch self {
        case .history: Self.historyRawValue
        case .securityCheck(let kind): Self.securityCheckPrefix + kind.rawValue
        case .installedApp(let id): Self.installedAppPrefix + id
        case .networkListener(let id): Self.networkListenerPrefix + id
        case .agent(let id): Self.agentPrefix + id
        case .update: Self.updateRawValue
        }
    }
}
