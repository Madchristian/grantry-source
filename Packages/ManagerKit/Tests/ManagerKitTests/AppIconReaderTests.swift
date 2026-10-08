import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

/// Zählt die Lesevorgänge und merkt sich die Queue, auf der sie liefen.
private final class CountingIconReader: AppIconReading {
    private let state = Mutex<(calls: Int, ranOnMainThread: Bool)>((0, false))
    var calls: Int { state.withLock { $0.calls } }
    var ranOnMainThread: Bool { state.withLock { $0.ranOnMainThread } }

    func icon(atPath path: String) -> AppIcon {
        let isMain = Thread.isMainThread
        state.withLock { $0.calls += 1; $0.ranOnMainThread = $0.ranOnMainThread || isMain }
        return .genericApplication
    }
}

/// Hält das Lesen von `blockedPath` an, bis der Test es freigibt; alle anderen Pfade sind sofort generisch.
private final class BlockingIconReader: AppIconReading {
    let blockedPath: String
    let latch = Latch()

    init(blockedPath: String) { self.blockedPath = blockedPath }

    func icon(atPath path: String) -> AppIcon {
        if path == blockedPath { latch.wait() }
        return .genericApplication
    }
}

/// Symbole nur aus Bundle-Dateien in Scratch-Ordnern – kein `NSWorkspace`, kein Launch Services (Review H1).
@Suite struct AppIconReaderTests {
    private let reader = BundleIconReader()
    private let icns = Data("icns".utf8) + Data([0, 0, 0, 8])

    private func bundle(in directory: URL, iconFile: String? = nil, iconName: String? = nil) throws -> URL {
        var extra: [String: Any] = [:]
        extra["CFBundleIconFile"] = iconFile
        extra["CFBundleIconName"] = iconName
        let bundle = try AppFixture.make(in: directory, named: "Example", bundleID: "com.example.tool", extra: extra)
        try FileManager.default.createDirectory(at: resources(of: bundle), withIntermediateDirectories: true)
        return bundle
    }

    private func resources(of bundle: URL) -> URL { bundle.appending(path: "Contents/Resources") }

    @Test(arguments: [("AppIcon", "AppIcon.icns"), ("AppIcon.icns", "AppIcon.icns")])
    func readsTheIconFile(iconFile: String, fileName: String) throws {
        try ScratchDirectory.with(prefix: "icons") { directory in
            let bundle = try bundle(in: directory, iconFile: iconFile)
            try icns.write(to: resources(of: bundle).appending(path: fileName))
            #expect(reader.icon(atPath: bundle.path) == .icns(icns))
        }
    }

    @Test func iconNameWithAnIcnsFileIsRead() throws {
        try ScratchDirectory.with(prefix: "icons") { directory in
            let bundle = try bundle(in: directory, iconName: "AppIcon")
            try icns.write(to: resources(of: bundle).appending(path: "AppIcon.icns"))
            #expect(reader.icon(atPath: bundle.path) == .icns(icns))
        }
    }

    /// Nur Asset-Katalog (`Assets.car`): generisches Symbol, der Katalog wird nicht gelesen.
    @Test func assetCatalogOnlyIsGeneric() throws {
        try ScratchDirectory.with(prefix: "icons") { directory in
            let bundle = try bundle(in: directory, iconName: "AppIcon")
            try Data("BOMStore".utf8).write(to: resources(of: bundle).appending(path: "Assets.car"))
            #expect(reader.icon(atPath: bundle.path) == .genericApplication)
        }
    }

    @Test func foreignOversizedOrEscapingFilesAreGeneric() throws {
        try ScratchDirectory.with(prefix: "icons") { directory in
            let png = try bundle(in: directory.appending(path: "png"), iconFile: "AppIcon")
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: resources(of: png).appending(path: "AppIcon.icns"))
            #expect(reader.icon(atPath: png.path) == .genericApplication)

            let huge = try bundle(in: directory.appending(path: "huge"), iconFile: "AppIcon")
            try (icns + Data(count: BundleIconReader.maximumIconLength)).write(to: resources(of: huge).appending(path: "AppIcon.icns"))
            #expect(reader.icon(atPath: huge.path) == .genericApplication)

            let escaping = try bundle(in: directory.appending(path: "escaping"), iconFile: "../Info")
            #expect(reader.icon(atPath: escaping.path) == .genericApplication)
        }
    }

    @Test func fifoIconDoesNotBlock() async throws {
        try await ScratchDirectory.with(prefix: "icons") { directory in
            let bundle = try bundle(in: directory, iconFile: "AppIcon")
            let fifo = try FIFOFixture.make(in: resources(of: bundle), named: "AppIcon.icns")
            let path = bundle.path
            #expect(await FIFOFixture.completes(unblocking: fifo) { BundleIconReader().icon(atPath: path) } == .genericApplication)
        }
    }

    @Test func fifoInfoPlistDoesNotBlock() async throws {
        try await ScratchDirectory.with(prefix: "icons") { directory in
            let contents = directory.appending(path: "Trap.app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let fifo = try FIFOFixture.make(in: contents, named: "Info.plist")
            let path = directory.appending(path: "Trap.app").path
            #expect(await FIFOFixture.completes(unblocking: fifo) { BundleIconReader().icon(atPath: path) } == .genericApplication)
        }
    }

    /// Eine einzelne Datei – auch eine FIFO als Programm – wird nie geöffnet.
    @Test func filesAreGenericExecutablesWithoutOpening() async throws {
        try await ScratchDirectory.with(prefix: "icons") { directory in
            let tool = directory.appending(path: "tool")
            try Data("#!/bin/sh\n".utf8).write(to: tool)
            #expect(reader.icon(atPath: tool.path) == .genericExecutable)
            let fifo = try FIFOFixture.make(in: directory, named: "trap")
            let path = fifo.path
            #expect(await FIFOFixture.completes(unblocking: fifo) { BundleIconReader().icon(atPath: path) } == .genericExecutable)
            #expect(reader.icon(atPath: directory.appending(path: "gone").path) == .missing)
        }
    }

    @Test func symlinkAndWrapperAreGeneric() throws {
        try ScratchDirectory.with(prefix: "icons") { directory in
            let bundle = try bundle(in: directory.appending(path: "real"), iconFile: "AppIcon")
            try icns.write(to: resources(of: bundle).appending(path: "AppIcon.icns"))
            let link = directory.appending(path: "Link.app")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundle)
            #expect(reader.icon(atPath: link.path) == .genericApplication)

            let (outer, _) = try AppFixture.makeWrapped(in: directory, named: "Tunnel", info: ["CFBundleIdentifier": "de.example.tunnel"])
            #expect(reader.icon(atPath: outer.path) == .genericApplication)
        }
    }

    @Test func loaderCachesPerFingerprintOnItsOwnQueue() async throws {
        try await ScratchDirectory.with(prefix: "icons") { directory in
            let bundle = try AppFixture.make(in: directory, named: "Example", bundleID: "com.example.tool")
            try AppBundleFixture.pin(bundle)
            let counting = CountingIconReader()
            let loader = AppIconLoader(reader: counting)
            let first = await loader.icon(forPath: bundle.path)
            let second = await loader.icon(forPath: bundle.path)
            #expect(first == second)
            #expect(counting.calls == 1)
            try AppBundleFixture.pin(bundle, plistModified: AppBundleFixture.pinnedDate.addingTimeInterval(60))
            let third = await loader.icon(forPath: bundle.path)
            #expect(third.revision != first.revision)
            #expect(counting.calls == 2)
            #expect(!counting.ranOnMainThread)
        }
    }

    @Test func missingPathsAreNotCached() async {
        let counting = CountingIconReader()
        let loader = AppIconLoader(reader: counting)
        _ = await loader.icon(forPath: "/does/not/exist.app")
        _ = await loader.icon(forPath: "/does/not/exist.app")
        #expect(counting.calls == 2)
    }

    /// Review N5: Ein hängendes Symbol hält die serielle Queue höchstens seine Frist auf. Danach gilt es als generisch,
    /// wird nicht gemerkt, und die übrigen Symbole laden weiter.
    @Test(.timeLimit(.minutes(1))) func hangingIconDoesNotBlockTheQueue() async {
        let reader = BlockingIconReader(blockedPath: "/hang.app")
        let loader = AppIconLoader(reader: reader, timeout: .milliseconds(100), callGuard: BlockingCallGuard(maximumHanging: 2))
        let start = ContinuousClock.now
        let hanging = await loader.icon(forPath: "/hang.app")
        #expect(hanging == LoadedAppIcon(icon: .genericApplication, revision: 0))
        #expect(await loader.icon(forPath: "/other.app").icon == .genericApplication)
        #expect(ContinuousClock.now - start < .seconds(5))
        reader.latch.release()
    }

    @Test func iconTimeoutIsBounded() {
        #expect(AppIconLoader.defaultTimeout <= .seconds(10))
    }
}
