/// Eine Systemerweiterung laut `systemextensionsctl list`. Jede Zeile ist ein eigener Eintrag – auch mehrere
/// Versionen derselben Bundle-ID, von denen die alten auf den Neustart warten.
///
/// Alle Texte stammen vom Hersteller der Erweiterung und sind einzeilig und gekürzt (`DisplayText.singleLine`).
public struct SystemExtension: Hashable, Sendable {
    public let category: SystemExtensionCategory
    /// Spalte `enabled` (`*`).
    public let isEnabled: Bool
    /// Spalte `active` (`*`).
    public let isActive: Bool
    /// `nil`, wenn die Spalte leer oder `-` ist.
    public let teamID: String?
    public let bundleID: String
    /// Erster Teil der Versionsangabe (`CFBundleShortVersionString`).
    public let version: String
    /// Zweiter Teil (`CFBundleVersion`); `nil`, wenn die Angabe keinen `/` enthält.
    public let buildVersion: String?
    public let name: String
    public let state: SystemExtensionState

    public init(
        category: SystemExtensionCategory, isEnabled: Bool, isActive: Bool, teamID: String?, bundleID: String,
        version: String, buildVersion: String?, name: String, state: SystemExtensionState
    ) {
        self.category = category
        self.isEnabled = isEnabled
        self.isActive = isActive
        self.teamID = teamID
        self.bundleID = bundleID
        self.version = version
        self.buildVersion = buildVersion
        self.name = name
        self.state = state
    }
}

/// Art der Systemerweiterung aus dem Abschnittskopf (`--- com.apple.system_extension.<art>`).
public enum SystemExtensionCategory: Hashable, Sendable {
    case driver
    case network
    case endpointSecurity
    case camera
    /// Unbekannte Art mit der Kennung aus dem Abschnittskopf.
    case unknown(String)

    init(identifier: String) {
        switch identifier {
        case "com.apple.system_extension.driver_extension": self = .driver
        case "com.apple.system_extension.network_extension": self = .network
        case "com.apple.system_extension.endpoint_security": self = .endpointSecurity
        case "com.apple.system_extension.cmio": self = .camera
        default: self = .unknown(identifier)
        }
    }
}

/// Zustand aus der letzten Spalte (`[activated enabled]`).
public enum SystemExtensionState: Hashable, Sendable {
    case activatedEnabled
    case activatedDisabled
    /// Wartet auf die Freigabe durch den Benutzer in den Systemeinstellungen.
    case activatedWaitingForUser
    /// Ersetzt oder deinstalliert; wird beim nächsten Neustart entfernt.
    case terminatedWaitingToUninstallOnReboot
    /// Unbekannter Zustand im Wortlaut.
    case unknown(String)

    init(text: String) {
        switch text {
        case "activated enabled": self = .activatedEnabled
        case "activated disabled": self = .activatedDisabled
        case "activated waiting for user": self = .activatedWaitingForUser
        case "terminated waiting to uninstall on reboot": self = .terminatedWaitingToUninstallOnReboot
        default: self = .unknown(text)
        }
    }
}

/// Ergebnis von `systemextensionsctl list`.
public struct SystemExtensionList: Hashable, Sendable {
    public let extensions: [SystemExtension]
    /// Zahl aus der Kopfzeile (`5 extension(s)`).
    public let declaredCount: Int
    /// Zeilen, die weder Kopf noch auswertbarer Eintrag sind.
    public let unreadableLineCount: Int

    public init(extensions: [SystemExtension], declaredCount: Int, unreadableLineCount: Int) {
        self.extensions = extensions
        self.declaredCount = declaredCount
        self.unreadableLineCount = unreadableLineCount
    }

    /// `true`, wenn jede Zeile lesbar war und die Kopfzahl zu den Einträgen passt. Sonst ist die Liste nur ein
    /// Ausschnitt und darf nicht als „alles gesehen“ gelten.
    public var isComplete: Bool { unreadableLineCount == 0 && declaredCount == extensions.count }
}
