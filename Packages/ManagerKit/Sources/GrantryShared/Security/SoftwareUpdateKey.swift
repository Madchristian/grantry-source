/// Boolesche Schlüssel in `/Library/Preferences/com.apple.SoftwareUpdate.plist`, die Grantry liest und (über den
/// Helper) nur auf `true` setzt. Fehlt ein Schlüssel, gilt der macOS-Standard „an“.
public enum SoftwareUpdateKey: String, Hashable, Sendable, Codable, CaseIterable {
    case automaticCheckEnabled = "AutomaticCheckEnabled"
    case automaticDownload = "AutomaticDownload"
    case criticalUpdateInstall = "CriticalUpdateInstall"
    case configDataInstall = "ConfigDataInstall"
    case automaticallyInstallMacOSUpdates = "AutomaticallyInstallMacOSUpdates"
}
