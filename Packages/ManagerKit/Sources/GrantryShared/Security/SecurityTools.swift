/// Pfade der Werkzeuge und Dateien des Sicherheitsstatus – gemeinsam für App (Prüfungen) und Helper (Aktionen).
public enum SecurityTools {
    public static let fdesetup = "/usr/bin/fdesetup"
    public static let socketfilterfw = "/usr/libexec/ApplicationFirewall/socketfilterfw"
    public static let csrutil = "/usr/bin/csrutil"
    public static let spctl = "/usr/sbin/spctl"
    public static let xprotect = "/usr/bin/xprotect"
    public static let profiles = "/usr/bin/profiles"
    public static let softwareupdate = "/usr/sbin/softwareupdate"
    public static let defaults = "/usr/bin/defaults"
    public static let softwareUpdatePreferences = "/Library/Preferences/com.apple.SoftwareUpdate.plist"
    /// Domain für `defaults write` (Pfad ohne `.plist`; `defaults` geht über cfprefsd).
    public static let softwareUpdateDefaultsDomain = "/Library/Preferences/com.apple.SoftwareUpdate"
    /// Firewall- und Tarnmodus-Zustand unter macOS 27 (`com.apple.alf.plist` gibt es nicht mehr).
    public static let networkExtensionPreferences = "/Library/Preferences/com.apple.networkextension.plist"
    /// Aktuelles, per Hintergrund-Update eingespieltes XProtect.
    public static let xprotectBundle = "/var/protected/xprotect/XProtect.bundle"
    /// XProtect im Stand der OS-Installation.
    public static let systemXProtectBundle = "/Library/Apple/System/Library/CoreServices/XProtect.bundle"
}
