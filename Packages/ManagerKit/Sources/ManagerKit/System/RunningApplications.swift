import AppKit

/// Ob eine App läuft (Spec v3 §3 Schritt 1).
public protocol RunningApplicationChecking: Sendable {
    func isRunning(_ app: InstalledApp) async -> Bool
}

/// Über `NSWorkspace.runningApplications`: läuft eine Instanz mit gleicher Bundle-ID **oder** aus demselben Bundle,
/// gilt die App als laufend (vorsichtig – auch eine zweite Kopie sperrt).
public struct WorkspaceRunningApplications: RunningApplicationChecking {
    public init() {}

    public func isRunning(_ app: InstalledApp) async -> Bool {
        await MainActor.run { !Self.instances(of: app).isEmpty }
    }

    /// Bittet alle Instanzen, sich zu beenden („Beenden“ im Entfernen-Blatt); `false`, wenn keine lief oder eine ablehnt.
    @MainActor
    public func terminate(_ app: InstalledApp) -> Bool {
        let instances = Self.instances(of: app)
        return !instances.isEmpty && instances.allSatisfy { $0.terminate() }
    }

    @MainActor
    private static func instances(of app: InstalledApp) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { matches(bundleID: $0.bundleIdentifier, bundleURL: $0.bundleURL, app: app) }
    }

    static func matches(bundleID: String?, bundleURL: URL?, app: InstalledApp) -> Bool {
        if let bundleID, let appID = app.bundleID, bundleID.caseInsensitiveCompare(appID) == .orderedSame { return true }
        guard let bundleURL else { return false }
        return bundleURL.standardizedFileURL.path.lowercased() == app.path.lowercased()
    }
}
