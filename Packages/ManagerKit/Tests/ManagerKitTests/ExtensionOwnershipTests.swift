import Foundation
import Testing
import TestSupport
@testable import ManagerKit

private func app(_ path: String, teamID: String?, symlinkTarget: String? = nil) -> InstalledApp {
    InstalledApp(
        path: path, bundleID: "com.example.\(URL(filePath: path).deletingPathExtension().lastPathComponent)",
        name: URL(filePath: path).lastPathComponent, shortVersion: nil, buildVersion: nil, location: .applications,
        origin: .direct, signing: SigningInfo(kind: .developerID, teamID: teamID, isNotarized: true),
        architecture: .appleSilicon, symlinkTarget: symlinkTarget
    )
}

private func systemExtension(_ bundleID: String, teamID: String?) -> SystemExtension {
    SystemExtension(
        category: .endpointSecurity, isEnabled: true, isActive: true, teamID: teamID, bundleID: bundleID,
        version: "1.0", buildVersion: "1", name: bundleID, state: .activatedEnabled
    )
}

/// Zuordnung über die eingebetteten Bundle-IDs, sonst über die Team-ID (reine Logik ohne Dateisystem).
@Suite struct ExtensionOwnershipTests {
    private static let security = "/Applications/Security.app"
    private static let editor = "/Applications/Editor.app"
    private static let viewer = "/Applications/Viewer.app"

    private func index(unreadable: [UnreadableExtension] = []) -> AppExtensionIndex {
        AppExtensionIndex(
            apps: [app(Self.security, teamID: "SECTEAM001"), app(Self.editor, teamID: "TEAM000001"), app(Self.viewer, teamID: "TEAM000001")],
            embedded: [Self.security: ["com.example.security.esext"], Self.editor: ["com.example.shared.netext"]],
            unreadable: unreadable
        )
    }

    @Test func appFoundByEmbeddedBundleID() {
        #expect(index().owner(of: systemExtension("com.example.security.esext", teamID: "SECTEAM001"))
                == .app(path: Self.security, evidence: .bundleID))
    }

    /// Abnahme 1: Die App fehlt – keine App bringt die Erweiterung mit, keine App hat das Team.
    @Test func appMissing() {
        #expect(index().owner(of: systemExtension("com.vendor.gone.esext", teamID: "GONETEAM01")) == .missing)
    }

    /// Abnahme 1: Zwei Apps desselben Teams, keine bringt die Erweiterung mit – unklar statt geraten.
    @Test func twoAppsOfTheSameTeamAreUnclear() {
        #expect(index().owner(of: systemExtension("com.example.driver", teamID: "TEAM000001"))
                == .unclear(candidates: [Self.editor, Self.viewer]))
    }

    /// Bringt eine der beiden Apps des Teams die Erweiterung mit, entscheidet die Bundle-ID.
    @Test func embeddedBundleIDBeatsTeamAmbiguity() {
        #expect(index().owner(of: systemExtension("com.example.shared.netext", teamID: "TEAM000001"))
                == .app(path: Self.editor, evidence: .bundleID))
    }

    @Test func singleAppOfTheTeam() {
        #expect(index().owner(of: systemExtension("com.example.security.other", teamID: "SECTEAM001"))
                == .app(path: Self.security, evidence: .teamID))
    }

    /// Eine App mit fremdem Team, die dieselbe Bundle-ID einbettet, ist nicht die Besitzerin.
    @Test func embeddedBundleIDWithContradictingTeamDoesNotCount() {
        #expect(index().owner(of: systemExtension("com.example.security.esext", teamID: "OTHERTEAM1")) == .missing)
    }

    /// Mehrere Apps bringen dieselbe Erweiterung mit (etwa zwei Kopien) – unklar.
    @Test func severalEmbeddingAppsAreUnclear() {
        let index = AppExtensionIndex(
            apps: [app(Self.editor, teamID: "TEAM000001"), app(Self.viewer, teamID: "TEAM000001")],
            embedded: [Self.editor: ["com.example.netext"], Self.viewer: ["com.example.netext"]], unreadable: []
        )
        #expect(index.owner(bundleID: "com.example.netext", teamID: "TEAM000001") == .unclear(candidates: [Self.editor, Self.viewer]))
    }

    /// Ohne Team-ID lässt sich das Fehlen nicht belegen.
    @Test func withoutTeamIDNoMatchIsUnclear() {
        #expect(index().owner(of: systemExtension("com.vendor.gone.esext", teamID: nil)) == .unclear(candidates: []))
    }

    /// War der Ordner einer App nicht lesbar, ist „App fehlt“ nicht belegt.
    @Test func incompleteIndexNeverReportsMissing() {
        let index = index(unreadable: [UnreadableExtension(path: "/Applications/Other.app", reason: "nicht lesbar")])
        #expect(!index.isComplete)
        #expect(index.owner(of: systemExtension("com.vendor.gone.esext", teamID: "GONETEAM01")) == .unclear(candidates: []))
    }

    @Test func pluginsAreMatchedByTheirSigningTeam() {
        let plugin = ServicePlugin(
            kind: .audio, location: .system, bundleID: "com.example.security.audio", version: nil, name: nil,
            path: "/Library/Audio/Plug-Ins/HAL/Audio.driver", signing: SigningInfo(kind: .developerID, teamID: "SECTEAM001"),
            isSigningConclusive: true
        )
        #expect(index().owner(of: plugin) == .app(path: Self.security, evidence: .teamID))
    }
}

/// Einlesen von `Contents/Library/SystemExtensions` der Apps im Fake-Dateisystem.
@Suite struct AppExtensionIndexBuilderTests {
    private static let localVolumes: @Sendable () -> [MountedVolume] = { [MountedVolume(path: "/", isLocal: true)] }

    private func makeBundle(_ relativePath: String, in directory: URL, bundleID: String?) throws {
        let contents = directory.appending(path: "\(relativePath)/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        guard let bundleID else { return }
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleID], format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
    }

    @Test func readsEmbeddedSystemExtensions() throws {
        try ScratchDirectory.withCanonical(prefix: "owner-apps") { root in
            let security = root.appending(path: "Security.app")
            try makeBundle("Contents/Library/SystemExtensions/com.example.esext.systemextension", in: security, bundleID: "com.example.esext")
            try makeBundle("Contents/Library/SystemExtensions/Broken.systemextension", in: security, bundleID: nil)
            let plain = root.appending(path: "Plain.app")
            try FileManager.default.createDirectory(at: plain.appending(path: "Contents"), withIntermediateDirectories: true)
            // DriverKit-Treiber in einer Hilfs-App (wie iCUE: iCUE.app/Contents/Applications/iCUE Virtual Device.app).
            let suite = root.appending(path: "Suite.app")
            try makeBundle("Contents/Applications/Helper.app", in: suite, bundleID: "com.example.suite.helper")
            // DriverKit-Bundles sind flach: Info.plist ohne Contents.
            let dext = suite.appending(path: "Contents/Applications/Helper.app/Contents/Library/SystemExtensions/com.example.driver.dext")
            try FileManager.default.createDirectory(at: dext, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.driver"], format: .xml, options: 0)
                .write(to: dext.appending(path: "Info.plist"))

            let index = AppExtensionIndexBuilder(volumes: Self.localVolumes).build(apps: [
                app(security.path, teamID: "SECTEAM001"), app(plain.path, teamID: "SECTEAM001"), app(suite.path, teamID: "SUITETEAM1"),
            ])

            #expect(index.owner(bundleID: "com.example.esext", teamID: "SECTEAM001") == .app(path: security.path, evidence: .bundleID))
            #expect(index.owner(bundleID: "com.example.driver", teamID: "SUITETEAM1") == .app(path: suite.path, evidence: .bundleID))
            #expect(index.unreadable == [UnreadableExtension(
                path: security.appending(path: "Contents/Library/SystemExtensions/Broken.systemextension").path,
                reason: ExtensionBundleScanner.missingPlistText
            )])
        }
    }

    /// Symlinks werden nicht gefolgt: weder eine verlinkte App noch ein verlinkter SystemExtensions-Ordner.
    @Test func symlinksAreNotFollowed() throws {
        try ScratchDirectory.withCanonical(prefix: "owner-apps") { root in
            let real = root.appending(path: "Real.app")
            try makeBundle("Contents/Library/SystemExtensions/com.example.esext.systemextension", in: real, bundleID: "com.example.esext")
            let linkedFolder = root.appending(path: "LinkedFolder.app/Contents/Library")
            try FileManager.default.createDirectory(at: linkedFolder, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: linkedFolder.appending(path: "SystemExtensions").path,
                withDestinationPath: real.appending(path: "Contents/Library/SystemExtensions").path
            )

            let index = AppExtensionIndexBuilder(volumes: Self.localVolumes).build(apps: [
                app(root.appending(path: "Link.app").path, teamID: "TEAM000001", symlinkTarget: real.path),
                app(root.appending(path: "LinkedFolder.app").path, teamID: "TEAM000001"),
            ])

            #expect(index.owner(bundleID: "com.example.esext", teamID: nil) == .unclear(candidates: []))
            #expect(index.unreadable == [UnreadableExtension(
                path: linkedFolder.appending(path: "SystemExtensions").path, reason: ExtensionBundleScanner.symlinkText
            )])
        }
    }

    /// Apps auf einem Netzlaufwerk werden nicht gelesen; die Zuordnung gilt dann als unvollständig.
    @Test func appsOnNetworkVolumesAreSkipped() throws {
        try ScratchDirectory.withCanonical(prefix: "owner-apps") { root in
            let remote = root.appending(path: "Remote.app")
            try makeBundle("Contents/Library/SystemExtensions/com.example.esext.systemextension", in: remote, bundleID: "com.example.esext")
            let volumes: @Sendable () -> [MountedVolume] = { [MountedVolume(path: "/", isLocal: true), MountedVolume(path: root.path, isLocal: false)] }

            let index = AppExtensionIndexBuilder(volumes: volumes).build(apps: [app(remote.path, teamID: "TEAM000001")])

            #expect(index.unreadable == [UnreadableExtension(path: remote.path, reason: ExtensionVolumeCheck.networkVolumeText)])
            #expect(index.owner(bundleID: "com.example.esext", teamID: "TEAM000001") == .app(path: remote.path, evidence: .teamID))
        }
    }
}
