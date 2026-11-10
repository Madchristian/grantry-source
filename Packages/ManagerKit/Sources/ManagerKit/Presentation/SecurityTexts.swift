// Deutsche Namen der Sicherheitsprüfungen und ihrer Werte (Verlauf, Benachrichtigungen, Bereich „Sicherheit“).

extension SecurityCheckKind {
    public var displayName: String {
        switch self {
        case .fileVault: "FileVault"
        case .automaticLogin: "Automatische Anmeldung"
        case .firewall: "Firewall"
        case .sharingServices: "Freigabedienste"
        case .sip: "Systemintegritätsschutz (SIP)"
        case .gatekeeper: "Gatekeeper"
        case .xprotect: "XProtect"
        case .automaticUpdates: "Automatische Updates"
        case .pendingUpdates: "Ausstehende Updates"
        case .mdmEnrollment: "Geräteverwaltung (MDM)"
        }
    }

    /// Kurzer Name für Kurzbefunde in Chips („SIP nicht prüfbar“).
    public var shortName: String {
        switch self {
        case .sip: "SIP"
        case .sharingServices: "Freigaben"
        case .pendingUpdates: "Updates"
        case .mdmEnrollment: "MDM"
        default: displayName
        }
    }

    /// Symbol der Prüfung in ihrer Zeile; den Zustand zeigt der Chip daneben.
    public var systemImage: String {
        switch self {
        case .fileVault: "lock.fill"
        case .automaticLogin: "person.badge.key.fill"
        case .firewall: "firewall"
        case .sharingServices: "person.2.fill"
        case .sip: "lock.shield.fill"
        case .gatekeeper: "checkmark.seal.fill"
        case .xprotect: "shield.lefthalf.filled"
        case .automaticUpdates: "arrow.triangle.2.circlepath"
        case .pendingUpdates: "arrow.down.circle.fill"
        case .mdmEnrollment: "building.2.fill"
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

extension SharingService {
    /// Wortlaut nach Systemeinstellungen › Allgemein › Teilen.
    public var displayName: String {
        switch self {
        case .screenSharing: "Bildschirmfreigabe"
        case .fileSharing: "Dateifreigabe"
        case .remoteLogin: "Entfernte Anmeldung"
        }
    }

    /// „Dateifreigabe (Port 445, 548)“.
    public var displayNameWithPorts: String {
        "\(displayName) (Port \(ports.map(String.init).joined(separator: ", ")))"
    }
}

extension PendingUpdate {
    /// „macOS 27.0.1“; die Version wird nur angehängt, wenn der Name sie nicht schon enthält.
    public var displayTitle: String {
        guard let displayVersion, !displayName.contains(displayVersion) else { return displayName }
        return "\(displayName) \(displayVersion)"
    }
}
