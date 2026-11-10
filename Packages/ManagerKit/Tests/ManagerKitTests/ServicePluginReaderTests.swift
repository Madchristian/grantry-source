import Foundation
import Testing
import TestSupport
@testable import ManagerKit

/// Bundles im Fake-Dateisystem (kanonischer Scratch-Ordner): Plug-ins, Apps und eingebettete Systemerweiterungen.
private enum FakeBundles {
    static func make(_ relativePath: String, in directory: URL, plist: [String: Any]?) throws {
        let contents = directory.appending(path: "\(relativePath)/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        guard let plist else { return }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
    }

    /// Plug-in-Ordner wie auf dem Mac (`Audio/Plug-Ins/HAL` …) unterhalb von `root`.
    static func directories(in root: URL) -> [ServicePluginDirectory] {
        [
            ServicePluginDirectory(kind: .audio, location: .system, path: root.appending(path: "Library/Audio/Plug-Ins/HAL").path),
            ServicePluginDirectory(kind: .audio, location: .currentUser, path: root.appending(path: "home/Library/Audio/Plug-Ins/HAL").path),
            ServicePluginDirectory(kind: .video, location: .system, path: root.appending(path: "Library/CoreMediaIO/Plug-Ins/DAL").path),
        ]
    }

    /// Alles liegt auf einem lokalen Volume.
    static let localVolumes: @Sendable () -> [MountedVolume] = { [MountedVolume(path: "/", isLocal: true)] }
}

@Suite struct ServicePluginDirectoryTests {
    @Test func standardDirectories() {
        let directories = ServicePluginDirectory.standard(home: "/Users/test")
        #expect(directories == [
            ServicePluginDirectory(kind: .audio, location: .system, path: "/Library/Audio/Plug-Ins/HAL"),
            ServicePluginDirectory(kind: .audio, location: .currentUser, path: "/Users/test/Library/Audio/Plug-Ins/HAL"),
            ServicePluginDirectory(kind: .video, location: .system, path: "/Library/CoreMediaIO/Plug-Ins/DAL"),
        ])
        #expect(!ServicePluginKind.audio.isDeprecated)
        #expect(ServicePluginKind.video.isDeprecated)
    }
}

@Suite struct ServicePluginScannerTests {
    @Test func missingDirectoriesAreEmptyAndComplete() throws {
        try ScratchDirectory.withCanonical(prefix: "plugins") { root in
            let scan = ServicePluginScanner(directories: FakeBundles.directories(in: root), volumes: FakeBundles.localVolumes).scan()
            #expect(scan.bundles.isEmpty)
            #expect(scan.unreadable.isEmpty)
        }
    }

    /// Fehlende Info.plist, Bundle ohne Kennung, Symlink als Bundle und fremde Dateien (`plugins-info.txt` liegt
    /// real im DAL-Ordner) – lesbare Plug-ins bleiben, nicht lesbare stehen mit Grund in `unreadable`.
    @Test func readsBundlesAndReportsUnreadable() throws {
        try ScratchDirectory.withCanonical(prefix: "plugins") { root in
            let hal = root.appending(path: "Library/Audio/Plug-Ins/HAL")
            let dal = root.appending(path: "Library/CoreMediaIO/Plug-Ins/DAL")
            try FakeBundles.make("Mic.driver", in: hal, plist: [
                "CFBundleIdentifier": "com.example.mic", "CFBundleShortVersionString": "1.2", "CFBundleName": "Mic\u{202E}\nFAKE",
            ])
            try FakeBundles.make("NoPlist.driver", in: hal, plist: nil)
            try FakeBundles.make("NoID.driver", in: hal, plist: ["CFBundleVersion": "1"])
            try FileManager.default.createSymbolicLink(
                atPath: hal.appending(path: "Link.driver").path, withDestinationPath: hal.appending(path: "Mic.driver").path
            )
            try FakeBundles.make("Cam.plugin", in: dal, plist: ["CFBundleIdentifier": "com.example.cam", "CFBundleVersion": "7"])
            try Data("info".utf8).write(to: dal.appending(path: "plugins-info.txt"))

            let scan = ServicePluginScanner(directories: FakeBundles.directories(in: root), volumes: FakeBundles.localVolumes).scan()

            #expect(scan.bundles.map(\.directory.kind) == [.audio, .video])
            #expect(scan.bundles.map(\.bundle) == [
                ExtensionBundle(bundleID: "com.example.mic", version: "1.2", name: "Mic FAKE", path: hal.appending(path: "Mic.driver").path),
                ExtensionBundle(bundleID: "com.example.cam", version: "7", name: nil, path: dal.appending(path: "Cam.plugin").path),
            ])
            #expect(scan.unreadable.sorted { $0.path < $1.path } == [
                UnreadableExtension(path: hal.appending(path: "Link.driver").path, reason: ExtensionBundleScanner.symlinkText),
                UnreadableExtension(path: hal.appending(path: "NoID.driver").path, reason: ExtensionBundleScanner.invalidPlistText),
                UnreadableExtension(path: hal.appending(path: "NoPlist.driver").path, reason: ExtensionBundleScanner.missingPlistText),
            ])
        }
    }

    /// Ein Symlink im Pfad des Plug-in-Ordners wird nicht gefolgt – weder als Ordner selbst noch weiter oben.
    @Test func symlinkedDirectoryIsNotFollowed() throws {
        try ScratchDirectory.withCanonical(prefix: "plugins") { root in
            let elsewhere = root.appending(path: "elsewhere/HAL")
            try FakeBundles.make("Mic.driver", in: elsewhere, plist: ["CFBundleIdentifier": "com.example.mic"])
            let audio = root.appending(path: "Library/Audio/Plug-Ins")
            try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: audio.appending(path: "HAL").path, withDestinationPath: elsewhere.path)
            let userLibrary = root.appending(path: "home/Library")
            try FileManager.default.createDirectory(at: root.appending(path: "home"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: userLibrary.path, withDestinationPath: root.appending(path: "Library").path)

            let directories = FakeBundles.directories(in: root)
            let scan = ServicePluginScanner(directories: directories, volumes: FakeBundles.localVolumes).scan()

            #expect(scan.bundles.isEmpty)
            #expect(scan.unreadable == [
                UnreadableExtension(path: directories[0].path, reason: ExtensionBundleScanner.symlinkText),
                UnreadableExtension(path: directories[1].path, reason: ExtensionBundleScanner.symlinkInPathText),
            ])
        }
    }

    /// Plug-in-Ordner auf einem Netzlaufwerk (Netz-Home) werden nicht berührt: ein hängender Server hielte den Scan an.
    @Test func networkVolumeIsNotRead() throws {
        try ScratchDirectory.withCanonical(prefix: "plugins") { root in
            let directories = FakeBundles.directories(in: root)
            try FakeBundles.make("Mic.driver", in: URL(filePath: directories[1].path), plist: ["CFBundleIdentifier": "com.example.mic"])
            let home = root.appending(path: "home").path
            let volumes: @Sendable () -> [MountedVolume] = {
                [MountedVolume(path: "/", isLocal: true), MountedVolume(path: home, isLocal: false)]
            }
            let scan = ServicePluginScanner(directories: directories, volumes: volumes).scan()
            #expect(scan.bundles.isEmpty)
            #expect(scan.unreadable == [UnreadableExtension(path: directories[1].path, reason: ExtensionVolumeCheck.networkVolumeText)])
        }
    }

    @Test func unknownVolumeIsNotRead() throws {
        try ScratchDirectory.withCanonical(prefix: "plugins") { root in
            let directories = Array(FakeBundles.directories(in: root).prefix(1))
            let scan = ServicePluginScanner(directories: directories, volumes: { [] }).scan()
            #expect(scan.unreadable == [UnreadableExtension(path: directories[0].path, reason: ExtensionVolumeCheck.uncheckedVolumeText)])
        }
    }
}

@Suite struct ServicePluginReaderTests {
    private static let developer = SigningInfo(
        kind: .developerID, teamID: "TEAM123456", isNotarized: true, developerName: "Example\u{202E} GmbH\nFAKE"
    )

    @Test func addsSigningKindPlacementAndCleansDeveloperName() async throws {
        try await ScratchDirectory.withCanonical(prefix: "plugins") { root in
            let hal = root.appending(path: "Library/Audio/Plug-Ins/HAL")
            try FakeBundles.make("Mic.driver", in: hal, plist: ["CFBundleIdentifier": "com.example.mic", "CFBundleName": "Mic"])
            let scanner = ServicePluginScanner(directories: FakeBundles.directories(in: root), volumes: FakeBundles.localVolumes)
            let list = try await ServicePluginReader(scanner: scanner, signing: RecordingSigningInspector(result: Self.developer))
                .servicePlugins()

            #expect(list.isComplete)
            #expect(list.plugins == [ServicePlugin(
                kind: .audio, location: .system, bundleID: "com.example.mic", version: nil, name: "Mic",
                path: hal.appending(path: "Mic.driver").path,
                signing: SigningInfo(kind: .developerID, teamID: "TEAM123456", isNotarized: true, developerName: "Example GmbH FAKE"),
                isSigningConclusive: true
            )])
        }
    }

    /// Abnahme 2: Die Signatur wird je Plug-in gepuffert – ein zweiter Scan prüft unveränderte Bundles nicht erneut.
    @Test func secondScanReusesSigningResult() async throws {
        try await ScratchDirectory.withCanonical(prefix: "plugins") { root in
            let hal = root.appending(path: "Library/Audio/Plug-Ins/HAL")
            try FakeBundles.make("Mic.driver", in: hal, plist: ["CFBundleIdentifier": "com.example.mic"])
            try FakeBundles.make("Cam.plugin", in: root.appending(path: "Library/CoreMediaIO/Plug-Ins/DAL"), plist: ["CFBundleIdentifier": "com.example.cam"])
            let recording = RecordingSigningInspector(result: Self.developer)
            let scanner = ServicePluginScanner(directories: FakeBundles.directories(in: root), volumes: FakeBundles.localVolumes)
            let reader = ServicePluginReader(scanner: scanner, signing: CachingSigningInspector(inspector: recording))

            let first = try await reader.servicePlugins()
            let second = try await reader.servicePlugins()

            #expect(first == second)
            #expect(first.plugins.count == 2)
            #expect(recording.paths.count == 2)
        }
    }

    /// Ein in place aktualisiertes Plug-in (neue Info.plist, gleiches Bundle-Verzeichnis) wird neu geprüft.
    @Test func updatedPluginIsInspectedAgain() async throws {
        try await ScratchDirectory.withCanonical(prefix: "plugins") { root in
            let hal = root.appending(path: "Library/Audio/Plug-Ins/HAL")
            try FakeBundles.make("Mic.driver", in: hal, plist: ["CFBundleIdentifier": "com.example.mic", "CFBundleVersion": "1"])
            let recording = RecordingSigningInspector(result: Self.developer)
            let scanner = ServicePluginScanner(directories: FakeBundles.directories(in: root), volumes: FakeBundles.localVolumes)
            let reader = ServicePluginReader(scanner: scanner, signing: CachingSigningInspector(inspector: recording))

            _ = try await reader.servicePlugins()
            let plist = hal.appending(path: "Mic.driver/Contents/Info.plist")
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: plist.path)
            _ = try await reader.servicePlugins()

            #expect(recording.paths.count == 2)
        }
    }

    @Test func timedOutSigningIsMarked() async throws {
        try await ScratchDirectory.withCanonical(prefix: "plugins") { root in
            try FakeBundles.make("Mic.driver", in: root.appending(path: "Library/Audio/Plug-Ins/HAL"), plist: ["CFBundleIdentifier": "com.example.mic"])
            let scanner = ServicePluginScanner(directories: FakeBundles.directories(in: root), volumes: FakeBundles.localVolumes)
            let list = try await ServicePluginReader(scanner: scanner, signing: TimingOutSigning()).servicePlugins()
            let plugin = try #require(list.plugins.first)
            #expect(plugin.signing == .unknown)
            #expect(!plugin.isSigningConclusive)
        }
    }
}

/// Jede Prüfung endet mit einer Zeitüberschreitung.
private struct TimingOutSigning: SigningInspecting {
    func inspect(path: String) -> SigningInfo { .unknown }
    func inspection(ofPath path: String) -> SigningInspection { .timedOut }
}
