import Foundation

/// Art eines Plug-ins, das ein Systemdienst lädt.
public enum ServicePluginKind: String, Hashable, Sendable, CaseIterable {
    /// Audio-Server-Plug-in (`Audio/Plug-Ins/HAL`), geladen von `coreaudiod`.
    case audio
    /// CoreMediaIO-DAL-Plug-in (`CoreMediaIO/Plug-Ins/DAL`), geladen von Apps mit Kamerazugriff.
    case video

    /// DAL-Plug-ins sind veraltete Technik; Apple ersetzt sie durch Kamera-Systemerweiterungen.
    public var isDeprecated: Bool { self == .video }
}

/// Wo ein Plug-in installiert ist.
public enum ServicePluginLocation: String, Hashable, Sendable {
    /// `/Library/…`: für alle Benutzer.
    case system
    /// `~/Library/…` des angemeldeten Benutzers.
    case currentUser
}

/// Ein Ordner, aus dem ein Systemdienst Plug-ins lädt.
struct ServicePluginDirectory: Hashable, Sendable {
    let kind: ServicePluginKind
    let location: ServicePluginLocation
    let path: String

    /// Audio aus `/Library` und `~/Library`, Video (DAL) aus `/Library` – DAL-Plug-ins im Benutzerordner lädt macOS nicht.
    static func standard(home: String) -> [ServicePluginDirectory] {
        [
            ServicePluginDirectory(kind: .audio, location: .system, path: "/Library/Audio/Plug-Ins/HAL"),
            ServicePluginDirectory(kind: .audio, location: .currentUser, path: (home as NSString).appendingPathComponent("Library/Audio/Plug-Ins/HAL")),
            ServicePluginDirectory(kind: .video, location: .system, path: "/Library/CoreMediaIO/Plug-Ins/DAL"),
        ]
    }
}

/// Ein Plug-in in einem Systemdienst mit Signatur.
///
/// Bundle-ID, Version, Name und Entwicklername stammen vom Hersteller und sind einzeilig und gekürzt (`ExtensionText`).
public struct ServicePlugin: Hashable, Sendable {
    public let kind: ServicePluginKind
    public let location: ServicePluginLocation
    public let bundleID: String
    /// `CFBundleShortVersionString`, ersatzweise `CFBundleVersion`.
    public let version: String?
    /// `CFBundleName`.
    public let name: String?
    /// Bundle-Pfad.
    public let path: String
    /// Signaturart, Notarisierung, Team-ID und Entwicklername (`SigningInspecting`).
    public let signing: SigningInfo
    /// `false`, wenn die Signaturprüfung nicht rechtzeitig endete: `signing` ist dann `.unknown`, ohne dass die Signatur
    /// ungültig sein muss.
    public let isSigningConclusive: Bool

    public init(
        kind: ServicePluginKind, location: ServicePluginLocation, bundleID: String, version: String?, name: String?,
        path: String, signing: SigningInfo, isSigningConclusive: Bool
    ) {
        self.kind = kind
        self.location = location
        self.bundleID = bundleID
        self.version = version
        self.name = name
        self.path = path
        self.signing = signing
        self.isSigningConclusive = isSigningConclusive
    }
}

/// Plug-ins aller Systemdienst-Ordner.
public struct ServicePluginList: Hashable, Sendable {
    public let plugins: [ServicePlugin]
    /// Nicht auswertbare Bundles oder Ordner (Symlink, Netzlaufwerk, fehlende Info.plist …).
    public let unreadable: [UnreadableExtension]

    public init(plugins: [ServicePlugin], unreadable: [UnreadableExtension] = []) {
        self.plugins = plugins
        self.unreadable = unreadable
    }

    /// `true`, wenn nichts übersprungen wurde; sonst ist die Liste nur ein Ausschnitt.
    public var isComplete: Bool { unreadable.isEmpty }
}
