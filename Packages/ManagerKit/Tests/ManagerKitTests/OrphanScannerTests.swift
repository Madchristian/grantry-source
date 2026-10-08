import Foundation
import Synchronization
import Testing
@testable import ManagerKit

/// Meldet Bundle-IDs aus `installed` als vorhanden, aus `missing` als vermutlich entfernt, alles andere als `unknown`
/// (Launch Services/Spotlight ohne belastbare Antwort); merkt sich jede Anfrage.
private final class OrphanResolver: AppResolving {
    private let missing: Set<String>
    private let installed: Set<String>
    private let asked = Mutex<[String]>([])

    init(missing: Set<String> = [], installed: Set<String> = []) {
        self.missing = missing
        self.installed = installed
    }

    var queries: [String] { asked.withLock { $0 } }

    func resolve(bundleID: String) async -> AppIdentity {
        asked.withLock { $0.append(bundleID) }
        let presence: Presence = installed.contains(bundleID) ? .present : missing.contains(bundleID) ? .probablyMissing : .unknown
        return AppIdentity(bundleID: bundleID, path: nil, displayName: bundleID, signing: .unknown, presence: presence)
    }

    func resolve(path: String) async -> AppIdentity {
        Issue.record("Pfade dürfen nie an Systemdienste gehen: \(path)")
        return AppIdentity(bundleID: nil, path: path, displayName: path, signing: .unknown, presence: .unknown)
    }
}

private struct FixedSizer: FileSizeMeasuring {
    func allocatedSize(of path: String) -> Int64? { 42 }
}

@Suite struct OrphanScannerTests {
    private func scan(
        _ fixture: LibraryFixture, _ snapshot: Snapshot = TestData.appSnapshot([]), resolver: OrphanResolver
    ) async -> OrphanScanResult {
        await OrphanScanner(layout: fixture.layout, resolver: resolver, sizes: FixedSizer()).scan(snapshot)
    }

    private func scan(
        _ fixture: LibraryFixture, _ snapshot: Snapshot = TestData.appSnapshot([]), missing: Set<String>,
        installed: Set<String> = []
    ) async -> OrphanScanResult {
        await scan(fixture, snapshot, resolver: OrphanResolver(missing: missing, installed: installed))
    }

    private static func signed(_ team: String?) -> SigningInfo {
        SigningInfo(kind: .developerID, teamID: team, isNotarized: true)
    }

    // MARK: Gruppen

    @Test func groupsLeftoversOfARemovedAppUnderTheShortestIdentifier() async throws {
        try await LibraryFixture.with { fixture in
            let paths = [
                try fixture.folder(fixture.userLibrary("Caches/ai.openclaw.mac")),
                try fixture.folder(fixture.userLibrary("Caches/ai.openclaw.mac.debug")),
                try fixture.file(fixture.userLibrary("Preferences/ai.openclaw.mac.plist")),
                try fixture.folder(fixture.userLibrary("HTTPStorages/ai.openclaw.mac")),
            ]
            let resolver = OrphanResolver(missing: ["ai.openclaw.mac", "ai.openclaw.mac.debug"])
            let result = await scan(fixture, resolver: resolver)
            #expect(result.coverage == .complete)
            #expect(result.groups.map(\.identifier) == ["ai.openclaw.mac"])
            let candidates = result.groups[0].candidates
            #expect(Set(candidates.map(\.path)) == Set(paths))
            #expect(candidates.allSatisfy { $0.confidence == .safe && $0.note == nil })
            #expect(candidates.allSatisfy { $0.size == .bytes(42) && $0.identity != nil })
            // Je Kennung höchstens eine Anfrage.
            #expect(resolver.queries.sorted() == ["ai.openclaw.mac", "ai.openclaw.mac.debug"])
        }
    }

    /// Review I1: Das Ergebnis kennt den Stand der installierten Apps und je Fund die Kennungen, die vor dem Papierkorb
    /// erneut geprüft werden.
    @Test func resultRemembersInstalledAppsAndClaims() async throws {
        try await LibraryFixture.with { fixture in
            let cache = try fixture.folder(fixture.userLibrary("Caches/ai.openclaw.mac.debug"))
            let prefs = try fixture.file(fixture.userLibrary("Preferences/ai.openclaw.mac.plist"))
            let team = try fixture.folder(fixture.userLibrary("Group Containers/TEAMB12345.ai.openclaw.mac.shared"))
            let vendor = try fixture.folder(fixture.userLibrary("Application Support/OpenClaw"))
            let zoom = TestData.installedApp()
            let snapshot = TestData.appSnapshot([zoom])
            let result = await scan(fixture, snapshot, missing: ["ai.openclaw.mac", "ai.openclaw.mac.debug", "ai.openclaw.mac.shared"])
            #expect(result.groups.map(\.identifier) == ["ai.openclaw.mac"])
            #expect(result.claims == [
                prefs: OrphanClaim(identifiers: ["ai.openclaw.mac"]),
                cache: OrphanClaim(identifiers: ["ai.openclaw.mac", "ai.openclaw.mac.debug"]),
                team: OrphanClaim(identifiers: ["ai.openclaw.mac", "ai.openclaw.mac.shared"], team: "TEAMB12345"),
                vendor: OrphanClaim(identifiers: ["OpenClaw", "ai.openclaw.mac"],
                                    vendorFolder: OrphanClaim.VendorFolder(name: "OpenClaw", groupIdentifier: "ai.openclaw.mac")),
            ])
            #expect(!result.isOutdated(comparedTo: snapshot))
            #expect(!result.isOutdated(comparedTo: TestData.appSnapshot([zoom], at: TestData.date.addingTimeInterval(60))))
            #expect(result.isOutdated(comparedTo: TestData.appSnapshot([zoom, TestData.installedApp("OpenClaw", bundleID: "ai.openclaw.mac")])))
            #expect(result.isOutdated(comparedTo: TestData.appSnapshot([])))
        }
    }

    @Test func candidatesPassTheRemovalGuardWithoutAppleRelease() async throws {
        try await LibraryFixture.with { fixture in
            try fixture.folder(fixture.userLibrary("Containers/ai.openclaw.mac"))
            try fixture.folder(fixture.userLibrary("Group Containers/group.ai.openclaw.mac"))
            let result = await scan(fixture, missing: ["ai.openclaw.mac"])
            let leftovers = result.leftovers
            #expect(leftovers.candidates.count == 2)
            let removalGuard = RemovalGuard(layout: fixture.layout)
            #expect(leftovers.candidates.allSatisfy { removalGuard.check($0, allowingAppleIDOf: nil) == .allowed })
            #expect(Set(leftovers.candidates.map(\.kind)) == [.container, .groupContainer])
        }
    }

    @Test func vendorFolderIsAnUncertainAddition() async throws {
        try await LibraryFixture.with { fixture in
            try fixture.folder(fixture.userLibrary("Caches/ai.openclaw.mac"))
            let vendor = try fixture.folder(fixture.userLibrary("Application Support/OpenClaw"))
            try fixture.folder(fixture.userLibrary("Application Support/moltbot"))
            let result = await scan(fixture, missing: ["ai.openclaw.mac"])
            let group = try #require(result.groups.first)
            #expect(group.candidates.count == 2)
            let folder = try #require(group.candidates.first { $0.path == vendor })
            #expect(folder.confidence == .uncertain && folder.note == "Ordner nach Herstellername")
        }
    }

    @Test func vendorFolderNamedLikeAnInstalledAppIsSkipped() async throws {
        try await LibraryFixture.with { fixture in
            try fixture.folder(fixture.userLibrary("Caches/ai.openclaw.mac"))
            try fixture.folder(fixture.userLibrary("Application Support/OpenClaw"))
            let other = TestData.installedApp("OpenClaw", bundleID: "com.other.claw")
            let group = try #require(await scan(fixture, TestData.appSnapshot([other]), missing: ["ai.openclaw.mac"]).groups.first)
            #expect(group.candidates.map(\.kind) == [.caches])
            // Name gleich einer installierten App – nur unsicher.
            #expect(group.candidates[0].confidence == .uncertain)
        }
    }

    // MARK: Nie

    @Test func appleIdentifiersNeverAppearAndAreNeverQueried() async throws {
        try await LibraryFixture.with { fixture in
            try fixture.folder(fixture.userLibrary("Caches/com.apple.Safari"))
            try fixture.folder(fixture.userLibrary("Caches/COM.APPLE.Safari.x"))
            try fixture.folder(fixture.userLibrary("Group Containers/group.com.apple.notes"))
            try fixture.folder(fixture.userLibrary("Group Containers/74J34U3R6X.com.apple.iWork"))
            try fixture.folder(fixture.userLibrary("Group Containers/group.is.workflow.my.app"))
            try fixture.folder(fixture.userLibrary("Containers/developer.apple.wwdc-Release"))
            try fixture.folder(fixture.userLibrary("Caches/org.swift.swiftpm"))
            try fixture.file(fixture.system("Library/Preferences/org.cups.printers.plist"))
            try fixture.file(fixture.system("Library/Preferences/edu.mit.Kerberos.plist"))
            let resolver = OrphanResolver(missing: [
                "com.apple.Safari", "COM.APPLE.Safari.x", "com.apple.notes", "com.apple.iWork", "is.workflow.my.app",
                "developer.apple.wwdc-Release", "org.swift.swiftpm", "org.cups.printers", "edu.mit.Kerberos",
            ])
            #expect(await scan(fixture, resolver: resolver).groups.isEmpty)
            #expect(resolver.queries.isEmpty)
        }
    }

    @Test func entriesOfInstalledOrKnownAppsNeverAppear() async throws {
        try await LibraryFixture.with { fixture in
            try fixture.folder(fixture.userLibrary("Caches/com.hnc.Discord.ShipIt"))
            try fixture.folder(fixture.userLibrary("Caches/com.microsoft.autoupdate2"))
            let discord = TestData.installedApp("Discord", bundleID: "com.hnc.Discord")
            let result = await scan(fixture, TestData.appSnapshot([discord]), missing: [], installed: ["com.microsoft.autoupdate2"])
            #expect(result.groups.isEmpty)
        }
    }

    @Test func bundlesOnDiskOwnTheirEntriesEvenIfTheSnapshotLacksThem() async throws {
        try await LibraryFixture.with { fixture in
            // Versteckt, in einem Unterordner und als zweite Kopie – keiner davon steht im Snapshot.
            try fixture.app(".Hidden", bundleID: "com.example.hidden")
            try fixture.app("Tool", bundleID: "com.example.tool", subfolder: "Vendor/Tools")
            try fixture.app("Copy", bundleID: "com.example.copy", subfolder: "Old")
            try fixture.folder(fixture.userLibrary("Caches/com.example.hidden.cache"))
            try fixture.folder(fixture.userLibrary("Caches/com.example.tool"))
            try fixture.file(fixture.userLibrary("Preferences/com.example.copy.plist"))
            let copy = TestData.installedApp("Copy", bundleID: "com.example.copy", path: "/elsewhere/Copy.app")
            let result = await scan(fixture, TestData.appSnapshot([copy]),
                                    missing: ["com.example.hidden.cache", "com.example.tool", "com.example.copy"])
            #expect(result.groups.isEmpty)
        }
    }

    @Test func symlinkedBundlesOwnTheirEntriesThroughTheirTarget() async throws {
        try await LibraryFixture.with { fixture in
            let target = try AppFixture.make(in: URL(fileURLWithPath: fixture.home + "/Elsewhere"), named: "Linked",
                                              bundleID: "com.example.linked")
            try FileManager.default.createSymbolicLink(atPath: fixture.system("Applications/Linked.app"),
                                                       withDestinationPath: target.path)
            try fixture.folder(fixture.userLibrary("Caches/com.example.linked"))
            let result = await scan(fixture, missing: ["com.example.linked"])
            #expect(result.coverage == .complete)
            #expect(result.groups.isEmpty)
        }
    }

    @Test func namespaceOfAnInstalledAppIsNeverAnOrphan() async throws {
        try await LibraryFixture.with { fixture in
            try fixture.folder(fixture.userLibrary("Caches/io.github.wickenico"))
            let wailbrew = TestData.installedApp("WailBrew", bundleID: "io.github.wickenico.wailbrew")
            #expect(await scan(fixture, TestData.appSnapshot([wailbrew]), missing: ["io.github.wickenico"]).groups.isEmpty)
        }
    }

    @Test func namesThatAreNoBundleIDsAreIgnored() async throws {
        try await LibraryFixture.with { fixture in
            try fixture.folder(fixture.userLibrary("Caches/Steam"))
            try fixture.folder(fixture.userLibrary("Caches/com.twoparts"))
            try fixture.folder(fixture.userLibrary("Caches/Com.Upper.case"))
            try fixture.folder(fixture.userLibrary("Caches/com..empty"))
            try fixture.folder(fixture.userLibrary("Caches/com.ümlaut.app"))
            try fixture.file(fixture.userLibrary("Preferences/.GlobalPreferences.plist"))
            let resolver = OrphanResolver(missing: ["Steam", "com.twoparts", "Com.Upper.case", "com..empty", "com.ümlaut.app"])
            #expect(await scan(fixture, resolver: resolver).groups.isEmpty)
            #expect(resolver.queries.isEmpty)
        }
    }

    @Test func groupsThatServicesStillKnowOrCannotAnswerAreSkipped() async throws {
        try await LibraryFixture.with { fixture in
            try fixture.folder(fixture.userLibrary("Caches/com.example.registered"))
            try fixture.folder(fixture.userLibrary("Caches/com.example.unanswered"))
            let result = await scan(fixture, missing: [], installed: ["com.example.registered"])
            #expect(result.groups.isEmpty)
        }
    }

    @Test func entriesWhoseOwnIdentifierIsStillKnownAreDroppedAndTheGroupBecomesUncertain() async throws {
        try await LibraryFixture.with { fixture in
            let gone = try fixture.folder(fixture.userLibrary("Caches/ai.openclaw.mac"))
            try fixture.folder(fixture.userLibrary("Caches/ai.openclaw.mac.helper"))
            let resolver = OrphanResolver(missing: ["ai.openclaw.mac"], installed: ["ai.openclaw.mac.helper"])
            let group = try #require(await scan(fixture, resolver: resolver).groups.first)
            #expect(group.candidates.map(\.path) == [gone])
            #expect(group.candidates[0].confidence == .uncertain)
            #expect(group.candidates[0].note == "Verwandte Kennung nicht als entfernt bestätigt: ai.openclaw.mac.helper")
        }
    }

    @Test func installedVendorMakesTheGroupUncertain() async throws {
        try await LibraryFixture.with { fixture in
            try fixture.file(fixture.userLibrary("Preferences/com.google.Keystone.Agent.plist"))
            let chrome = TestData.installedApp("Google Chrome", bundleID: "com.google.Chrome")
            let group = try #require(await scan(fixture, TestData.appSnapshot([chrome]), missing: ["com.google.Keystone.Agent"]).groups.first)
            #expect(group.candidates.allSatisfy { $0.confidence == .uncertain })
            #expect(group.candidates.first?.note == "Hersteller hat installierte Apps: Google Chrome")
        }
    }

    @Test func identifierNamingAnInstalledAppIsUncertain() async throws {
        try await LibraryFixture.with { fixture in
            try fixture.file(fixture.userLibrary("Logs/warp.log.old.0"))
            let warp = TestData.installedApp("Warp", bundleID: "dev.warp.Warp-Stable")
            let group = try #require(await scan(fixture, TestData.appSnapshot([warp]), missing: ["warp.log.old.0"]).groups.first)
            #expect(group.candidates.first?.confidence == .uncertain)
            #expect(group.candidates.first?.note == "Name ähnelt installierter App: Warp")
        }
    }

    @Test func renamedIdentifierOfAnInstalledAppIsUncertain() async throws {
        try await LibraryFixture.with { fixture in
            try fixture.folder(fixture.userLibrary("Containers/de.strube.ACCpromAdapter"))
            let adapter = TestData.installedApp("Apple Content Cache Prometheus Adapter", bundleID: "de.cstrube.ACCpromAdapter",
                                                path: "/Applications/ACCpromAdapter.app")
            let group = try #require(await scan(fixture, TestData.appSnapshot([adapter]), missing: ["de.strube.ACCpromAdapter"]).groups.first)
            #expect(group.candidates.first?.confidence == .uncertain)
            #expect(group.candidates.first?.note
                    == "Name ähnelt installierter App: Apple Content Cache Prometheus Adapter; " + OrphanScanner.appDataNote)
        }
    }

    @Test func identifiersOfEmbeddedLibrariesAreUncertain() async throws {
        try await LibraryFixture.with { fixture in
            try fixture.file(fixture.userLibrary("Preferences/org.sparkle-project.Sparkle.Autoupdate.plist"))
            try fixture.folder(fixture.userLibrary("Application Support/Sparkle-Project"))
            let group = try #require(await scan(fixture, missing: ["org.sparkle-project.Sparkle.Autoupdate"]).groups.first)
            #expect(group.candidates.count == 1)
            #expect(group.candidates[0].confidence == .uncertain)
            #expect(group.candidates[0].note == "Kennung einer Bibliothek – gehört evtl. zu einer installierten App")
        }
    }

    @Test func teamContainerOfAnInstalledTeamIsSkipped() async throws {
        try await LibraryFixture.with { fixture in
            try fixture.folder(fixture.userLibrary("Group Containers/TEAMA12345.com.example.gone"))
            try fixture.folder(fixture.userLibrary("Group Containers/TEAMA12345.group.com.example.gone"))
            let installed = TestData.installedApp()  // Team TEAMA12345
            #expect(await scan(fixture, TestData.appSnapshot([installed]), missing: ["com.example.gone"]).groups.isEmpty)
        }
    }

    @Test func teamContainerIsUncertainWhileATeamIsUnknown() async throws {
        try await LibraryFixture.with { fixture in
            try fixture.folder(fixture.userLibrary("Group Containers/TEAMB12345.com.example.gone"))
            try fixture.folder(fixture.userLibrary("Caches/com.example.gone"))
            let unchecked = TestData.installedApp("Unchecked", bundleID: "org.other.app", signing: .unknown)
            let group = try #require(await scan(fixture, TestData.appSnapshot([unchecked]), missing: ["com.example.gone"]).groups.first)
            let team = try #require(group.candidates.first { $0.kind == .groupContainer })
            #expect(team.confidence == .uncertain
                    && team.note == "Team-ID nicht bei allen Apps prüfbar; " + OrphanScanner.appDataNote)
            #expect(group.candidates.first { $0.kind == .caches }?.confidence == .safe)
        }
    }

    @Test func symlinksNeverAppearAndAreNeverQueried() async throws {
        try await LibraryFixture.with { fixture in
            try FileManager.default.createSymbolicLink(atPath: fixture.userLibrary("Caches/ai.openclaw.mac"),
                                                       withDestinationPath: fixture.home + "/Documents")
            let resolver = OrphanResolver(missing: ["ai.openclaw.mac"])
            #expect(await scan(fixture, resolver: resolver).groups.isEmpty)
            #expect(resolver.queries.isEmpty)
        }
    }

    // MARK: Komponenten ohne App (Review M1)

    @Test func autostartItemsWithPresentProgramOwnTheirLabelAndOwner() async throws {
        try await LibraryFixture.with { fixture in
            try fixture.folder(fixture.userLibrary("Caches/com.vendor.mdm.agent"))
            try fixture.file(fixture.userLibrary("Preferences/com.vendor.mdm.agent.plist"))
            try fixture.folder(fixture.userLibrary("Application Support/com.vendor.mdmclient"))
            try fixture.folder(fixture.userLibrary("Caches/ai.openclaw.gateway"))
            let owner = AppIdentity(bundleID: "com.vendor.mdmclient", path: nil, displayName: "MDM", signing: .unknown,
                                    presence: .unknown)
            let daemon = TestData.item("com.vendor.mdm.agent", kind: .launchDaemon, domain: .system, owner: owner)
            let gone = TestData.item("ai.openclaw.gateway", programPresence: .missing)
            let snapshot = TestData.appSnapshot([], items: [daemon, gone])
            let result = await scan(fixture, snapshot,
                                    missing: ["com.vendor.mdm.agent", "com.vendor.mdmclient", "ai.openclaw.gateway"])
            // Nur der Eintrag, dessen Programm fehlt, bleibt ein Rest.
            #expect(result.groups.map(\.identifier) == ["ai.openclaw.gateway"])
        }
    }

    @Test func componentBundlesWithoutAppOwnTheirEntries() async throws {
        try await LibraryFixture.with { fixture in
            try fixture.component("Pane.prefPane", bundleID: "com.example.pane", in: fixture.system("Library/PreferencePanes"))
            try fixture.component("Saver.saver", bundleID: "com.example.saver", in: fixture.system("Library/Screen Savers"))
            try fixture.component("Mic.driver", bundleID: "com.example.mic", in: fixture.system("Library/Audio/Plug-Ins/HAL"))
            try fixture.component("Synth.component", bundleID: "com.example.synth",
                                  in: fixture.userLibrary("Audio/Plug-Ins/Components"))
            try fixture.component("Net.kext", bundleID: "com.example.kext", in: fixture.system("Library/Extensions"))
            try fixture.component("Own.prefPane", bundleID: "com.example.ownpane", in: fixture.userLibrary("PreferencePanes"))
            try fixture.component("Own.saver", bundleID: "com.example.ownsaver", in: fixture.userLibrary("Screen Savers"))
            try fixture.file(fixture.system("Library/PrivilegedHelperTools/com.example.helper"))
            let identifiers = ["com.example.pane", "com.example.saver", "com.example.mic", "com.example.synth",
                               "com.example.kext", "com.example.ownpane", "com.example.ownsaver", "com.example.helper"]
            for identifier in identifiers {
                try fixture.folder(fixture.userLibrary("Caches/\(identifier)"))
            }
            let result = await scan(fixture, missing: Set(identifiers))
            #expect(result.coverage == .complete)
            #expect(result.groups.isEmpty)
        }
    }

    @Test func installedComponentOfTheVendorMakesTheGroupUncertain() async throws {
        try await LibraryFixture.with { fixture in
            try fixture.component("Pane.prefPane", bundleID: "com.example.pane", in: fixture.system("Library/PreferencePanes"))
            try fixture.folder(fixture.userLibrary("Caches/com.example.gone"))
            try fixture.folder(fixture.userLibrary("Application Support/Example"))
            let group = try #require(await scan(fixture, missing: ["com.example.gone"]).groups.first)
            #expect(group.candidates.map(\.kind) == [.caches], "kein Herstellerordner")
            #expect(group.candidates[0].confidence == .uncertain)
            #expect(group.candidates[0].note == "Hersteller hat installierte Komponenten: Pane.prefPane")
        }
    }

    @Test func componentInfoPlistAsFIFODoesNotBlock() async throws {
        try await LibraryFixture.with { fixture in
            let contents = URL(fileURLWithPath: fixture.system("Library/PreferencePanes/Pipe.prefPane/Contents"))
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let fifo = try FIFOFixture.make(in: contents, named: "Info.plist")
            let snapshot = TestData.appSnapshot([]), layout = fixture.layout
            let coverage = await FIFOFixture.completes(unblocking: fifo) { OrphanInventory(snapshot: snapshot, layout: layout).coverage }
            #expect(coverage == .complete)
        }
    }

    @Test func unreadableComponentFolderMakesEverythingUncertain() async throws {
        try await LibraryFixture.with { fixture in
            try fixture.folder(fixture.userLibrary("Caches/ai.openclaw.mac"))
            let helpers = fixture.system("Library/PrivilegedHelperTools")
            try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: helpers)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helpers) }
            let result = await scan(fixture, missing: ["ai.openclaw.mac"])
            #expect(result.coverage == .incomplete("App-Inventar unvollständig: 1 Komponenten-Ordner nicht lesbar"))
            #expect(result.groups.first?.candidates.first?.confidence == .uncertain)
        }
    }

    @Test func systemWideEntriesAreNeverPreselected() async throws {
        try await LibraryFixture.with { fixture in
            let user = try fixture.folder(fixture.userLibrary("Caches/ai.openclaw.mac"))
            let system = try fixture.folder(fixture.system("Library/Caches/ai.openclaw.mac"))
            let prefs = try fixture.file(fixture.system("Library/Preferences/ai.openclaw.mac.plist"))
            let support = try fixture.folder(fixture.system("Library/Application Support/ai.openclaw.mac"))
            let group = try #require(await scan(fixture, missing: ["ai.openclaw.mac"]).groups.first)
            #expect(group.candidates.first { $0.path == user }?.confidence == .safe)
            for path in [system, prefs, support] {
                let candidate = try #require(group.candidates.first { $0.path == path })
                #expect(candidate.confidence == .uncertain, "\(path)")
                #expect(candidate.note == OrphanScanner.systemWideNote)
            }
        }
    }

    /// Review N1: Eine App auf einem gerade nicht angeschlossenen Laufwerk kennen weder Inventar noch Spotlight – ihre
    /// Container (Dokumente sandboxed Apps) sind daher nie vorausgewählt.
    @Test func appDataContainersAreNeverPreselected() async throws {
        try await LibraryFixture.with { fixture in
            let container = try fixture.folder(fixture.userLibrary("Containers/ai.openclaw.mac"))
            let group = try fixture.folder(fixture.userLibrary("Group Containers/group.ai.openclaw.mac"))
            let cache = try fixture.folder(fixture.userLibrary("Caches/ai.openclaw.mac"))
            let found = try #require(await scan(fixture, missing: ["ai.openclaw.mac"]).groups.first)
            #expect(found.candidates.first { $0.path == cache }?.confidence == .safe)
            for path in [container, group] {
                let candidate = try #require(found.candidates.first { $0.path == path })
                #expect(candidate.confidence == .uncertain, "\(path)")
                #expect(candidate.note == OrphanScanner.appDataNote)
            }
        }
    }

    // MARK: Unvollständiges Inventar

    @Test func withoutAnAppInventoryNothingIsOffered() async throws {
        try await LibraryFixture.with { fixture in
            try fixture.folder(fixture.userLibrary("Caches/ai.openclaw.mac"))
            let neverDelivered = TestData.appSnapshot([], baseline: TestData.allSources)
            let failed = TestData.appSnapshot([], errors: [SourceError(source: .apps, message: "kaputt")])
            for snapshot in [neverDelivered, failed] {
                let resolver = OrphanResolver(missing: ["ai.openclaw.mac"])
                let result = await scan(fixture, snapshot, resolver: resolver)
                #expect(result.groups.isEmpty)
                #expect(result.coverage == .unavailable("App-Inventar liegt nicht vor"))
                #expect(resolver.queries.isEmpty)
            }
        }
    }

    @Test func unreadableAppRootOffersNothing() async throws {
        try await LibraryFixture.with { fixture in
            try fixture.folder(fixture.userLibrary("Caches/ai.openclaw.mac"))
            let root = fixture.system("Applications")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root) }
            let result = await scan(fixture, missing: ["ai.openclaw.mac"])
            #expect(result.groups.isEmpty)
            guard case .unavailable(let reason) = result.coverage else {
                Issue.record("erwartet .unavailable, war \(result.coverage)")
                return
            }
            #expect(reason.hasPrefix("App-Ordner nicht lesbar: "))
        }
    }

    @Test func unreadableAppFolderMakesEverythingUncertain() async throws {
        try await LibraryFixture.with { fixture in
            try fixture.folder(fixture.userLibrary("Caches/ai.openclaw.mac"))
            let locked = fixture.system("Applications/Locked")
            try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
            let result = await scan(fixture, missing: ["ai.openclaw.mac"])
            #expect(result.coverage == .incomplete("App-Inventar unvollständig: 1 Ordner nicht lesbar"))
            let candidate = try #require(result.groups.first?.candidates.first)
            #expect(candidate.confidence == .uncertain)
            #expect(candidate.note == "App-Inventar unvollständig: 1 Ordner nicht lesbar")
        }
    }

    @Test func bundlesWithoutKnownIdentifierMakeEverythingUncertain() async throws {
        try await LibraryFixture.with { fixture in
            try fixture.folder(fixture.userLibrary("Caches/ai.openclaw.mac"))
            try FileManager.default.createSymbolicLink(atPath: fixture.system("Applications/Linked.app"),
                                                       withDestinationPath: fixture.home + "/Elsewhere.app")
            try fixture.app("Broken", bundleID: nil)
            let result = await scan(fixture, missing: ["ai.openclaw.mac"])
            #expect(result.coverage == .incomplete("App-Inventar unvollständig: 2 Apps ohne bekannte Bundle-ID"))
            #expect(result.groups.first?.candidates.first?.confidence == .uncertain)
        }
    }

    @Test func infoPlistAsFIFODoesNotBlock() async throws {
        try await LibraryFixture.with { fixture in
            let bundle = URL(fileURLWithPath: fixture.system("Applications/Pipe.app/Contents"))
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            let fifo = try FIFOFixture.make(in: bundle, named: "Info.plist")
            let snapshot = TestData.appSnapshot([]), layout = fixture.layout
            let coverage = await FIFOFixture.completes(unblocking: fifo) { OrphanInventory(snapshot: snapshot, layout: layout).coverage }
            #expect(coverage == .incomplete("App-Inventar unvollständig: 1 App ohne bekannte Bundle-ID"))
        }
    }

    @Test func unreadableLeftoverLocationsAreReported() async throws {
        try await LibraryFixture.with { fixture in
            let caches = fixture.userLibrary("Caches")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: caches)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: caches) }
            let result = await scan(fixture, missing: [])
            #expect(result.unreadableLocations == [caches])
            #expect(result.leftovers.unreadableLocations == [caches])
        }
    }

    // MARK: Autostart und Berechtigungen

    @Test func orphanAutostartItemsAndGrants() async throws {
        try await LibraryFixture.with { fixture in
            let gone = TestData.item("ai.openclaw.gateway", programPresence: .missing)
            let btm = TestData.item("com.example.login", kind: .loginItem, source: .btm, programPresence: .missing)
            let apple = TestData.item("com.apple.gone", domain: .system, programPresence: .missing)
            let present = TestData.item("com.example.agent")
            let removedGrant = TestData.grant(client: TestData.app("ai.openclaw.mac", presence: .probablyMissing))
            let appleGrant = TestData.grant(client: TestData.app("com.apple.gone", presence: .missing))
            let snapshot = TestData.appSnapshot([], grants: [removedGrant, appleGrant, TestData.grant()],
                                                items: [gone, btm, apple, present])
            let result = await scan(fixture, snapshot, missing: [])
            #expect(result.autostartItems == [gone])
            #expect(result.grants == [removedGrant])
        }
    }

    @Test func autostartAndGrantsDoNotDependOnTheAppInventory() async throws {
        try await LibraryFixture.with { fixture in
            let gone = TestData.item("ai.openclaw.gateway", programPresence: .missing)
            let snapshot = TestData.appSnapshot([], items: [gone], baseline: TestData.allSources)
            #expect(await scan(fixture, snapshot, missing: []).autostartItems == [gone])
        }
    }
}

@Suite struct BundleIDShapeTests {
    @Test(arguments: ["ai.openclaw.mac", "com.hnc.Discord.ShipIt", "at.EternalStorms.Yoink", "recipes.mela.app",
                      "com.electron.ollama.ShipIt.C515AAEC-D5A7-5948-B2D7-7F109E3D63FC", "io.github.wickenico.wailbrew"])
    func plausible(_ identifier: String) {
        #expect(BundleIDShape.isPlausible(identifier))
    }

    @Test(arguments: ["Steam", "com.twoparts", "Com.Upper.case", "com..empty", "com.ümlaut.app", "c.short.x",
                      "averylongtld.foo.bar", "com.foo.bar.", "com.foo bar.baz", "com.foo/bar.baz"])
    func implausible(_ identifier: String) {
        #expect(!BundleIDShape.isPlausible(identifier))
    }

    @Test(arguments: ["com.apple.Safari", "COM.APPLE.x", "group.com.apple.notes", "74J34U3R6X.com.apple.iWork",
                      "is.workflow.my.app", "developer.apple.wwdc-Release", "org.swift.swiftpm", "org.cups.printers",
                      "edu.mit.Kerberos", "de.example.apple.helper", "74J34U3R6X.group.com.apple.notes"])
    func apple(_ identifier: String) {
        #expect(BundleIDShape.isApple(identifier))
    }

    @Test(arguments: ["ai.openclaw.mac", "com.example.applesauce", "com.pineapple.app"])
    func notApple(_ identifier: String) {
        #expect(!BundleIDShape.isApple(identifier))
    }
}
