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

extension WorkspaceRunningApplications {
    /// Laufende Apps mit Fenster für die Gruppe „Apps“ des Task-Managers; Menüleisten-Helfer und Hintergrund-Apps
    /// zählen wie in Windows 11 zu „Hintergrund“. Aus `RegularAppsCache`, denn Takt und Tabellen fragen je Messung.
    @MainActor
    public static func regularApps() -> [RunningApp] {
        RegularAppsCache.shared.apps()
    }

    /// Fragt je App Launch Services (`activationPolicy`); nur über `RegularAppsCache`.
    @MainActor
    static func readRegularApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, app.processIdentifier > 0 else { return nil }
            let name = app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? ""
            return RunningApp(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                              bundlePath: app.bundleURL?.path, name: name)
        }
    }
}

/// Merkt sich die laufenden Apps mit Fenster (#481): `activationPolicy` fragt je App Launch Services, und der App-Verlauf
/// sowie die Tabellen „Prozesse“ und „Energie“ brauchen die Liste in jedem Messtakt. Neu gelesen wird erst, nachdem eine
/// App startet, endet oder aktiviert wird, spätestens nach `maximumAge` – eine App kann ihre Aktivierungsart auch ohne
/// Start ändern (eine Menüleisten-App öffnet ein Fenster).
@MainActor
final class RegularAppsCache {
    static let shared = RegularAppsCache(read: WorkspaceRunningApplications.readRegularApps)
    static let maximumAge: TimeInterval = 10

    private let read: @MainActor () -> [RunningApp]
    private let now: @MainActor () -> Date
    private var cached: (apps: [RunningApp], date: Date)?
    private var observers: [NSObjectProtocol] = []

    init(read: @escaping @MainActor () -> [RunningApp], now: @escaping @MainActor () -> Date = Date.init,
         center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.read = read
        self.now = now
        observers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cached = nil }
            }
        }
    }

    func apps() -> [RunningApp] {
        let date = now()
        if let cached, date.timeIntervalSince(cached.date) < Self.maximumAge { return cached.apps }
        let apps = read()
        cached = (apps, date)
        return apps
    }
}
