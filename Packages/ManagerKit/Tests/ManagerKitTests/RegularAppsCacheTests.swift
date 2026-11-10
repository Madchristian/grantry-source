import AppKit
import Foundation
import Testing
@testable import ManagerKit

/// Laufende Apps je Takt (#481): `activationPolicy` fragt je App Launch Services, das kostete im App-Verlauf und in den
/// Tabellen jeden Takt Hauptthread-Zeit. Gelesen wird erst nach Start, Ende oder Wechsel einer App bzw. nach `maximumAge`.
@MainActor
@Suite struct RegularAppsCacheTests {
    @MainActor private final class Reader {
        var reads = 0
        var apps = [RunningApp(pid: 100, bundleID: "com.example.browser", bundlePath: "/Applications/Browser.app",
                               name: "Browser")]

        func read() -> [RunningApp] {
            reads += 1
            return apps
        }
    }

    @MainActor private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000)
    }

    private func cache(_ reader: Reader, clock: Clock = Clock(),
                       center: NotificationCenter = NotificationCenter()) -> RegularAppsCache {
        RegularAppsCache(read: reader.read, now: { clock.now }, center: center)
    }

    @Test func readsOnceWhileNothingChanges() {
        let reader = Reader(), clock = Clock()
        let cache = cache(reader, clock: clock)
        #expect(cache.apps() == reader.apps)
        clock.now += RegularAppsCache.maximumAge - 1
        #expect(cache.apps() == reader.apps)
        #expect(reader.reads == 1)
    }

    @Test(arguments: [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                      NSWorkspace.didActivateApplicationNotification])
    func readsAgainAfterAnAppChanged(_ name: Notification.Name) {
        let reader = Reader(), center = NotificationCenter()
        let cache = cache(reader, center: center)
        _ = cache.apps()
        reader.apps = []
        center.post(name: name, object: nil)
        #expect(cache.apps() == [])
        #expect(reader.reads == 2)
    }

    /// Eine App kann ihre Aktivierungsart ohne Start oder Ende ändern (Menüleisten-App öffnet ein Fenster).
    @Test func readsAgainAfterMaximumAge() {
        let reader = Reader(), clock = Clock()
        let cache = cache(reader, clock: clock)
        _ = cache.apps()
        clock.now += RegularAppsCache.maximumAge
        _ = cache.apps()
        #expect(reader.reads == 2)
    }
}
