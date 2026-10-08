import Testing
import Foundation
import Synchronization
@testable import ManagerKit
import TestSupport

private struct FixedLocator: BundleLocating {
    let map: [String: String]
    var fallback = BundleLocation.notRegistered
    func location(ofBundleID bundleID: String) -> BundleLocation { map[bundleID].map { .found(path: $0) } ?? fallback }
}

/// Namensquelle mit festem Ergebnis – zeigt, dass der Resolver keinen eigenen Weg zum Namen hat.
private struct FixedNames: AppNameReading {
    func name(ofBundleAt path: String, info: [String: Any]) -> String { "Fest" }
}

private struct FixedInspector: SigningInspecting {
    func inspect(path: String) -> SigningInfo { SigningInfo(kind: .developerID, teamID: "TEAM") }
}

/// Spotlight-Ersatz mit festem Ergebnis, zählt die Anfragen; `delay` hält jede Anfrage offen.
private final class FixedSpotlight: BundleSpotlightLocating {
    let result: SpotlightLookup
    let delay: Duration
    private let count = Mutex(0)
    var calls: Int { count.withLock { $0 } }

    init(_ result: SpotlightLookup, delay: Duration = .zero) {
        self.result = result
        self.delay = delay
    }

    func lookup(bundleID: String) async -> SpotlightLookup {
        count.withLock { $0 += 1 }
        try? await Task.sleep(for: delay)
        return result
    }
}

/// Zählt die Signaturprüfungen, um den Cache nachzuweisen.
private final class CountingInspector: SigningInspecting {
    private let count = Mutex(0)
    var calls: Int { count.withLock { $0 } }

    func inspect(path: String) -> SigningInfo {
        count.withLock { $0 += 1 }
        return .unknown
    }
}

@Suite struct AppResolverTests {
    let resolver = AppResolver(
        locator: FixedLocator(map: ["com.apple.calculator": "/System/Applications/Calculator.app"]),
        inspector: FixedInspector(),
        spotlight: FixedSpotlight(.unavailable)
    )

    private func resolver(spotlight: FixedSpotlight, clock: ManualClock = ManualClock()) -> AppResolver {
        AppResolver(locator: FixedLocator(map: [:]), inspector: FixedInspector(), spotlight: spotlight,
                    spotlightTTL: 3600, now: { clock.now })
    }

    @Test func resolvesInstalledBundleID() async {
        let app = await resolver.resolve(bundleID: "com.apple.calculator")
        #expect(app.bundleID == "com.apple.calculator")
        #expect(app.path == "/System/Applications/Calculator.app")
        #expect(app.displayName == "Rechner" || app.displayName == "Calculator")
        #expect(app.presence == .present)
        #expect(app.signing.teamID == "TEAM")
    }

    /// Launch Services kennt Systemerweiterungen, eingebettete Helfer und XPC-Dienste nicht – ein fehlender Eintrag
    /// beweist also nicht, dass die App fehlt; ohne Spotlight-Antwort bleibt die Existenz unbekannt.
    @Test func unknownBundleIDWithoutSpotlightAnswerHasUnknownPresence() async {
        let app = await resolver.resolve(bundleID: "com.gone.app")
        #expect(app.bundleID == "com.gone.app")
        #expect(app.path == nil)
        #expect(app.displayName == "com.gone.app")
        #expect(app.presence == .unknown)
        #expect(app.signing == .unknown)
    }

    /// Weder Launch Services noch Spotlight kennen die Bundle-ID: typisch für eine gelöschte App.
    @Test func bundleIDUnknownToSpotlightIsProbablyMissing() async {
        let app = await resolver(spotlight: FixedSpotlight(.notFound)).resolve(bundleID: "ai.openclaw.mac")
        #expect(app.presence == .probablyMissing)
        #expect(app.signing == .unknown)
    }

    /// Spotlight findet ein Bundle (z. B. eine Systemerweiterung), Launch Services aber nicht: Ob es das von TCC
    /// gemeinte ist, bleibt offen.
    @Test func bundleIDFoundOnlyBySpotlightHasUnknownPresence() async {
        let app = await resolver(spotlight: FixedSpotlight(.found)).resolve(bundleID: "com.microsoft.wdav.epsext")
        #expect(app.presence == .unknown)
    }

    /// Launch Services antwortet nicht (Frist abgelaufen): Über die App ist nichts bekannt – auch ohne Spotlight-Treffer
    /// nicht „wahrscheinlich entfernt“.
    @Test func unavailableLaunchServicesGivesUnknownPresence() async {
        let spotlight = FixedSpotlight(.notFound)
        let resolver = AppResolver(locator: FixedLocator(map: [:], fallback: .unavailable), inspector: FixedInspector(),
                                   spotlight: spotlight)
        let app = await resolver.resolve(bundleID: "com.example.app")
        #expect(app.presence == .unknown)
        #expect(spotlight.calls == 0)
    }

    @Test func nameSourceIsInjectable() async throws {
        try await ScratchDirectory.with(prefix: "resolver") { directory in
            let bundle = try AppBundleFixture.make(in: directory, named: "Fixture", bundleID: "de.example.fixture",
                                                   bundleName: "Beispiel")
            let resolver = AppResolver(locator: FixedLocator(map: [:]), inspector: FixedInspector(), names: FixedNames())
            #expect(await resolver.resolve(path: bundle.path).displayName == "Fest")
        }
    }

    @Test func installedBundleIDSkipsSpotlight() async {
        let spotlight = FixedSpotlight(.notFound)
        let resolver = AppResolver(
            locator: FixedLocator(map: ["com.apple.calculator": "/System/Applications/Calculator.app"]),
            inspector: FixedInspector(), spotlight: spotlight
        )
        #expect(await resolver.resolve(bundleID: "com.apple.calculator").presence == .present)
        #expect(spotlight.calls == 0)
    }

    @Test func spotlightLookupIsCachedPerBundleID() async {
        let spotlight = FixedSpotlight(.notFound)
        let resolver = resolver(spotlight: spotlight)
        _ = await resolver.resolve(bundleID: "ai.openclaw.mac")
        _ = await resolver.resolve(bundleID: "ai.openclaw.mac")
        _ = await resolver.resolve(bundleID: "bot.molt.mac")
        #expect(spotlight.calls == 2)
    }

    @Test func spotlightCacheExpiresAfterTTL() async {
        let spotlight = FixedSpotlight(.notFound)
        let clock = ManualClock()
        let resolver = resolver(spotlight: spotlight, clock: clock)
        _ = await resolver.resolve(bundleID: "ai.openclaw.mac")
        clock.advance(by: 3599)
        _ = await resolver.resolve(bundleID: "ai.openclaw.mac")
        clock.advance(by: 2)
        _ = await resolver.resolve(bundleID: "ai.openclaw.mac")
        #expect(spotlight.calls == 2)
    }

    /// Keine Antwort (Fehler, Zeitüberschreitung) wird nur kurz gemerkt, damit ein späterer Scan erneut fragt.
    @Test func unavailableSpotlightAnswerIsRetriedAfterAMinute() async {
        let spotlight = FixedSpotlight(.unavailable)
        let clock = ManualClock()
        let resolver = resolver(spotlight: spotlight, clock: clock)
        _ = await resolver.resolve(bundleID: "ai.openclaw.mac")
        clock.advance(by: 59)
        _ = await resolver.resolve(bundleID: "ai.openclaw.mac")
        #expect(spotlight.calls == 1)
        clock.advance(by: 2)
        _ = await resolver.resolve(bundleID: "ai.openclaw.mac")
        #expect(spotlight.calls == 2)
    }

    @Test func concurrentResolvesShareOneSpotlightLookup() async {
        let spotlight = FixedSpotlight(.notFound, delay: .milliseconds(50))
        let resolver = resolver(spotlight: spotlight)
        let presences = await withTaskGroup(of: Presence.self) { group in
            for _ in 0..<5 {
                group.addTask { await resolver.resolve(bundleID: "ai.openclaw.mac").presence }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(presences == Array(repeating: .probablyMissing, count: 5))
        #expect(spotlight.calls == 1)
    }

    @Test func resolvesPlainExecutablePath() async {
        let app = await resolver.resolve(path: "/bin/ls")
        #expect(app.bundleID == nil)
        #expect(app.displayName == "ls")
        #expect(app.presence == .present)
    }

    @Test func missingPathIsMarkedMissing() async {
        let app = await resolver.resolve(path: "/opt/gone/tool")
        #expect(app.presence == .missing)
        #expect(app.displayName == "tool")
        #expect(app.signing == .unknown)
    }

    @Test func unchangedPathIsInspectedOnlyOnce() async {
        let inspector = CountingInspector()
        let resolver = AppResolver(locator: FixedLocator(map: [:]), inspector: inspector)
        _ = await resolver.resolve(path: "/bin/ls")
        _ = await resolver.resolve(path: "/bin/ls")
        #expect(inspector.calls == 1)
    }

    @Test func bundlePathReadsIdentifierAndNameFromInfoPlist() async throws {
        try await ScratchDirectory.with(prefix: "resolver") { directory in
            let bundle = try AppBundleFixture.make(in: directory, named: "Fixture", bundleID: "de.example.fixture",
                                                   bundleName: "Beispiel")
            let app = await resolver.resolve(path: bundle.path)
            #expect(app.bundleID == "de.example.fixture")
            #expect(app.displayName == "Beispiel")
            #expect(app.path == bundle.path)
            #expect(app.presence == .present)
        }
    }

    @Test func unchangedBundleIsInspectedOnlyOnce() async throws {
        try await withCountingResolver { resolver, inspector, bundle in
            _ = await resolver.resolve(path: bundle.path)
            _ = await resolver.resolve(path: bundle.path)
            #expect(inspector.calls == 1)
        }
    }

    @Test func newerInfoPlistTriggersReinspection() async throws {
        try await withCountingResolver { resolver, inspector, bundle in
            _ = await resolver.resolve(path: bundle.path)
            // In-Place-Update: Nur eine Datei tief im Bundle ändert sich, nicht das Bundle-Verzeichnis selbst.
            try AppBundleFixture.writeInfoPlist(of: bundle, bundleID: "de.example.fixture", bundleName: "Neu")
            try AppBundleFixture.pin(bundle, plistModified: AppBundleFixture.pinnedDate.addingTimeInterval(60))
            let app = await resolver.resolve(path: bundle.path)
            #expect(inspector.calls == 2)
            #expect(app.displayName == "Neu")
        }
    }

    @Test func replacedBundleDirectoryTriggersReinspection() async throws {
        try await withCountingResolver { resolver, inspector, bundle in
            _ = await resolver.resolve(path: bundle.path)
            let staging = bundle.deletingLastPathComponent().appending(path: "staging")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let replacement = try AppBundleFixture.make(in: staging, named: "Fixture", bundleID: "de.example.fixture",
                                                        bundleName: "Beispiel")
            try FileManager.default.removeItem(at: bundle)
            try FileManager.default.moveItem(at: replacement, to: bundle)
            // Gleiche Zeitstempel wie vorher: Nur die Inode verrät den Austausch.
            try AppBundleFixture.pin(bundle)
            _ = await resolver.resolve(path: bundle.path)
            #expect(inspector.calls == 2)
        }
    }

    @Test func danglingSymlinkIsMarkedMissing() async throws {
        try await ScratchDirectory.with(prefix: "resolver") { directory in
            let link = directory.appending(path: "tool")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.appending(path: "gone"))
            let app = await resolver.resolve(path: link.path)
            #expect(app.presence == .missing)
            #expect(app.signing == .unknown)
            #expect(app.path == link.path)
            #expect(app.displayName == "tool")
        }
    }

    @Test func symlinkToExistingFileKeepsRequestedPath() async throws {
        try await ScratchDirectory.with(prefix: "resolver") { directory in
            let link = directory.appending(path: "list")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/bin/ls"))
            let app = await resolver.resolve(path: link.path)
            #expect(app.presence == .present)
            #expect(app.path == link.path)
        }
    }

    /// Wie `/Library/Ossec`: Das Programm existiert, aber das Elternverzeichnis ist nicht lesbar.
    @Test(.disabled(if: geteuid() == 0, "root umgeht Dateirechte")) func pathInsideUnreadableDirectoryHasUnknownPresence() async throws {
        try await LockedDirectoryFixture.with(fileNamed: "wazuh-execd") { file in
            let app = await resolver.resolve(path: file.path)
            #expect(app.presence == .unknown)
            #expect(app.signing == .unknown)
            #expect(app.displayName == "wazuh-execd")
        }
    }

    /// Zeitüberschreitung der Signaturprüfung wird nicht gemerkt (Review M1): Die nächste Auflösung prüft erneut.
    @Test func signingTimeoutIsNotCached() async throws {
        try await ScratchDirectory.with(prefix: "resolver") { directory in
            let bundle = try AppBundleFixture.make(in: directory, named: "Fixture", bundleID: "de.example.fixture",
                                                   bundleName: "Beispiel")
            let inspector = ScriptedSigningInspector([.timedOut, .completed(SigningInfo(kind: .developerID, teamID: "TEAM"))])
            let resolver = AppResolver(locator: FixedLocator(map: [:]), inspector: inspector)
            #expect(await resolver.resolve(path: bundle.path).signing == .unknown)
            #expect(await resolver.resolve(path: bundle.path).signing.teamID == "TEAM")
            #expect(await resolver.resolve(path: bundle.path).signing.teamID == "TEAM")
            #expect(inspector.calls == 2)
        }
    }

    /// Resolver mit zählendem Inspector und einem frischen Fixture-Bundle mit festen Zeitstempeln.
    private func withCountingResolver(
        _ body: (AppResolver, CountingInspector, URL) async throws -> Void
    ) async throws {
        try await ScratchDirectory.with(prefix: "resolver") { directory in
            let bundle = try AppBundleFixture.make(in: directory, named: "Fixture", bundleID: "de.example.fixture",
                                                   bundleName: "Beispiel")
            try AppBundleFixture.pin(bundle)
            let inspector = CountingInspector()
            try await body(AppResolver(locator: FixedLocator(map: [:]), inspector: inspector), inspector, bundle)
        }
    }
}
