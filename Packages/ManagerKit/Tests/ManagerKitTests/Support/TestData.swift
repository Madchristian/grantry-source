import Foundation
@testable import ManagerKit

enum TestData {
    static let date = Date(timeIntervalSince1970: 1_790_000_000)
    /// Ein Tag in Sekunden (für Datumsrechnungen in Tests).
    static let day: TimeInterval = 86_400
    /// Kalender ohne Zeitumstellung für Tagesgrenzen in Tests.
    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    static func app(
        _ bundleID: String = "us.zoom.xos",
        signing: SigningInfo = SigningInfo(kind: .developerID, teamID: "BJ4HAAB9B3", isNotarized: true),
        presence: Presence = .present
    ) -> AppIdentity {
        AppIdentity(bundleID: bundleID, path: "/Applications/\(bundleID).app", displayName: bundleID, signing: signing, presence: presence)
    }

    static func grant(
        _ service: String = "kTCCServiceCamera",
        client: AppIdentity = app(),
        authValue: AuthValue = .allowed,
        scope: TCCScope = .user
    ) -> PermissionGrant {
        PermissionGrant(service: service, client: client, authValue: authValue, scope: scope, lastModified: date)
    }

    static func item(
        _ label: String = "com.example.agent",
        kind: AutostartKind = .launchAgent,
        domain: AutostartDomain = .user,
        source: SourceID = .launchd,
        isEnabled: Bool = true,
        programPresence: Presence = .present,
        /// `false` bildet eine Quelle nach, die den Programmpfad nicht kennt (`program == nil`).
        hasProgram: Bool = true,
        owner: AppIdentity? = nil
    ) -> AutostartItem {
        AutostartItem(
            kind: kind, domain: domain, label: label,
            program: hasProgram ? "/usr/local/bin/\(label)" : nil,
            programPresence: programPresence, isEnabled: isEnabled, isLoaded: true,
            plistPath: "/Library/LaunchAgents/\(label).plist", owner: owner, source: source
        )
    }

    /// Benutzer-LaunchAgent mit eigenem Plist- und Programmpfad samt Programmsignatur.
    static func userAgent(_ label: String, plistPath: String, program: String, signing: SigningInfo?) -> AutostartItem {
        var agent = item(label)
        agent.plistPath = plistPath
        agent.program = program
        agent.programSigning = signing
        return agent
    }

    /// Klassische Adware-Tarnung: `com.apple.`-Label, Plist in `~/Library/LaunchAgents`, unsigniertes Programm in
    /// einem versteckten Ordner.
    static let disguisedAppleAgent = userAgent(
        "com.apple.update.agent", plistPath: "/Users/test/Library/LaunchAgents/com.apple.update.agent.plist",
        program: "/Users/test/Library/.x/agent", signing: SigningInfo(kind: .unsigned)
    )

    /// Alle Standardquellen; Vorgabe-Baseline, damit Test-Snapshots einen eingeschwungenen Zustand abbilden.
    static let allSources: Set<SourceID> = [.tccUser, .tccSystem, .launchd, .btm]

    static func snapshot(
        grants: [PermissionGrant] = [],
        items: [AutostartItem] = [],
        errors: [SourceError] = [],
        baseline: Set<SourceID> = allSources,
        at date: Date = date
    ) -> Snapshot {
        Snapshot(takenAt: date, grants: grants, autostartItems: items, sourceErrors: errors, baselineSources: baseline)
    }
}
