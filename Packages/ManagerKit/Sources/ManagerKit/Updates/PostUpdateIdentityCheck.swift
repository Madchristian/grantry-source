import Foundation
import GrantryShared
import Security

/// Nachgelagerte Prüfung: Sparkle 2.10.0 stellt keinen öffentlichen Pfad zur extrahierten App bereit.
/// Nur ein tatsächlich gestarteter Ziel-Build wird geprüft, keine unsignierten Entwicklerstarts.
@MainActor
public final class PostUpdateIdentityCheck {
    public static let warning = "Sicherheitswarnung: Die Signatur der aktualisierten Grantry-App stammt nicht vom erwarteten Entwickler oder konnte nicht geprüft werden. Automatische Installation ist gesperrt. Bitte Grantry aus einer vertrauenswürdigen Quelle neu installieren."

    private let preferences: UpdatePreferences
    private let build: Int
    private let isRelease: Bool
    private let appURL: URL
    private let validate: @Sendable (URL) async -> Bool

    public init(preferences: UpdatePreferences = UpdatePreferences(), build: Int = InstalledBuild.current().build,
                isRelease: Bool, appURL: URL = Bundle.main.bundleURL,
                validate: (@Sendable (URL) async -> Bool)? = nil) {
        self.preferences = preferences
        self.build = build
        self.isRelease = isRelease
        self.appURL = appURL
        self.validate = validate ?? { url in
            await BlockingWorkQueue(label: "update-identity").run {
                BlockingCallGuard.deepValidation.run(timeout: .seconds(15)) {
                    Self.hasReleaseIdentity(at: url)
                } ?? false
            }
        }
    }

    public func verify() async -> String? {
        guard isRelease, preferences.pendingIdentityVerificationBuild == build else { return nil }
        guard await validate(appURL) else { return Self.warning }
        preferences.pendingIdentityVerificationBuild = nil
        return nil
    }

    /// Vollständige statische Prüfung aller Architekturen und verschachtelten Codes gegen das zentrale
    /// Release-Requirement (inklusive Team, Bundle-ID, Developer ID und Ausschluss von get-task-allow).
    nonisolated static func hasReleaseIdentity(at url: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(GrantryIdentity.releaseAppRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}
