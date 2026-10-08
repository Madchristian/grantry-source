/// Feste Identitäten von App und Helper. Grundlage der gegenseitigen Code-Signatur-Prüfung über XPC.
public enum GrantryIdentity {
    public static let logSubsystem = "de.cstrube.Grantry"
    public static let appBundleID = "de.cstrube.Grantry"
    public static let helperBundleID = "de.cstrube.Grantry.Helper"
    /// Mach-Service des Helpers; muss mit `MachServices` in der launchd-Plist übereinstimmen.
    public static let helperMachServiceName = "de.cstrube.Grantry.Helper"
    /// Dateiname der launchd-Plist in `Contents/Library/LaunchDaemons` (für `SMAppService.daemon(plistName:)`).
    public static let helperPlistName = "de.cstrube.Grantry.Helper.plist"
    public static let teamID = "73SP5UXC3Q"

    /// Code-Requirement für ein Programm dieses Teams mit gegebener Kennung.
    public static func codeRequirement(identifier: String, teamID: String = teamID) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// Der Helper akzeptiert nur Verbindungen der App. Erfüllen auch Entwicklungs-Builds (nur für `DEBUG`-Helper).
    public static var appRequirement: String { codeRequirement(identifier: appBundleID) }

    /// Signatur mit einem Developer-ID-Application-Zertifikat: Zwischenzertifikat „Developer ID CA“
    /// (OID 1.2.840.113635.100.6.2.6) und Blatt „Developer ID Application“ (OID 1.2.840.113635.100.6.1.13).
    public static let developerIDRequirement =
        "certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    /// Wie `appRequirement`, verlangt aber eine Developer-ID-Signatur und schließt Builds mit dem Entitlement
    /// `com.apple.security.get-task-allow` aus.
    ///
    /// Eine App mit `get-task-allow` (typisch für Entwicklungs-Builds, meist ohne Hardened Runtime) darf von jedem
    /// Prozess desselben Benutzers per `task_for_pid` übernommen werden: Eingeschleuster Code liefe dann mit gültiger
    /// Team-Signatur und könnte den root-Helper steuern. Die Developer-ID-Bedingung schließt zusätzlich alle mit
    /// „Apple Development“ signierten Builds aus. Release-Builds des Helpers verlangen daher dieses Requirement.
    public static var releaseAppRequirement: String {
        appRequirement + " and " + developerIDRequirement + #" and !(entitlement["com.apple.security.get-task-allow"] exists)"#
    }

    /// Die App vertraut nur dem eigenen Helper.
    public static var helperRequirement: String { codeRequirement(identifier: helperBundleID) }
}
