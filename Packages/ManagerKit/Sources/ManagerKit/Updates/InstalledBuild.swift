import Foundation

/// Die laufende Grantry-Version aus Sicht der Update-Prüfung.
public struct InstalledBuild: Equatable, Sendable {
    /// `CFBundleShortVersionString`, z. B. „2026.10.4“; „?“, wenn er fehlt.
    public let version: String
    /// `CFBundleVersion` als Zahl; 0, wenn er fehlt (dann ist jede veröffentlichte Version neuer).
    public let build: Int
    public let systemVersion: SystemVersion
    public let architecture: String

    init(info: [String: Any], systemVersion: SystemVersion, architecture: String) {
        version = info["CFBundleShortVersionString"] as? String ?? "?"
        build = (info["CFBundleVersion"] as? String).flatMap(Int.init) ?? 0
        self.systemVersion = systemVersion
        self.architecture = architecture
    }

    /// Version des laufenden App-Bundles.
    public static func current() -> InstalledBuild {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return InstalledBuild(
            info: Bundle.main.infoDictionary ?? [:], systemVersion: .current, architecture: architecture
        )
    }

    /// Einziger Header der Prüfung, z. B. „Grantry/2026.10.4 (276; macOS 27.0; arm64)“.
    public var userAgent: String {
        "Grantry/\(version) (\(build); macOS \(systemVersion); \(architecture))"
    }
}
