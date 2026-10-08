@testable import ManagerKit

/// Resolver ohne Dateisystemzugriff: alles existiert, signiert als Developer ID.
struct StubAppResolver: AppResolving {
    var missing: Set<String> = []

    func resolve(bundleID: String) async -> AppIdentity {
        AppIdentity(bundleID: bundleID, path: "/Applications/\(bundleID).app", displayName: bundleID,
                    signing: SigningInfo(kind: .developerID, teamID: "TEAM", isNotarized: true),
                    presence: missing.contains(bundleID) ? .missing : .present)
    }

    func resolve(path: String) async -> AppIdentity {
        AppIdentity(bundleID: nil, path: path, displayName: path.split(separator: "/").last.map(String.init) ?? path,
                    signing: SigningInfo(kind: .developerID, teamID: "TEAM", isNotarized: true),
                    presence: missing.contains(path) ? .missing : .present)
    }
}
