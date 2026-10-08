import Foundation

/// Wurzeln für Reste-Suche und Sperrliste: Benutzerordner und Systemwurzel (`/`, in Tests ein Scratch-Ordner).
/// Beide kanonisch (Symlinks aufgelöst), ohne abschließenden `/` (außer `/`).
public struct LibraryLayout: Sendable, Equatable {
    public let home: String
    public let systemRoot: String

    public init(home: String, systemRoot: String) {
        self.home = Self.canonical(home)
        self.systemRoot = Self.canonical(systemRoot)
    }

    public static var standard: LibraryLayout {
        LibraryLayout(home: NSHomeDirectory(), systemRoot: "/")
    }

    func userLibrary(_ relative: String) -> String { home + "/Library/" + relative }
    func system(_ relative: String) -> String { systemRoot == "/" ? "/" + relative : systemRoot + "/" + relative }

    /// Wurzeln der App-Bundles (wie die App-Inventur).
    var appRoots: [String] { [system("Applications"), home + "/Applications"] }

    /// Apps des versiegelten Systems; ihre Bundle-IDs kann keine andere App besitzen (`AppleAppVerification`).
    var systemAppRoots: [String] {
        ["System/Applications", "System/Applications/Utilities", "System/Library/CoreServices",
         "System/Library/CoreServices/Applications"].map(system)
    }

    /// Ordner mit Komponenten-Bundles ohne `.app` (Review M1): Systemeinstellungen, Bildschirmschoner, Kernel-
    /// Erweiterungen; Audio-Plug-ins liegen eine Ebene tiefer (`componentParentDirectories`).
    var componentDirectories: [String] {
        ["Library/PreferencePanes", "Library/Screen Savers", "Library/Extensions"].map(system)
            + ["PreferencePanes", "Screen Savers"].map(userLibrary)
    }

    /// Ordner, deren Unterordner Komponenten-Bundles enthalten (`Audio/Plug-Ins/{HAL,Components,VST3,…}`).
    var componentParentDirectories: [String] {
        [system("Library/Audio/Plug-Ins"), userLibrary("Audio/Plug-Ins")]
    }

    /// Hilfsprogramme privilegierter Dienste; ihr Dateiname ist eine Kennung (`com.docker.vmnetd`).
    var privilegedHelperTools: String { system("Library/PrivilegedHelperTools") }

    /// `true` für Reste-Orte unter `/Library` (statt `~/Library`).
    func isSystemWide(_ location: LeftoverLocation) -> Bool {
        location.directory.hasPrefix(system("Library") + "/")
    }

    /// Reste-Orte (Spec v3 §3) in Suchreihenfolge. Namenstreffer nur in Application Support, Caches und Logs des
    /// Benutzers sowie `/Library/Application Support` (Plan-Abweichung 7).
    var leftoverLocations: [LeftoverLocation] {
        [
            LeftoverLocation(kind: .container, directory: userLibrary("Containers"), naming: .bundleID, allowsNameMatches: false),
            LeftoverLocation(kind: .groupContainer, directory: userLibrary("Group Containers"), naming: .groupContainer,
                             allowsNameMatches: false),
            LeftoverLocation(kind: .applicationSupport, directory: userLibrary("Application Support"), naming: .bundleID,
                             allowsNameMatches: true),
            LeftoverLocation(kind: .caches, directory: userLibrary("Caches"), naming: .bundleID, allowsNameMatches: true),
            LeftoverLocation(kind: .preferences, directory: userLibrary("Preferences"), naming: .preferences, allowsNameMatches: false),
            LeftoverLocation(kind: .preferences, directory: userLibrary("Preferences/ByHost"), naming: .preferences,
                             allowsNameMatches: false),
            LeftoverLocation(kind: .savedState, directory: userLibrary("Saved Application State"), naming: .savedState,
                             allowsNameMatches: false),
            LeftoverLocation(kind: .httpStorage, directory: userLibrary("HTTPStorages"), naming: .bundleID, allowsNameMatches: false),
            LeftoverLocation(kind: .webKit, directory: userLibrary("WebKit"), naming: .bundleID, allowsNameMatches: false),
            LeftoverLocation(kind: .logs, directory: userLibrary("Logs"), naming: .bundleID, allowsNameMatches: true),
            LeftoverLocation(kind: .applicationScripts, directory: userLibrary("Application Scripts"), naming: .bundleID,
                             allowsNameMatches: false),
            LeftoverLocation(kind: .applicationSupport, directory: system("Library/Application Support"), naming: .bundleID,
                             allowsNameMatches: true),
            LeftoverLocation(kind: .caches, directory: system("Library/Caches"), naming: .bundleID, allowsNameMatches: false),
            LeftoverLocation(kind: .preferences, directory: system("Library/Preferences"), naming: .preferences,
                             allowsNameMatches: false),
        ]
    }

    /// Harte Sperrliste (Spec v3 §3 „Niemals angefasst“), ergänzt um Systemordner hinter Symlinks (`/etc`, `/var`, `/tmp`)
    /// und schützenswerte Einträge innerhalb der Reste-Orte (iPhone-Sicherungen, TCC-Datenbank, Kontakte, Anrufliste,
    /// Wissensdatenbank, iCloud-Daten, zuletzt benutzte Objekte, Anmeldefenster). Apple-Kennungen (`com.apple.…`,
    /// `group.com.apple.…`) sperrt der `RemovalGuard` zusätzlich, versteckte Einträge (`.GlobalPreferences.plist`) ebenso.
    var blockedPaths: [String] {
        ["System", "usr", "bin", "sbin", "private", "etc", "var", "tmp", "cores", "dev", "Library/Apple", "Library/Keychains",
         "Library/Application Support/com.apple.TCC"].map(system)
            + ["Mobile Documents", "Keychains", "Mail", "Messages", "Photos", "CloudStorage", "Accounts", "Safari",
               "Application Support/MobileSync", "Application Support/com.apple.TCC", "Application Support/AddressBook",
               "Application Support/CallHistoryDB", "Application Support/Knowledge", "Application Support/FileProvider",
               "Application Support/CloudDocs", "Application Support/com.apple.sharedfilelist",
               "Preferences/loginwindow.plist"].map(userLibrary)
    }

    private static func canonical(_ path: String) -> String {
        let canonical = AppleComponent.canonicalPath(path) ?? path
        return canonical.count > 1 && canonical.hasSuffix("/") ? String(canonical.dropLast()) : canonical
    }
}
