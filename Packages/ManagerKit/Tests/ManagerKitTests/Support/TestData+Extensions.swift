import Foundation
@testable import ManagerKit

extension TestData {
    /// Standardquellen plus Apps und Erweiterungen (eingeschwungener Zustand).
    static let extensionSources: Set<SourceID> = allSources.union([.apps, .extensions])

    static func extensionRecord(
        _ bundleID: String = "com.vendor.filter", kind: ExtensionKind = .network, teamID: String? = "TEAMSYS001",
        name: String? = "Vendor Filter", version: String? = "1.0", state: ExtensionState = .enabled,
        signing: SigningInfo? = nil, path: String? = nil, owner: ExtensionOwnership? = nil, firstSeenAt: Date = date
    ) -> ExtensionRecord {
        ExtensionRecord(
            kind: kind, bundleID: bundleID, teamID: teamID, name: name, version: version, buildVersion: version,
            state: state, signing: signing, path: path, owner: owner, firstSeenAt: firstSeenAt
        )
    }

    static func kernelExtensionRecord(
        _ bundleID: String = "com.vendor.kext", version: String? = "1.0", state: ExtensionState = .loaded,
        signing: SigningInfo? = SigningInfo(kind: .developerID, teamID: "TEAMKEXT01", isNotarized: true)
    ) -> ExtensionRecord {
        extensionRecord(bundleID, kind: .kernelExtension, teamID: signing?.teamID, name: "Vendor Kext", version: version,
                        state: state, signing: signing, path: "/Library/Extensions/\(bundleID).kext")
    }

    static func pluginRecord(
        _ path: String = "/Library/Audio/Plug-Ins/HAL/Vendor.driver", kind: ExtensionKind = .audioPlugin,
        version: String? = "1.0", signing: SigningInfo = SigningInfo(kind: .developerID, teamID: "TEAMPLUG01", isNotarized: true)
    ) -> ExtensionRecord {
        extensionRecord("com.vendor.audio", kind: kind, teamID: signing.teamID, name: "Vendor Audio", version: version,
                        state: .installed, signing: signing, path: path)
    }

    static func extensionSnapshot(
        _ records: [ExtensionRecord], apps: [InstalledApp] = [], errors: [SourceError] = [],
        baseline: Set<SourceID> = extensionSources, at date: Date = date
    ) -> Snapshot {
        Snapshot(takenAt: date, grants: [], autostartItems: [], installedApps: apps, extensions: records, sourceErrors: errors,
                 baselineSources: baseline)
    }
}
