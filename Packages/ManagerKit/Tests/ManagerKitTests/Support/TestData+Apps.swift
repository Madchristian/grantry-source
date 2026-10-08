import Foundation
@testable import ManagerKit

extension TestData {
    static let developerSigning = SigningInfo(kind: .developerID, teamID: "TEAMA12345", isNotarized: true)
    /// Standardquellen plus App-Inventar (eingeschwungener Zustand).
    static let appSources: Set<SourceID> = allSources.union([.apps])

    static func installedApp(
        _ name: String = "Zoom", bundleID: String? = "us.zoom.xos", path: String? = nil,
        version: String? = "6.0", build: String? = "600", origin: AppOrigin = .direct,
        signing: SigningInfo = developerSigning, architecture: AppArchitecture = .universal,
        location: AppLocation = .applications
    ) -> InstalledApp {
        InstalledApp(
            path: path ?? "/Applications/\(name).app", bundleID: bundleID, name: name, shortVersion: version,
            buildVersion: build, location: location, origin: origin, signing: signing, architecture: architecture
        )
    }

    static func appSnapshot(
        _ apps: [InstalledApp], grants: [PermissionGrant] = [], items: [AutostartItem] = [],
        errors: [SourceError] = [], baseline: Set<SourceID> = appSources, at date: Date = date
    ) -> Snapshot {
        Snapshot(takenAt: date, grants: grants, autostartItems: items, installedApps: apps, sourceErrors: errors,
                 baselineSources: baseline)
    }
}
