import Foundation

public enum UpdateInstallationError: LocalizedError, Equatable {
    case invalidSignature, downgrade, busy, noWritePermission, invalidArchive

    public var errorDescription: String? {
        switch self {
        case .invalidSignature: "Die Update-Signatur fehlt oder ist ungültig. Die bisherige Version bleibt erhalten."
        case .downgrade: "Eine ältere oder abweichende Version wird nicht installiert."
        case .busy: "Bitte zuerst das Aufräumen, Entfernen oder die Helper-Aktion abschließen."
        case .noWritePermission: "Keine Schreibrechte am Installationsort. Bitte Grantry in /Applications mit einem berechtigten Benutzer aktualisieren."
        case .invalidArchive: "Das Update enthält keine passende Grantry-App."
        }
    }
}

/// Strengere Grantry-Regeln zusätzlich zu Sparkles eigener Signatur- und Austauschprüfung.
public enum UpdateInstallationPolicy {
    /// Alte unsignierte Einträge dürfen angezeigt, aber nie zur Installation verwendet werden.
    public static func validateOffer(_ item: AppcastItem, installed: InstalledBuild) throws {
        guard let signature = item.edSignature, Data(base64Encoded: signature)?.count == 64,
              let length = item.length, length > 0 else { throw UpdateInstallationError.invalidSignature }
        // CalVer-Suffixe sind nicht numerisch sortierbar: 2026.10.192 → 2026.10.20 ist ein Upgrade.
        // Wie Sparkle dient deshalb ausschließlich der streng steigende CFBundleVersion als Versionsordnung.
        guard UpdateChecker.isApplicable(item, installed: installed)
        else { throw UpdateInstallationError.downgrade }
    }

    @MainActor
    public static func canInstall(isCleaning: Bool, isRemoving: Bool, helperActivity: HelperActivityLock) -> Bool {
        !isCleaning && !isRemoving && helperActivity.isIdle
    }
}

/// Der Prüftakt und die Zustimmung gehören weiterhin allein `UpdateModel`.
/// Implementierungen dürfen keinen zweiten automatischen Feed-Prüftakt starten.
@MainActor
public protocol UpdateInstalling: AnyObject {
    var onStatus: ((String?, String?) -> Void)? { get set }
    func check() async throws -> AppcastItem?
    func install(_ item: AppcastItem, automatically: Bool)
    func setAutomaticInstallation(_ enabled: Bool)
    func cancelCheck()
    /// Bereits eingeleiteten Abbruch vor dem Beenden abschließen (kein Installer darf danach nachlaufen).
    func prepareToTerminate() async
}

public extension UpdateInstalling {
    func prepareToTerminate() async {}
}
