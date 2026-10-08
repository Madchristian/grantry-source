#if DEBUG
import Foundation

/// Feste Zustände von „Grantry deinstallieren …“ für die SwiftUI-Previews (#143) – ohne Dienste, Finder oder Papierkorb.
public enum SelfUninstallPreviewData {
    private static let grantry = AppIdentity(
        bundleID: GrantryIdentity.appBundleID, path: "/Applications/Grantry.app", displayName: "Grantry",
        signing: SigningInfo(kind: .developerID, teamID: "73SP5UXC3Q", isNotarized: true), presence: .present
    )
    private static let app = LeftoverCandidate(path: "/Applications/Grantry.app", kind: .appBundle, confidence: .safe)
    private static let data = LeftoverCandidate(
        path: NSHomeDirectory() + "/Library/Application Support/Grantry", kind: .applicationSupport, confidence: .safe
    )
    private static let fullDiskAccess = PermissionGrant(
        service: "kTCCServiceSystemPolicyAllFiles", client: grantry, authValue: .allowed, scope: .system, lastModified: .now
    )
    private static let automation = PermissionGrant(
        service: PermissionCatalog.automationServiceID, client: grantry, authValue: .allowed, scope: .user,
        lastModified: .now, target: "com.apple.finder"
    )
    private static let plan = SelfUninstallPlan(files: [app, data], grants: [fullDiskAccess, automation])

    /// Dienste sind abgemeldet, der Finder legt gerade in den Papierkorb (ggf. mit Passwortabfrage).
    public static var trashing: SelfUninstallProgress {
        var progress = SelfUninstallProgress(plan: plan)
        progress.apply(.started(.finderAccess))
        progress.apply(.finished(.finderAccess, []))
        progress.apply(.started(.services))
        progress.apply(.finished(.services, [.init(subject: .helper, result: .done)]))
        progress.apply(.started(.services))
        progress.apply(.finished(.services, [.init(subject: .loginItem, result: .skipped(SelfUninstaller.notRegisteredReason))]))
        progress.apply(.started(.permissions))
        progress.apply(.finished(.permissions, [.init(subject: .grant(fullDiskAccess), result: .done)]))
        progress.apply(.started(.trash))
        return progress
    }

    /// Passwortabfrage abgebrochen: Daten im Papierkorb, Grantry nicht – Wiederholung möglich.
    public static var passwordCancelled: SelfUninstallProgress {
        finished([
            .init(subject: .helper, result: .done),
            .init(subject: .loginItem, result: .skipped(SelfUninstaller.notRegisteredReason)),
            .init(subject: .grant(fullDiskAccess), result: .done),
            .init(subject: .file(app), result: .failed("Abgebrochen (z. B. Passwortabfrage)")),
            .init(subject: .file(data), result: .done),
            .init(subject: .grant(automation), result: .skipped(SelfUninstaller.blockedReason)),
        ], blockedBy: .file(app))
    }

    /// Der Hintergrunddienst ließ sich nicht abmelden – nichts Weiteres wurde angefasst.
    public static var helperFailed: SelfUninstallProgress {
        finished([
            .init(subject: .helper, result: .failed("launchd hat die Abmeldung verweigert")),
            .init(subject: .loginItem, result: .skipped(SelfUninstaller.blockedReason)),
            .init(subject: .grant(fullDiskAccess), result: .skipped(SelfUninstaller.blockedReason)),
            .init(subject: .file(app), result: .skipped(SelfUninstaller.blockedReason)),
            .init(subject: .file(data), result: .skipped(SelfUninstaller.blockedReason)),
            .init(subject: .grant(automation), result: .skipped(SelfUninstaller.blockedReason)),
        ], blockedBy: .helper)
    }

    /// Grantry lag schon im Papierkorb, die Abmeldung des Hintergrunddiensts scheiterte – Wiederholung möglich.
    public static var removedButHelperRegistered: SelfUninstallProgress {
        finished([
            .init(subject: .helper, result: .failed("launchd hat die Abmeldung verweigert")),
            .init(subject: .loginItem, result: .skipped(SelfUninstaller.blockedReason)),
            .init(subject: .grant(fullDiskAccess), result: .skipped(SelfUninstaller.blockedReason)),
            .init(subject: .file(app), result: .done),
            .init(subject: .file(data), result: .skipped(SelfUninstaller.blockedReason)),
            .init(subject: .grant(automation), result: .skipped(SelfUninstaller.blockedReason)),
        ], blockedBy: .helper)
    }

    /// Alles erledigt – Grantry liegt im Papierkorb.
    public static var removed: SelfUninstallProgress {
        finished([
            .init(subject: .helper, result: .done), .init(subject: .loginItem, result: .done),
            .init(subject: .grant(fullDiskAccess), result: .done), .init(subject: .file(app), result: .done),
            .init(subject: .file(data), result: .done), .init(subject: .grant(automation), result: .done),
        ], blockedBy: nil)
    }

    private static func finished(
        _ entries: [SelfUninstallReport.Entry], blockedBy: SelfUninstallReport.Subject?
    ) -> SelfUninstallProgress {
        var progress = SelfUninstallProgress(plan: plan)
        progress.complete(with: SelfUninstallReport(entries: entries, finderAccessFailure: nil, blockedBy: blockedBy))
        return progress
    }
}
#endif
