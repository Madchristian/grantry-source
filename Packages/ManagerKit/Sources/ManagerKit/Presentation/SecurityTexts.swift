// Deutsche Namen der Sicherheitsprüfungen und ihrer Werte (Verlauf, Benachrichtigungen, Bereich „Sicherheit“).

extension SecurityCheckKind {
    public var displayName: String {
        switch self {
        case .fileVault: "FileVault"
        case .firewall: "Firewall"
        case .sip: "Systemintegritätsschutz (SIP)"
        case .gatekeeper: "Gatekeeper"
        case .xprotect: "XProtect"
        case .automaticUpdates: "Automatische Updates"
        case .pendingUpdates: "Ausstehende Updates"
        case .mdmEnrollment: "Geräteverwaltung (MDM)"
        }
    }
}

extension SecurityState {
    public var displayName: String {
        switch self {
        case .good: "in Ordnung"
        case .warning: "Hinweis"
        case .critical: "kritisch"
        case .unknown: "nicht prüfbar"
        }
    }
}

extension FileVaultStatus {
    public var displayName: String {
        switch self {
        case .on: "an"
        case .off: "aus"
        case .encrypting: "Verschlüsselung läuft"
        case .decrypting: "Entschlüsselung läuft"
        case .pendingRestart: "wird nach dem Neustart eingeschaltet"
        }
    }
}

extension SIPStatus {
    public var displayName: String {
        switch self {
        case .enabled: "aktiv"
        case .customConfiguration: "teilweise aktiv"
        case .disabled: "ausgeschaltet"
        }
    }
}

extension SoftwareUpdateKey {
    /// Wortlaut nach Systemeinstellungen › Softwareupdate › Automatische Updates.
    public var displayName: String {
        switch self {
        case .automaticCheckEnabled: "Nach Updates suchen"
        case .automaticDownload: "Neue Updates laden"
        case .automaticallyInstallMacOSUpdates: "macOS-Updates installieren"
        case .criticalUpdateInstall: "Sicherheitsmaßnahmen installieren"
        case .configDataInstall: "Systemdateien installieren"
        }
    }
}

extension PendingUpdate {
    /// „macOS 27.0.1“; die Version wird nur angehängt, wenn der Name sie nicht schon enthält.
    public var displayTitle: String {
        guard let displayVersion, !displayName.contains(displayVersion) else { return displayName }
        return "\(displayName) \(displayVersion)"
    }
}
