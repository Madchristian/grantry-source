import Foundation
import Testing
@testable import ManagerKit

/// Aus den Listen der Leser (TM-13.1, TM-13.2) werden Inventar-Einträge (TM-13.3): je Systemerweiterung ein Eintrag mit
/// der maßgeblichen Version, je Kernel-Erweiterung einer aus geladener und installierter Fassung, je Plug-in einer.
@Suite struct ExtensionRecordTests {
    private let seenAt = TestData.date

    private func fixture(_ name: String) throws -> SystemExtensionList {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/Extensions")
        )
        return try SystemExtensionListParser.parse(String(contentsOf: url, encoding: .utf8))
    }

    // MARK: Systemerweiterungen

    /// Echte Ausgabe: Microsoft Defender mit vier Versionen, drei warten auf den Neustart. Ein Eintrag mit der aktiven
    /// Version, die übrigen als ältere Versionen (neueste zuerst).
    @Test func severalVersionsBecomeOneRecordWithTheActiveVersion() throws {
        let records = ExtensionRecord.records(from: try fixture("systemextensions-endpoint-security-versions"), seenAt: seenAt)
        #expect(records.count == 2)
        let defender = try #require(records.first { $0.bundleID == "com.microsoft.wdav.epsext" })
        #expect(defender.kind == .endpointSecurity)
        #expect(defender.layer == .systemExtension)
        #expect(defender.state == .enabled)
        #expect(defender.version == "101.26092.0012")
        #expect(defender.buildVersion == "101.26092.0012")
        #expect(defender.otherVersions == ["101.26092.0009", "101.26082.0012", "101.26072.0017"])
        #expect(defender.teamID == "UBF8T346G9")
        #expect(defender.name == "Microsoft Defender Endpoint Security Extension")
        #expect(defender.path == nil)
        #expect(defender.signing == nil)
        #expect(defender.firstSeenAt == seenAt)
        let driver = try #require(records.first { $0.bundleID == "com.corsair.cue.main.VirtualHIDDeviceDriver" })
        #expect(driver.kind == .driver)
        #expect(driver.layer == .driver)
        #expect(driver.otherVersions.isEmpty)
    }

    /// Nur noch alte Versionen: Der Eintrag zeigt „wird beim Neustart entfernt“ mit der neuesten davon.
    @Test func onlyTerminatedVersionsMeanRemovalPending() {
        let list = SystemExtensionList(extensions: [
            Self.systemExtension(version: "1.0", state: .terminatedWaitingToUninstallOnReboot),
            Self.systemExtension(version: "1.10", state: .terminatedWaitingToUninstallOnReboot),
        ], declaredCount: 2, unreadableLineCount: 0)
        let record = ExtensionRecord.records(from: list, seenAt: seenAt)
        #expect(record.map(\.state) == [.removalPending])
        #expect(record.map(\.version) == ["1.10"])
        #expect(record.map(\.otherVersions) == [["1.0"]])
    }

    /// Doppelte Version (dieselbe Version neu aktiviert): Die aktive Zeile gilt, die andere bleibt als ältere Version.
    @Test func duplicateVersionsPreferTheActiveRow() {
        let list = SystemExtensionList(extensions: [
            Self.systemExtension(version: "2.0", state: .terminatedWaitingToUninstallOnReboot),
            Self.systemExtension(version: "2.0", state: .activatedEnabled),
        ], declaredCount: 2, unreadableLineCount: 0)
        let record = ExtensionRecord.records(from: list, seenAt: seenAt)
        #expect(record.map(\.state) == [.enabled])
        #expect(record.map(\.otherVersions) == [["2.0"]])
    }

    @Test func waitingForUserAndUnknownCategoryAreKept() throws {
        let records = ExtensionRecord.records(from: try fixture("systemextensions-waiting-for-user"), seenAt: seenAt)
        #expect(records.contains { $0.state == .waitingForUser })
        let unknown = ExtensionRecord.records(from: SystemExtensionList(extensions: [
            Self.systemExtension(category: .unknown("com.apple.system_extension.future"), state: .unknown("activated later")),
        ], declaredCount: 1, unreadableLineCount: 0), seenAt: seenAt)
        #expect(unknown.map(\.kind) == [.otherSystemExtension("com.apple.system_extension.future")])
        #expect(unknown.map(\.layer) == [.systemExtension])
        #expect(unknown.map(\.state) == [.unknown("activated later")])
    }

    /// Dieselbe Bundle-ID von einem anderen Team ist eine andere Erweiterung (Identität mit Team-ID).
    @Test func identityIncludesTheTeam() {
        let original = Self.systemExtension(teamID: "AAAAAAAAAA")
        let impostor = Self.systemExtension(teamID: "BBBBBBBBBB")
        let records = ExtensionRecord.records(from: SystemExtensionList(
            extensions: [original, impostor], declaredCount: 2, unreadableLineCount: 0
        ), seenAt: seenAt)
        #expect(records.count == 2)
        #expect(Set(records.map(\.id)).count == 2)
    }

    @Test func identityIsStableAcrossVersionsAndStates() {
        let before = ExtensionRecord.records(from: SystemExtensionList(
            extensions: [Self.systemExtension(version: "1.0")], declaredCount: 1, unreadableLineCount: 0
        ), seenAt: seenAt)
        let after = ExtensionRecord.records(from: SystemExtensionList(
            extensions: [Self.systemExtension(version: "2.0", state: .activatedWaitingForUser)], declaredCount: 1,
            unreadableLineCount: 0
        ), seenAt: seenAt)
        #expect(before.map(\.id) == after.map(\.id))
    }

    @Test func eachCategoryHasItsLayer() {
        #expect(ExtensionKind.kernelExtension.layer == .kernel)
        #expect(ExtensionKind.network.layer == .systemExtension)
        #expect(ExtensionKind.endpointSecurity.layer == .systemExtension)
        #expect(ExtensionKind.camera.layer == .systemExtension)
        #expect(ExtensionKind.driver.layer == .driver)
        #expect(ExtensionKind.audioPlugin.layer == .servicePlugin)
        #expect(ExtensionKind.videoPlugin.layer == .servicePlugin)
        #expect(ExtensionLayer.allCases == [.kernel, .systemExtension, .driver, .servicePlugin])
    }

    // MARK: Kernel-Erweiterungen

    /// Geladen und installiert werden über die Bundle-ID zusammengeführt: Version der geladenen, Name und Pfad der
    /// installierten; Signatur aus dem Pfad.
    @Test func kernelExtensionsMergeLoadedAndInstalled() {
        let list = KernelExtensionList(
            loaded: [
                KernelExtension(bundleID: "com.vendor.loaded", version: "2.0", name: nil, path: "/Library/StagedExtensions/Library/Extensions/Vendor.kext"),
                KernelExtension(bundleID: "com.vendor.loadedonly", version: "1.0", name: nil, path: nil),
            ],
            installed: [
                KernelExtension(bundleID: "com.vendor.loaded", version: "2.1", name: "Vendor", path: "/Library/Extensions/Vendor.kext"),
                KernelExtension(bundleID: "com.vendor.idle", version: "3.0", name: "Idle", path: "/Library/Extensions/Idle.kext"),
            ],
            loadedSource: .kextManager
        )
        let signing = SigningInfo(kind: .developerID, teamID: "TEAMKEXT01", isNotarized: true)
        var inspected: [String] = []
        let records = ExtensionRecord.records(from: list, seenAt: seenAt) { path in
            inspected.append(path)
            return .completed(signing)
        }
        #expect(records.map(\.bundleID) == ["com.vendor.idle", "com.vendor.loaded", "com.vendor.loadedonly"])
        let loaded = records[1]
        #expect(loaded.kind == .kernelExtension)
        #expect(loaded.state == .loaded)
        #expect(loaded.version == "2.0")
        #expect(loaded.name == "Vendor")
        #expect(loaded.path == "/Library/Extensions/Vendor.kext")
        #expect(loaded.signing == signing)
        #expect(loaded.teamID == "TEAMKEXT01")
        #expect(loaded.isSigningConclusive)
        #expect(records[0].state == .notLoaded)
        #expect(records[2].state == .loaded)
        #expect(records[2].signing == nil)
        #expect(records[2].teamID == nil)
        #expect(inspected == ["/Library/Extensions/Idle.kext", "/Library/Extensions/Vendor.kext"])
    }

    @Test func timedOutKernelSigningIsInconclusive() {
        let list = KernelExtensionList(
            loaded: [], installed: [KernelExtension(bundleID: "com.vendor.k", version: "1", name: nil, path: "/Library/Extensions/K.kext")],
            loadedSource: .kextManager
        )
        let records = ExtensionRecord.records(from: list, seenAt: seenAt) { _ in .timedOut }
        #expect(records.map(\.signing) == [.unknown])
        #expect(records.map(\.isSigningConclusive) == [false])
    }

    // MARK: Plug-ins

    @Test func pluginBecomesRecordWithSigningAndPath() {
        let signing = SigningInfo(kind: .developerID, teamID: "TEAMPLUG01", isNotarized: true, developerName: "Vendor")
        let plugin = ServicePlugin(
            kind: .video, location: .system, bundleID: "com.vendor.dal", version: "4.2", name: "Vendor Camera",
            path: "/Library/CoreMediaIO/Plug-Ins/DAL/Vendor.plugin", signing: signing, isSigningConclusive: true
        )
        let record = ExtensionRecord(plugin: plugin, seenAt: seenAt)
        #expect(record.kind == .videoPlugin)
        #expect(record.state == .installed)
        #expect(record.teamID == "TEAMPLUG01")
        #expect(record.signing == signing)
        #expect(record.path == plugin.path)
        #expect(record.version == "4.2")
        #expect(record.source == .extensions)
    }

    /// Zwei Plug-ins mit gleicher Bundle-ID in System und Benutzerordner bleiben zwei Einträge.
    @Test func pluginIdentityFollowsThePath() {
        let system = ExtensionRecord(plugin: Self.plugin(path: "/Library/Audio/Plug-Ins/HAL/A.driver"), seenAt: seenAt)
        let user = ExtensionRecord(plugin: Self.plugin(path: "/Users/test/Library/Audio/Plug-Ins/HAL/A.driver"), seenAt: seenAt)
        #expect(system.id != user.id)
    }

    // MARK: Hilfen

    static func systemExtension(
        category: SystemExtensionCategory = .network, teamID: String? = "TEAMSYS001", bundleID: String = "com.vendor.filter",
        version: String = "1.0", state: SystemExtensionState = .activatedEnabled
    ) -> SystemExtension {
        SystemExtension(
            category: category, isEnabled: state == .activatedEnabled, isActive: state == .activatedEnabled, teamID: teamID,
            bundleID: bundleID, version: version, buildVersion: version, name: "Vendor Filter", state: state
        )
    }

    static func plugin(path: String, bundleID: String = "com.vendor.audio") -> ServicePlugin {
        ServicePlugin(
            kind: .audio, location: .system, bundleID: bundleID, version: "1.0", name: "Vendor Audio", path: path,
            signing: SigningInfo(kind: .developerID, teamID: "TEAMPLUG01", isNotarized: true), isSigningConclusive: true
        )
    }
}
