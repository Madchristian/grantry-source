import Foundation

/// Die Team-ID einer App hat sich nach einem Update geändert (**hoch**): Ein anderes Entwicklerteam signiert jetzt –
/// bei einer übernommenen App legitim, bei einer ausgetauschten ein Angriff. Gemeldet `retention` lang ab dem Scan, der
/// den Wechsel erkannte (gemessen an `Snapshot.takenAt`, keine eigene Uhr).
public struct TeamIDChangedRule: RiskRule {
    public static let retention: TimeInterval = 30 * 24 * 3_600

    public init() {}

    public func evaluate(_ snapshot: Snapshot) -> [RiskFinding] {
        snapshot.installedApps.compactMap { app in
            guard let change = app.teamIDChange, let teamID = app.signing.teamID,
                  snapshot.takenAt.timeIntervalSince(change.detectedAt) <= Self.retention else { return nil }
            return RiskFinding(
                rule: .teamIDChanged, severity: .high, recordID: app.id,
                message: "\(app.name): Entwickler-Team gewechselt (\(change.previousTeamID) → \(teamID))"
            )
        }
    }
}

/// App unsigniert (**mittel**) oder nur ad hoc signiert (**mittel**, als Homebrew-Cask oder Chromium-Web-App **niedrig**).
/// `.unknown` ist kein Befund (kein Beleg), eine Safari-Web-App ebenso wenig: Sie bringt kein eigenes Programm mit
/// (`WebAppBrowser.safari`), ihre Signatur schützt also keinen Code.
///
/// Homebrew-Casks signieren oft nur ad hoc (z. B. darktable), daher dort nur ein Hinweis. Die Herkunft „Homebrew“ ist
/// aber nur aus dem für den Nutzer beschreibbaren Caskroom abgeleitet (Symlink bzw. `INSTALL_RECEIPT.json`) und damit
/// ohne Rechte fälschbar: Sie senkt den Befund deshalb nur, statt ihn zu unterdrücken, und eine völlig fehlende Signatur
/// bleibt mittel – arm64-Code braucht mindestens eine Ad-hoc-Signatur, Homebrew legt sie an; unsigniert ist auch für
/// einen Cask untypisch.
///
/// Chromium-Web-Apps (App-Shims) signiert der Browser selbst nur ad hoc. Sie sind aber nur an der Bundle-ID erkannt und
/// bringen eigenen Code mit – wie bei Homebrew sinkt der Befund daher nur.
///
/// Apple-Apps sind bewusst nicht ausgenommen: Echte Apple-Apps sind immer von Apple bzw. dem App Store signiert und
/// erreichen diese Regel nie; eine `com.apple.`-Kennung ohne Signatur lässt sich in jedem `Info.plist` setzen.
public struct UnsignedAppRule: RiskRule {
    public init() {}

    public func evaluate(_ snapshot: Snapshot) -> [RiskFinding] {
        snapshot.installedApps.compactMap { app in
            Self.assessment(of: app).map { severity, statement in
                RiskFinding(rule: .unsignedApp, severity: severity, recordID: app.id, message: "\(app.name) \(statement)")
            }
        }
    }

    /// Schweregrad und Aussage der Meldung, `nil` ohne Befund.
    private static func assessment(of app: InstalledApp) -> (RiskFinding.Severity, String)? {
        if case .webApp(let browser) = app.origin, !browser.bundlesOwnCode { return nil }
        switch app.signing.kind {
        case .unsigned: return (.medium, "ist nicht signiert")
        case .adHoc: return (app.origin.lowersAdHocFinding ? .low : .medium, "ist nur ad hoc signiert")
        default: return nil
        }
    }
}

/// Nur Intel (**niedrig**, Hinweis): läuft über Rosetta 2.
public struct IntelOnlyRule: RiskRule {
    public init() {}

    public func evaluate(_ snapshot: Snapshot) -> [RiskFinding] {
        snapshot.installedApps.filter { $0.architecture == .intel }.map {
            RiskFinding(rule: .intelOnly, severity: .low, recordID: $0.id, message: "\($0.name) läuft nur über Rosetta (Intel)")
        }
    }
}

/// Symbolischer Link als App-Bundle in einem App-Ordner (**niedrig**, Review M3): Grantry folgt ihm für keine Prüfung,
/// Signatur und Herkunft sind daher unbekannt. Links ins versiegelte System (`/Applications/Safari.app`) erfasst das
/// Inventar gar nicht erst.
public struct SymlinkedAppRule: RiskRule {
    public init() {}

    public func evaluate(_ snapshot: Snapshot) -> [RiskFinding] {
        snapshot.installedApps.compactMap { app in
            app.symlinkTarget.map { target in
                let shown = PathDisplay.abbreviatingHome(target)
                let statement = Self.isInsideAppFolders(target)
                    ? "verweist auf \(shown)" : "verweist auf eine App außerhalb der App-Ordner: \(shown)"
                return RiskFinding(rule: .symlinkedApp, severity: .low, recordID: app.id, message: "\(app.name) \(statement)")
            }
        }
    }

    private static func isInsideAppFolders(_ path: String) -> Bool {
        AppInventorySource.standardRoots.contains { root in
            AppleComponent.canonicalPath(root.path).map { path.hasPrefix($0 + "/") } == true
        }
    }
}

extension AppOrigin {
    public var isHomebrew: Bool {
        if case .homebrew = self { true } else { false }
    }

    /// Herkünfte, bei denen eine Ad-hoc-Signatur üblich ist (Homebrew-Cask, Web-App).
    var lowersAdHocFinding: Bool {
        switch self {
        case .homebrew, .webApp: true
        case .appStore, .apple, .direct, .unverified: false
        }
    }
}
