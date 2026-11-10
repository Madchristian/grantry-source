import Foundation
import Testing
@testable import ManagerKit

/// Opt-in gegen das echte System (`MANAGERKIT_LIVE=1`), rein lesend und ohne Root: Systemerweiterungen, Kernel-
/// Erweiterungen und Plug-ins dieses Macs samt Wanduhr je Quelle (TM-13.1, Grenze 300 ms; Median und Maximum über 5 Läufe
/// nach einem Aufwärmlauf) und ihre Zuordnung zu den Apps in `/Applications` (TM-13.2).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MANAGERKIT_LIVE"] == "1"), .serialized)
struct ExtensionsLiveTests {
    private static let budgetMilliseconds = 300.0

    private func milliseconds(_ body: () async throws -> Void) async rethrows -> Double {
        let start = ContinuousClock.now
        try await body()
        let elapsed = (ContinuousClock.now - start).components
        return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
    }

    @Test func readsRealSystemExtensions() async throws {
        let reader = SystemExtensionReader()
        let list = try await reader.systemExtensions()
        #expect(list.isComplete)
        for entry in list.extensions {
            print("sysext \(entry.category) \(entry.bundleID) \(entry.version) \(entry.state) enabled=\(entry.isEnabled) active=\(entry.isActive)")
        }
        let times = try await measure { _ = try await reader.systemExtensions() }
        print("systemextensionsctl count=\(list.extensions.count) wall_ms median=\(times.median) max=\(times.max)")
        #expect(times.max < Self.budgetMilliseconds)
    }

    @Test func readsRealKernelExtensions() async throws {
        let reader = KernelExtensionReader()
        let list = try await reader.kernelExtensions()
        #expect(list.loadedSource == .kextManager)
        #expect(list.isComplete)
        print("kexts loaded=\(list.loaded.map(\.bundleID)) installed=\(list.installed.map(\.bundleID)) unreadable=\(list.unreadable)")
        let times = try await measure { _ = try await reader.kernelExtensions() }
        print("kernel extensions wall_ms median=\(times.median) max=\(times.max)")
        #expect(times.max < Self.budgetMilliseconds)
    }

    /// Rückfall `kmutil showloaded` auf demselben Mac: lesbar und deckungsgleich mit IOKit bei den Drittanbietern.
    @Test func kmutilFallbackMatchesKextManager() async throws {
        let filter = AppleKernelExtensionFilter(signing: SecuritySigningInspector())
        let viaKmutil = try await KmutilLoadedProvider(runner: ProcessCommandRunner()).loadedExtensions()
        let viaIOKit = try await KextManagerLoadedProvider().loadedExtensions()
        #expect(viaKmutil.unreadableLineCount == 0)
        let thirdPartyKmutil = Set(viaKmutil.records.filter { !filter.isApple($0) }.map(\.bundleID))
        let thirdPartyIOKit = Set(viaIOKit.records.filter { !filter.isApple($0) }.map(\.bundleID))
        print("kmutil records=\(viaKmutil.records.count) iokit records=\(viaIOKit.records.count) thirdParty=\(thirdPartyIOKit)")
        #expect(thirdPartyKmutil == thirdPartyIOKit)
        let times = try await measure { _ = try await KmutilLoadedProvider(runner: ProcessCommandRunner()).loadedExtensions() }
        print("kmutil showloaded wall_ms median=\(times.median) max=\(times.max)")
    }

    /// Plug-ins mit Signatur; ab dem zweiten Lauf aus dem Signaturpuffer.
    @Test func readsRealServicePlugins() async throws {
        let reader = ServicePluginReader()
        let list = try await reader.servicePlugins()
        #expect(list.isComplete)
        for plugin in list.plugins {
            print("plugin \(plugin.kind) \(plugin.location) \(plugin.bundleID) \(plugin.version ?? "-") \(plugin.signing.kind) team=\(plugin.signing.teamID ?? "-") notarized=\(plugin.signing.isNotarized)")
        }
        let times = try await measure { _ = try await reader.servicePlugins() }
        print("service plugins count=\(list.plugins.count) unreadable=\(list.unreadable) wall_ms median=\(times.median) max=\(times.max)")
        #expect(times.max < Self.budgetMilliseconds)
    }

    /// Zuordnung der echten Systemerweiterungen und Plug-ins zu den Apps in `/Applications` und eine Ordnerebene darunter
    /// (Signatur je App wie im Inventar).
    @Test func assignsRealExtensionsToApps() async throws {
        let signing = SecuritySigningInspector()
        let fileManager = FileManager.default
        let paths = try fileManager.contentsOfDirectory(atPath: "/Applications").flatMap { name -> [String] in
            let path = "/Applications/\(name)"
            if name.hasSuffix(".app") { return [path] }
            return ((try? fileManager.contentsOfDirectory(atPath: path)) ?? []).filter { $0.hasSuffix(".app") }.map { "\(path)/\($0)" }
        }
        let apps = paths.map { path in
            let name = URL(filePath: path).lastPathComponent
            let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
            return InstalledApp(
                path: path, bundleID: nil, name: name, shortVersion: nil, buildVersion: nil, location: .applications,
                origin: .direct, signing: isLink ? .unknown : signing.inspect(path: path), architecture: .unknown,
                symlinkTarget: isLink ? path : nil
            )
        }
        let systemExtensions = try await SystemExtensionReader().systemExtensions()
        let plugins = try await ServicePluginReader().servicePlugins()
        let index = try await AppExtensionIndex.load(apps: apps)
        print("apps=\(apps.count) index unreadable=\(index.unreadable)")
        for entry in systemExtensions.extensions {
            print("owner sysext \(entry.bundleID) \(entry.state) -> \(index.owner(of: entry))")
        }
        for plugin in plugins.plugins {
            print("owner plugin \(plugin.bundleID) -> \(index.owner(of: plugin))")
        }
        let times = try await measure { _ = try await AppExtensionIndex.load(apps: apps) }
        print("app extension index wall_ms median=\(times.median) max=\(times.max)")
        #expect(times.max < Self.budgetMilliseconds)
    }

    private func measure(_ body: () async throws -> Void) async throws -> (median: Double, max: Double) {
        _ = try await milliseconds(body)
        var times: [Double] = []
        for _ in 0..<5 { times.append(try await milliseconds(body)) }
        times.sort()
        return (times[2], times[4])
    }
}
