import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

/// Zählt die Namensabfragen und merkt sich die Queue, auf der sie liefen.
private final class CountingNames: AppNameReading {
    private let state = Mutex<(calls: Int, queues: Set<String>)>((0, []))
    var calls: Int { state.withLock { $0.calls } }
    var queues: Set<String> { state.withLock { $0.queues } }

    func name(ofBundleAt path: String, info: [String: Any]) -> String {
        let label = String(cString: __dispatch_queue_get_label(nil))
        state.withLock { $0.calls += 1; $0.queues.insert(label) }
        return "Name"
    }
}

@Suite struct AppInventorySourceTests {
    private let signing = SigningInfo(kind: .developerID, teamID: "TEAMA12345", isNotarized: true)

    private func source(_ root: URL, caskrooms: [String] = []) -> AppInventorySource {
        AppInventorySource(roots: [.init(path: root.path, location: .applications)],
                           inspector: RecordingSigningInspector(result: signing), caskrooms: caskrooms)
    }

    @Test func findsBundlesUpToThreeFoldersDeep() async throws {
        try await ScratchDirectory.with(prefix: "apps") { root in
            let fileManager = FileManager.default
            try AppFixture.make(in: root, named: "Top", bundleID: "com.example.top")
            try AppFixture.make(in: root.appending(path: "Vendor"), named: "One", bundleID: "com.example.one")
            try AppFixture.make(in: root.appending(path: "Canon Utilities/EOS Utility/EU3"), named: "Three", bundleID: "com.example.three")
            try AppFixture.make(in: root.appending(path: "a/b/c/d"), named: "TooDeep", bundleID: "com.example.deep")
            try AppFixture.make(in: root.appending(path: ".hidden"), named: "Hidden", bundleID: "com.example.hidden")
            let host = try AppFixture.make(in: root, named: "Host", bundleID: "com.example.host")
            try AppFixture.make(in: host.appending(path: "Contents/Applications"), named: "Nested", bundleID: "com.example.nested")
            try fileManager.createSymbolicLink(atPath: root.appending(path: "Linked.app").path, withDestinationPath: host.path)
            try fileManager.createSymbolicLink(atPath: root.appending(path: "LinkedFolder").path,
                                               withDestinationPath: root.appending(path: "Vendor").path)

            let apps = try await source(root).collect().installedApps
            #expect(Set(apps.compactMap(\.bundleID)) == ["com.example.top", "com.example.one", "com.example.three", "com.example.host"])
            #expect(apps.filter { $0.symlinkTarget != nil }.map(\.name) == ["Linked"])
        }
    }

    /// Versteckte Bundles (`.Name.app`) werden erfasst (Review M3), versteckte Ordner weiterhin nicht durchsucht – auch
    /// mit kombinierendem Zeichen nach dem Punkt (byteweise wie der `RemovalGuard`, `RawPath.isHidden`).
    @Test func hiddenBundlesAreFoundButHiddenFoldersAreNotSearched() async throws {
        try await ScratchDirectory.with(prefix: "apps") { root in
            try AppFixture.make(in: root, named: ".Sneaky", bundleID: "com.example.sneaky")
            try AppFixture.make(in: root.appending(path: ".hidden"), named: "Inside", bundleID: "com.example.inside")
            try AppFixture.make(in: root.appending(path: ".\u{301}accent"), named: "Accent", bundleID: "com.example.accent")
            let apps = try await source(root).collect().installedApps
            #expect(apps.map(\.bundleID) == ["com.example.sneaky"])
        }
    }

    /// Ein Symlink-Bundle außerhalb der Apple-Pfade erscheint als Eintrag mit Ziel (Review M3) – ohne dem Ziel für
    /// Signatur, Metadaten oder Architektur zu folgen.
    @Test func symlinkedBundleIsListedWithoutFollowingIt() async throws {
        try await ScratchDirectory.with(prefix: "apps") { directory in
            let root = directory.appending(path: "Applications")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let elsewhere = try AppFixture.make(in: directory.appending(path: "Downloads"), named: "Real", bundleID: "com.example.real")
            try FileManager.default.createSymbolicLink(atPath: root.appending(path: "Real.app").path, withDestinationPath: elsewhere.path)
            try FileManager.default.createSymbolicLink(atPath: root.appending(path: "Gone.app").path, withDestinationPath: "../Missing.app")
            let inspector = RecordingSigningInspector(result: signing)
            let source = AppInventorySource(roots: [.init(path: root.path, location: .applications)], inspector: inspector, caskrooms: [])
            let apps = try await source.collect().installedApps
            let canonicalRoot = try #require(AppleComponent.canonicalPath(root.path))

            #expect(apps.map(\.path) == [canonicalRoot + "/Gone.app", canonicalRoot + "/Real.app"])
            let real = try #require(apps.last)
            #expect(real.symlinkTarget == AppleComponent.canonicalPath(elsewhere.path))
            #expect(real.name == "Real")
            #expect(real.bundleID == nil)
            #expect(real.signing == .unknown)
            #expect(real.origin == .unverified)
            #expect(real.architecture == .unknown)
            #expect(apps.first?.symlinkTarget == directory.appending(path: "Missing.app").standardizedFileURL.path
                    || apps.first?.symlinkTarget == AppleComponent.canonicalPath(directory.path).map { $0 + "/Missing.app" })
            #expect(inspector.paths.isEmpty)
        }
    }

    /// Symlinks ins versiegelte System (`/Applications/Safari.app` → Cryptex) bleiben übersprungen. Nur `lstat`/`realpath`
    /// am Systempfad, nichts wird gelesen.
    @Test func symlinkIntoTheSystemIsSkipped() async throws {
        try await ScratchDirectory.with(prefix: "apps") { root in
            try FileManager.default.createSymbolicLink(atPath: root.appending(path: "Rechner.app").path,
                                                       withDestinationPath: "/System/Applications/Calculator.app")
            // Wie `/Applications/Safari.app` (Task 6): Ziel im Cryptex des Preboot-Volumes.
            try FileManager.default.createSymbolicLink(
                atPath: root.appending(path: "Safari.app").path,
                withDestinationPath: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"
            )
            #expect(try await source(root).collect().installedApps.isEmpty)
        }
    }

    @Test func buildsTheRecord() async throws {
        try await ScratchDirectory.with(prefix: "apps") { root in
            let bundle = try AppFixture.make(in: root, named: "Example", bundleID: "com.example.tool", version: "2.1", build: "210")
            let app = try #require(try await source(root).collect().installedApps.first)
            #expect(app.path == AppleComponent.canonicalPath(bundle.path))
            #expect(app.bundleID == "com.example.tool")
            #expect(app.versionText == "2.1 (210)")
            #expect(app.location == .applications)
            #expect(app.origin == .direct)
            #expect(app.signing == signing)
            #expect(app.architecture == .universal)
        }
    }

    @Test func homebrewCaskIsDetected() async throws {
        try await ScratchDirectory.with(prefix: "apps") { directory in
            let root = directory.appending(path: "Applications")
            let bundle = try AppFixture.make(in: root, named: "darktable", bundleID: "org.darktable")
            let version = directory.appending(path: "Caskroom/darktable/5.6.1")
            try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: version.appending(path: "darktable.app").path, withDestinationPath: bundle.path)
            let apps = try await source(root, caskrooms: [directory.appending(path: "Caskroom").path]).collect().installedApps
            #expect(apps.map(\.origin) == [.homebrew(cask: "darktable")])
        }
    }

    @Test func missingRootIsEmpty() async throws {
        try await ScratchDirectory.with(prefix: "apps") { directory in
            let apps = try await source(directory.appending(path: "missing")).collect().installedApps
            #expect(apps.isEmpty)
        }
    }

    /// Ein vorhandener, aber nicht lesbarer Ordner darf nicht als „alle Apps entfernt“ erscheinen (Review M3): Er wird
    /// gemeldet, damit der Scan nur seine Apps fortschreibt – die übrigen Wurzeln liefern normal.
    @Test(.disabled(if: geteuid() == 0, "root umgeht Dateirechte")) func unreadableRootIsReportedNotThrown() async throws {
        try await ScratchDirectory.with(prefix: "apps") { directory in
            let locked = directory.appending(path: "locked")
            let open = directory.appending(path: "open")
            try AppFixture.make(in: locked, named: "Example", bundleID: "com.example.tool")
            try AppFixture.make(in: open, named: "Other", bundleID: "com.example.other")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
            let source = AppInventorySource(
                roots: [.init(path: locked.path, location: .applications), .init(path: open.path, location: .userApplications)],
                inspector: RecordingSigningInspector(result: signing), caskrooms: []
            )
            let contribution = try await source.collect()
            #expect(contribution.installedApps.map(\.bundleID) == ["com.example.other"])
            #expect(contribution.incompleteFolders == [try #require(AppleComponent.canonicalPath(locked.path))])
        }
    }

    @Test(.disabled(if: geteuid() == 0, "root umgeht Dateirechte")) func unreadableSubfolderIsReported() async throws {
        try await ScratchDirectory.with(prefix: "apps") { root in
            let vendor = root.appending(path: "Vendor")
            try AppFixture.make(in: vendor, named: "One", bundleID: "com.example.one")
            try AppFixture.make(in: root, named: "Top", bundleID: "com.example.top")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: vendor.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vendor.path) }
            let contribution = try await source(root).collect()
            #expect(contribution.installedApps.map(\.bundleID) == ["com.example.top"])
            let folder = try #require(AppleComponent.canonicalPath(vendor.path))
            #expect(contribution.incompleteFolders == [folder])
            // Als Einschränkung genannt (#142): Der Bereich „Apps“ gilt dann als teilweise geprüft.
            #expect(contribution.limitations == ["Ordner \(folder) nicht lesbar – Apps darin zeigen den letzten bekannten Stand"])
        }
    }

    @Test func bundleWithoutInfoPlistIsSkipped() async throws {
        try await ScratchDirectory.with(prefix: "apps") { root in
            try FileManager.default.createDirectory(at: root.appending(path: "Broken.app/Contents"), withIntermediateDirectories: true)
            let apps = try await source(root).collect().installedApps
            #expect(apps.isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1))) func fifoAsExecutableDoesNotBlock() async throws {
        try await ScratchDirectory.with(prefix: "apps") { root in
            let bundle = try AppFixture.make(in: root, named: "Trap", bundleID: "com.example.trap", executable: nil)
            _ = try FIFOFixture.make(in: bundle.appending(path: "Contents/MacOS"), named: "Trap")
            let apps = try await source(root).collect().installedApps
            #expect(apps.map(\.architecture) == [.unknown])
        }
    }

    /// Review M5: Metadaten werden je Fingerabdruck gemerkt, gesammelt wird auf der eigenen Queue.
    @Test func metadataIsCachedPerFingerprintAndReadOnTheInventoryQueue() async throws {
        try await ScratchDirectory.with(prefix: "apps") { root in
            let bundle = try AppFixture.make(in: root, named: "Example", bundleID: "com.example.tool")
            try AppBundleFixture.pin(bundle)
            let names = CountingNames()
            let source = AppInventorySource(roots: [.init(path: root.path, location: .applications)],
                                            inspector: RecordingSigningInspector(result: signing), caskrooms: [], names: names)
            _ = try await source.collect()
            _ = try await source.collect()
            #expect(names.calls == 1)
            try AppBundleFixture.pin(bundle, plistModified: AppBundleFixture.pinnedDate.addingTimeInterval(60))
            _ = try await source.collect()
            #expect(names.calls == 2)
            #expect(names.queues == ["de.cstrube.Grantry.app-inventory"])
        }
    }
}
