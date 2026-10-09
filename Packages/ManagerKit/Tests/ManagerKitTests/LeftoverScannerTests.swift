import Foundation
import Synchronization
import Testing
@testable import ManagerKit

/// Größe = Länge des Pfads (deterministisch, ohne Dateisystem).
private struct PathLengthSizer: FileSizeMeasuring {
    func allocatedSize(of path: String) -> Int64? { Int64(path.count) }
}

private struct FixedSizer: FileSizeMeasuring {
    let size: Int64
    func allocatedSize(of path: String) -> Int64? { size }
}

/// Zählt gleichzeitige Messungen (je 20 ms) und liefert 7 Bytes.
private final class ConcurrencyRecordingSizer: FileSizeMeasuring {
    private struct State {
        var running = 0
        var maximum = 0
        var calls = 0
    }

    private let state = Mutex(State())
    var maximum: Int { state.withLock { $0.maximum } }
    var calls: Int { state.withLock { $0.calls } }

    func allocatedSize(of path: String) -> Int64? { 7 }

    func measure(_ path: String) async -> FileSize {
        state.withLock { state in
            state.calls += 1
            state.running += 1
            state.maximum = max(state.maximum, state.running)
        }
        try? await Task.sleep(for: .milliseconds(20))
        state.withLock { $0.running -= 1 }
        return .bytes(7)
    }
}

@Suite struct LeftoverScannerTests {
    private func app(_ fixture: LibraryFixture, _ name: String, _ bundleID: String?, team: String? = "TEAMA12345") throws -> InstalledApp {
        let path = try fixture.app(name, bundleID: bundleID)
        return TestData.installedApp(name, bundleID: bundleID, path: path,
                                     signing: SigningInfo(kind: .developerID, teamID: team, isNotarized: true))
    }

    private func scan(_ fixture: LibraryFixture, for app: InstalledApp, installed: [InstalledApp]) async -> [LeftoverCandidate] {
        await LeftoverScanner(layout: fixture.layout, sizes: PathLengthSizer(), appSizes: PathLengthSizer())
            .scan(for: app, installedApps: installed).candidates
    }

    private static let appleAppStore = SigningInfo(kind: .appStore, teamID: "74J34U3R6X", isNotarized: true)

    @Test func safeEntriesByBundleIDAtAllLocations() async throws {
        try await LibraryFixture.with { fixture in
            let tool = try app(fixture, "Tool", "com.example.tool")
            let expected = [
                try fixture.folder(fixture.userLibrary("Containers/com.example.tool")),
                try fixture.folder(fixture.userLibrary("Containers/com.example.tool.safari")),
                try fixture.folder(fixture.userLibrary("Application Support/com.example.tool")),
                try fixture.folder(fixture.userLibrary("Caches/com.example.tool.ShipIt")),
                try fixture.file(fixture.userLibrary("Preferences/com.example.tool.plist")),
                try fixture.file(fixture.userLibrary("Preferences/ByHost/com.example.tool.C515AAEC.plist")),
                try fixture.folder(fixture.userLibrary("Saved Application State/com.example.tool.savedState")),
                try fixture.file(fixture.userLibrary("HTTPStorages/com.example.tool.binarycookies")),
                try fixture.folder(fixture.userLibrary("WebKit/com.example.tool")),
                try fixture.folder(fixture.userLibrary("Logs/com.example.tool")),
                try fixture.folder(fixture.userLibrary("Application Scripts/com.example.tool")),
                try fixture.folder(fixture.system("Library/Application Support/com.example.tool")),
                try fixture.folder(fixture.system("Library/Caches/com.example.tool")),
                try fixture.file(fixture.system("Library/Preferences/com.example.tool.plist")),
            ]
            try fixture.folder(fixture.userLibrary("Caches/com.example.toolbox"))  // anderer Name, kein Präfix mit Punkt
            try fixture.folder(fixture.userLibrary("Caches/.com.example.tool"))  // versteckt
            let candidates = await scan(fixture, for: tool, installed: [tool])
            let first = try #require(candidates.first)
            #expect(first.path == tool.path && first.kind == .appBundle && first.confidence == .safe)
            #expect(Set(candidates.dropFirst().map(\.path)) == Set(expected))
            #expect(candidates.allSatisfy { $0.confidence == .safe && $0.isPreselected })
            #expect(candidates.allSatisfy { $0.size == .bytes(Int64($0.path.count)) })
            #expect(candidates.allSatisfy { $0.identity == FileIdentity.of($0.path) && $0.identity != nil })
        }
    }

    @Test(arguments: [SigningInfo.Kind.unsigned, .adHoc, .unknown, .development, .appStore])
    func systemWideEntriesWithoutDeveloperIDAreUncertain(kind: SigningInfo.Kind) async throws {
        try await LibraryFixture.with { fixture in
            var tool = try app(fixture, "Tool", "com.example.tool")
            tool.signing = SigningInfo(kind: kind)
            let user = try fixture.file(fixture.userLibrary("Preferences/com.example.tool.plist"))
            let system = [
                try fixture.folder(fixture.system("Library/Application Support/com.example.tool")),
                try fixture.folder(fixture.system("Library/Caches/com.example.tool")),
                try fixture.file(fixture.system("Library/Preferences/com.example.tool.plist")),
            ]
            let candidates = await scan(fixture, for: tool, installed: [tool])
            let systemCandidates = candidates.filter { system.contains($0.path) }
            #expect(systemCandidates.count == 3)
            #expect(systemCandidates.allSatisfy { !$0.isPreselected && $0.note != nil })
            #expect(candidates.filter { [tool.path, user].contains($0.path) }.allSatisfy { $0.isPreselected })
        }
    }

    /// Bundle-IDs und Eintragsnamen ohne Groß-/Kleinschreibung (APFS).
    @Test func identifiersIgnoreCase() async throws {
        try await LibraryFixture.with { fixture in
            let discord = try app(fixture, "Discord", "com.hnc.Discord")
            let lower = try fixture.folder(fixture.userLibrary("Caches/com.hnc.discord.ShipIt"))
            #expect(await scan(fixture, for: discord, installed: [discord]).map(\.path).contains(lower))
        }
    }

    @Test func longerInstalledIdentifierKeepsItsEntries() async throws {
        try await LibraryFixture.with { fixture in
            let tool = try app(fixture, "Tool", "com.example.tool")
            let pro = try app(fixture, "Tool Pro", "com.example.tool.pro")
            try fixture.folder(fixture.userLibrary("Caches/com.example.tool.pro"))
            try fixture.folder(fixture.userLibrary("Caches/com.example.tool.pro.helper"))
            let ship = try fixture.folder(fixture.userLibrary("Caches/com.example.tool.ShipIt"))
            let paths = await scan(fixture, for: tool, installed: [tool, pro]).map(\.path)
            #expect(paths.contains(ship))
            #expect(!paths.contains(fixture.userLibrary("Caches/com.example.tool.pro")))
            #expect(!paths.contains(fixture.userLibrary("Caches/com.example.tool.pro.helper")))
        }
    }

    @Test func nameMatchesAreUncertainWithVendorNote() async throws {
        try await LibraryFixture.with { fixture in
            let steam = try app(fixture, "Steam", "com.valvesoftware.steam")
            let link = try app(fixture, "Steam Link", "com.valvesoftware.link", team: "TEAMB67890")
            let byName = try fixture.folder(fixture.userLibrary("Application Support/Steam"))
            let byVendor = try fixture.folder(fixture.userLibrary("Caches/ValveSoftware"))
            try fixture.folder(fixture.userLibrary("Containers/Steam"))  // Container: keine Namenstreffer
            try fixture.folder(fixture.userLibrary("WebKit/Steam"))  // WebKit: keine Namenstreffer
            let uncertain = await scan(fixture, for: steam, installed: [steam, link]).filter { $0.confidence == .uncertain }
            #expect(Set(uncertain.map(\.path)) == [byName, byVendor])
            #expect(uncertain.allSatisfy { $0.note == "Gehört evtl. auch zu: Steam Link" && !$0.isPreselected })
        }
    }

    @Test func nameMatchesWithoutOtherAppsHaveNoNote() async throws {
        try await LibraryFixture.with { fixture in
            let discord = try app(fixture, "Discord", "com.hnc.Discord")
            let byName = try fixture.folder(fixture.userLibrary("Application Support/discord"))
            let logs = try fixture.folder(fixture.userLibrary("Logs/Discord"))
            let system = try fixture.folder(fixture.system("Library/Application Support/Discord"))
            try fixture.folder(fixture.system("Library/Caches/Discord"))  // nur Benutzer-Caches (Abweichung 7)
            let uncertain = await scan(fixture, for: discord, installed: [discord]).filter { $0.confidence == .uncertain }
            #expect(Set(uncertain.map(\.path)) == [byName, logs, system])
            #expect(uncertain.allSatisfy { $0.note == nil })
        }
    }

    /// Ein Eintrag, der einer anderen installierten App gehört, ist kein Namenstreffer; ebenso keine Apple-Kennungen.
    @Test func nameMatchesSkipOwnedAndAppleEntries() async throws {
        try await LibraryFixture.with { fixture in
            let tool = try app(fixture, "com.example.other", "com.example.tool")
            let other = try app(fixture, "Other", "com.example.other")
            try fixture.folder(fixture.userLibrary("Caches/com.example.other"))
            let mail = try app(fixture, "com.apple.mail", "org.example.mail")
            try fixture.folder(fixture.userLibrary("Caches/com.apple.mail"))
            #expect(await scan(fixture, for: tool, installed: [tool, other]).map(\.path) == [tool.path])
            #expect(await scan(fixture, for: mail, installed: [mail]).map(\.path) == [mail.path])
        }
    }

    @Test func groupContainersDependOnTheTeam() async throws {
        try await LibraryFixture.with { fixture in
            let editor = try app(fixture, "Editor", "org.studio.editor", team: "STUDIO1234")
            let viewer = try app(fixture, "Viewer", "net.viewer.app", team: "STUDIO1234")
            let tool = try app(fixture, "Tool", "com.example.tool")
            let shared = try fixture.folder(fixture.userLibrary("Group Containers/STUDIO1234.org.studio"))
            let own = try fixture.folder(fixture.userLibrary("Group Containers/TEAMA12345.com.example"))
            let group = try fixture.folder(fixture.userLibrary("Group Containers/group.com.example.tool"))
            try fixture.folder(fixture.userLibrary("Group Containers/group.com.example.toolbox"))
            try fixture.folder(fixture.userLibrary("Group Containers/TEAMB67890.com.example"))
            try fixture.folder(fixture.userLibrary("Group Containers/com.example.tool"))  // ohne Präfix: unbekannte Form
            let editorResult = await scan(fixture, for: editor, installed: [editor, viewer, tool])
            #expect(editorResult.first { $0.path == shared }?.confidence == .uncertain)
            #expect(editorResult.first { $0.path == shared }?.note == "Team-ID auch bei: Viewer")
            let toolResult = await scan(fixture, for: tool, installed: [editor, viewer, tool])
            #expect(toolResult.filter { $0.kind == .groupContainer }.map(\.path).sorted() == [group, own].sorted())
            #expect(toolResult.allSatisfy { $0.confidence == .safe })
        }
    }

    /// Ohne Team-ID (ad hoc, unsigniert) keine Team-Gruppen-Container.
    @Test func appWithoutTeamGetsNoTeamContainers() async throws {
        try await LibraryFixture.with { fixture in
            let tool = try app(fixture, "Tool", "com.example.tool", team: nil)
            try fixture.folder(fixture.userLibrary("Group Containers/TEAMA12345.com.example"))
            #expect(await scan(fixture, for: tool, installed: [tool]).map(\.path) == [tool.path])
        }
    }

    /// Apple-Kennungen nur als exakte Treffer der Apple-App, die gerade entfernt wird; keine Namenstreffer.
    @Test func appleAppGetsOnlyItsOwnIdentifiers() async throws {
        try await LibraryFixture.with { fixture in
            let path = try fixture.app("Keynote", bundleID: "com.apple.Keynote")
            let keynote = TestData.installedApp("Keynote", bundleID: "com.apple.Keynote", path: path, origin: .appStore,
                                                signing: Self.appleAppStore)
            let own = try fixture.folder(fixture.userLibrary("Containers/com.apple.Keynote"))
            try fixture.folder(fixture.userLibrary("Containers/com.apple.Pages"))
            try fixture.folder(fixture.userLibrary("Application Support/Keynote"))
            #expect(await scan(fixture, for: keynote, installed: [keynote]).dropFirst().map(\.path) == [own])
        }
    }

    /// Eine Bundle-ID, die nur ein Namensraum ist (`com.apple`, `com`), besitzt keine fremden Einträge per Präfix.
    @Test func namespaceBundleIDsOwnNothingByPrefix() async throws {
        try await LibraryFixture.with { fixture in
            let fake = try app(fixture, "Fake", "com.apple")
            let bare = try app(fixture, "Bare", "com")
            try fixture.folder(fixture.userLibrary("Containers/com.apple.mail"))
            try fixture.folder(fixture.userLibrary("Containers/com.example.tool"))
            #expect(await scan(fixture, for: fake, installed: [fake, bare]).map(\.path) == [fake.path])
            #expect(await scan(fixture, for: bare, installed: [fake, bare]).map(\.path) == [bare.path])
        }
    }

    /// Ohne Bundle-ID nur Namenstreffer (unsicher) und das Bundle selbst.
    @Test func appWithoutBundleID() async throws {
        try await LibraryFixture.with { fixture in
            let tool = try app(fixture, "Tool", nil)
            let byName = try fixture.folder(fixture.userLibrary("Caches/Tool"))
            try fixture.folder(fixture.userLibrary("Containers/com.example.tool"))
            let result = await scan(fixture, for: tool, installed: [tool])
            #expect(result.map(\.path) == [tool.path, byName])
            #expect(result.last?.confidence == .uncertain)
        }
    }

    @Test func symlinksAndBlockedPlacesNeverAppear() async throws {
        try await LibraryFixture.with { fixture in
            let tool = try app(fixture, "Tool", "com.example.tool")
            try FileManager.default.createSymbolicLink(atPath: fixture.userLibrary("Caches/com.example.tool"),
                                                       withDestinationPath: fixture.home + "/Documents")
            try FileManager.default.createSymbolicLink(atPath: fixture.userLibrary("Caches/Tool"),
                                                       withDestinationPath: fixture.userLibrary("Keychains"))
            try fixture.folder(fixture.userLibrary("Keychains/com.example.tool"))
            #expect(await scan(fixture, for: tool, installed: [tool]).map(\.path) == [tool.path])
        }
    }

    /// Ein Reste-Ort, der selbst ein Symlink ist (z. B. auf die Schlüsselbunde), liefert nichts.
    @Test func symlinkedLocationIsIgnored() async throws {
        try await LibraryFixture.with { fixture in
            let tool = try app(fixture, "Tool", "com.example.tool")
            try fixture.folder(fixture.userLibrary("Keychains/com.example.tool"))
            try fixture.folder(fixture.home + "/Documents/com.example.tool")
            try fixture.replaceWithSymlink(fixture.userLibrary("Containers"), to: fixture.userLibrary("Keychains"))
            try fixture.replaceWithSymlink(fixture.userLibrary("Caches"), to: fixture.home + "/Documents")
            #expect(await scan(fixture, for: tool, installed: [tool]).map(\.path) == [tool.path])
        }
    }

    /// Ein App-Bundle als Symlink (`/Applications/Safari.app`) wird nie Kandidat – auch nicht das Ziel.
    @Test func symlinkedAppBundleIsNotACandidate() async throws {
        try await LibraryFixture.with { fixture in
            let real = try fixture.app("Real", bundleID: "com.example.real", subfolder: "../System")
            let link = fixture.system("Applications/Real.app")
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
            let app = TestData.installedApp("Real", bundleID: "com.example.real", path: link)
            let data = try fixture.folder(fixture.userLibrary("Caches/com.example.real"))
            #expect(await scan(fixture, for: app, installed: [app]).map(\.path) == [data])
        }
    }

    /// Größen mit dem echten Rechner: FIFOs blockieren nicht und zählen nicht, Symlinks werden nicht verfolgt.
    @Test func realSizesDoNotBlockOnFIFOs() async throws {
        try await LibraryFixture.with { fixture in
            let tool = try app(fixture, "Tool", "com.example.tool")
            let container = try fixture.folder(fixture.userLibrary("Containers/com.example.tool"), bytes: 8_192)
            let fifo = try FIFOFixture.make(in: URL(fileURLWithPath: container))
            try FileManager.default.createSymbolicLink(atPath: container + "/big",
                                                       withDestinationPath: fixture.system("Applications"))
            let entryFIFO = try FIFOFixture.make(in: URL(fileURLWithPath: fixture.userLibrary("Caches")),
                                                 named: "com.example.tool")
            let scanner = LeftoverScanner(layout: fixture.layout)
            let result = await FIFOFixture.completes(unblocking: fifo) {
                await scanner.scan(for: tool, installedApps: [tool]).candidates
            }
            let candidates = try #require(result)
            let size = try #require(candidates.first { $0.path == container }?.size.bytes)
            #expect(size >= 8_192 && size < 64 * 1_024)
            #expect(candidates.first { $0.path == entryFIFO.path }?.size == .bytes(0))
        }
    }

    /// Eine unsignierte Kopie mit Apple-Bundle-ID erbt keine Apple-Daten (C1).
    @Test func unsignedAppleCopyGetsNoAppleEntries() async throws {
        try await LibraryFixture.with { fixture in
            let path = try fixture.app("Notes", bundleID: "com.apple.Notes")
            let fake = TestData.installedApp("Notes", bundleID: "com.apple.Notes", path: path,
                                             signing: SigningInfo(kind: .unsigned))
            try fixture.folder(fixture.userLibrary("Containers/com.apple.Notes"))
            try fixture.folder(fixture.userLibrary("Group Containers/group.com.apple.notes"))
            try fixture.file(fixture.userLibrary("Preferences/com.apple.Notes.plist"))
            #expect(await scan(fixture, for: fake, installed: [fake]).map(\.path) == [path])
        }
    }

    /// Auch eine echt signierte Kopie einer System-App (gleiche Bundle-ID unter `/System/Applications`) erbt nichts.
    @Test func copyOfSystemAppGetsNoAppleEntries() async throws {
        try await LibraryFixture.with { fixture in
            try AppFixture.make(in: URL(fileURLWithPath: fixture.system("System/Applications")), named: "Notes",
                                bundleID: "com.apple.Notes")
            let path = try fixture.app("Notes", bundleID: "com.apple.Notes")
            let copy = TestData.installedApp("Notes", bundleID: "com.apple.Notes", path: path, origin: .apple,
                                             signing: SigningInfo(kind: .apple, isNotarized: true))
            try fixture.folder(fixture.userLibrary("Containers/com.apple.Notes"))
            try fixture.folder(fixture.userLibrary("Group Containers/group.com.apple.notes"))
            #expect(await scan(fixture, for: copy, installed: [copy]).map(\.path) == [path])
        }
    }

    /// Apple-App aus dem App Store (Apple-Signatur): eigene Kennungen inklusive `group.<id>` sind sicher.
    @Test func appStoreAppleAppGetsItsGroupContainer() async throws {
        try await LibraryFixture.with { fixture in
            let path = try fixture.app("Keynote", bundleID: "com.apple.iWork.Keynote")
            let keynote = TestData.installedApp("Keynote", bundleID: "com.apple.iWork.Keynote", path: path,
                                                origin: .appStore, signing: Self.appleAppStore)
            let container = try fixture.folder(fixture.userLibrary("Containers/com.apple.iWork.Keynote"))
            let group = try fixture.folder(fixture.userLibrary("Group Containers/group.com.apple.iWork.Keynote"))
            try fixture.folder(fixture.userLibrary("Group Containers/74J34U3R6X.com.apple.iWork"))  // mit Pages geteilt
            let result = await scan(fixture, for: keynote, installed: [keynote])
            #expect(Set(result.dropFirst().map(\.path)) == [container, group])
            #expect(result.allSatisfy { $0.confidence == .safe })
        }
    }

    /// Zwei installierte Apps mit derselben Bundle-ID: Treffer unsicher, mit Hinweis auf die andere (I1).
    @Test func duplicateBundleIDsMakeMatchesUncertain() async throws {
        try await LibraryFixture.with { fixture in
            let tool = try app(fixture, "Tool", "com.example.tool")
            let copyPath = try fixture.app("Tool Copy", bundleID: "com.example.tool", subfolder: "Old")
            let copy = TestData.installedApp("Tool Copy", bundleID: "com.example.tool", path: copyPath)
            let cache = try fixture.folder(fixture.userLibrary("Caches/com.example.tool"))
            let group = try fixture.folder(fixture.userLibrary("Group Containers/group.com.example.tool"))
            let result = await scan(fixture, for: tool, installed: [tool, copy])
            for path in [cache, group] {
                let match = try #require(result.first { $0.path == path })
                #expect(match.confidence == .uncertain && match.note == "Gehört evtl. auch zu: Tool Copy", "\(path)")
            }
            #expect(result.first?.path == tool.path && result.first?.confidence == .safe)
        }
    }

    /// Team-Gruppen-Container nur sicher, wenn alle anderen Apps eine bekannte Team-ID haben und keine denselben
    /// Hersteller trägt (I2): Word mit Outlook ohne prüfbare Team-ID.
    @Test func teamContainerUncertainWhenOtherTeamsAreUnknownOrSameVendor() async throws {
        try await LibraryFixture.with { fixture in
            let word = try app(fixture, "Word", "com.microsoft.Word", team: "UBF8T346G9")
            let outlookPath = try fixture.app("Outlook", bundleID: "com.microsoft.Outlook")
            let outlook = TestData.installedApp("Outlook", bundleID: "com.microsoft.Outlook", path: outlookPath,
                                                signing: SigningInfo(kind: .unknown))
            let shared = try fixture.folder(fixture.userLibrary("Group Containers/UBF8T346G9.Office"))
            let withOutlook = await scan(fixture, for: word, installed: [word, outlook])
            #expect(withOutlook.first { $0.path == shared }?.confidence == .uncertain)
            #expect(withOutlook.first { $0.path == shared }?.note == "Gehört evtl. auch zu: Outlook")

            // Andere App ohne prüfbare Team-ID (anderer Hersteller): ebenfalls unsicher.
            let otherPath = try fixture.app("Other", bundleID: "org.other.app")
            let other = TestData.installedApp("Other", bundleID: "org.other.app", path: otherPath,
                                              signing: SigningInfo(kind: .developerID))
            let withUnknown = await scan(fixture, for: word, installed: [word, other])
            #expect(withUnknown.first { $0.path == shared }?.confidence == .uncertain)
            #expect(withUnknown.first { $0.path == shared }?.note == "Team-ID nicht bei allen Apps prüfbar")

            // Bekannt: Apple-signiert ohne Team-ID, unsigniert, ad hoc, andere Team-ID → sicher.
            let known = [SigningInfo(kind: .apple), SigningInfo(kind: .unsigned), SigningInfo(kind: .adHoc),
                         SigningInfo(kind: .developerID, teamID: "TEAMB67890")].enumerated().map { index, signing in
                TestData.installedApp("Known\(index)", bundleID: "org.known\(index).app", path: otherPath + "\(index)",
                                      signing: signing)
            }
            let safe = await scan(fixture, for: word, installed: [word] + known)
            #expect(safe.first { $0.path == shared }?.confidence == .safe)
        }
    }

    /// Namenstreffer: mindestens 4 Zeichen, keine allgemeinen Namen, keine Apple-Ordnernamen (M4).
    @Test func nameMatchesSkipShortGenericAndAppleNames() async throws {
        try await LibraryFixture.with { fixture in
            try AppFixture.make(in: URL(fileURLWithPath: fixture.system("System/Applications")), named: "Reminders",
                                bundleID: "com.apple.reminders")
            for name in ["Zed", "Data", "Google", "Microsoft", "Electron", "Helper", "Updater", "Support", "Reminders",
                         "Knowledge", "CrashReporter"] {
                try fixture.folder(fixture.userLibrary("Application Support/" + name))
            }
            let chromeOwn = try fixture.folder(fixture.userLibrary("Application Support/Google Chrome"))
            let apps = try [
                app(fixture, "Zed", "dev.zed.Zed"), app(fixture, "Data", nil), app(fixture, "Google Chrome", "com.google.Chrome"),
                app(fixture, "Microsoft Teams", "com.microsoft.teams2"), app(fixture, "Electron", nil),
                app(fixture, "Helper", nil), app(fixture, "Updater", nil), app(fixture, "Support", nil),
                app(fixture, "Reminders", "org.example.reminders"), app(fixture, "Knowledge", "org.example.knowledge"),
                app(fixture, "CrashReporter", "org.example.crash"),
            ]
            for tool in apps {
                let uncertain = await scan(fixture, for: tool, installed: [tool]).filter { $0.confidence == .uncertain }
                #expect(uncertain.map(\.path) == (tool.name == "Google Chrome" ? [chromeOwn] : []), "\(tool.name)")
            }
        }
    }

    /// Präfix-Besitz erst ab drei Bestandteilen, exakte Treffer ab zwei (M5).
    @Test func twoComponentBundleIDOwnsOnlyExactEntries() async throws {
        try await LibraryFixture.with { fixture in
            let darktable = try app(fixture, "darktable", "org.darktable")
            let exact = try fixture.folder(fixture.userLibrary("Caches/org.darktable"))
            try fixture.folder(fixture.userLibrary("Caches/org.darktable.helper"))
            try fixture.folder(fixture.userLibrary("Containers/org.darktable.other"))
            #expect(await scan(fixture, for: darktable, installed: [darktable]).map(\.path) == [darktable.path, exact])
        }
    }

    /// Ein Reste-Ort ohne Leserecht (z. B. ohne Festplattenvollzugriff) ist „nicht lesbar“, nicht „keine Reste“ (M7).
    @Test func unreadableLocationsAreReported() async throws {
        try await LibraryFixture.with { fixture in
            let tool = try app(fixture, "Tool", "com.example.tool")
            let containers = fixture.userLibrary("Containers")
            try fixture.folder(containers + "/com.example.tool")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: containers)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: containers) }
            let result = await LeftoverScanner(layout: fixture.layout, sizes: PathLengthSizer(), appSizes: PathLengthSizer())
                .scan(for: tool, installedApps: [tool])
            #expect(result.unreadableLocations == [containers])
            #expect(result.candidates.map(\.path) == [tool.path])
        }
    }

    /// Das App-Bundle misst der großzügigere Rechner, Reste der knappere.
    @Test func appBundleUsesItsOwnSizer() async throws {
        try await LibraryFixture.with { fixture in
            let tool = try app(fixture, "Tool", "com.example.tool")
            let cache = try fixture.folder(fixture.userLibrary("Caches/com.example.tool"))
            let result = await LeftoverScanner(layout: fixture.layout, sizes: FixedSizer(size: 1), appSizes: FixedSizer(size: 2))
                .scan(for: tool, installedApps: [tool]).candidates
            #expect(result.map(\.size) == [.bytes(2), .bytes(1)])
            #expect(result.map(\.path) == [tool.path, cache])
        }
    }

    /// Größen laufen begrenzt parallel.
    @Test func sizesAreMeasuredWithLimitedConcurrency() async throws {
        try await LibraryFixture.with { fixture in
            let tool = try app(fixture, "Tool", "com.example.tool")
            for index in 0..<12 { try fixture.folder(fixture.userLibrary("Caches/com.example.tool.\(index)")) }
            let sizer = ConcurrencyRecordingSizer()
            let result = await LeftoverScanner(layout: fixture.layout, sizes: sizer, appSizes: sizer)
                .scan(for: tool, installedApps: [tool]).candidates
            #expect(result.count == 13 && result.allSatisfy { $0.size == .bytes(7) })
            #expect(sizer.maximum > 1 && sizer.maximum <= LeftoverScanner.maximumConcurrentMeasurements)
        }
    }

    /// Nach dem Abbruch wird nichts mehr gemessen; Größen bleiben unbekannt.
    @Test func cancelledScanMeasuresNothing() async throws {
        try await LibraryFixture.with { fixture in
            let tool = try app(fixture, "Tool", "com.example.tool")
            try fixture.folder(fixture.userLibrary("Caches/com.example.tool"))
            let sizer = ConcurrencyRecordingSizer()
            let scanner = LeftoverScanner(layout: fixture.layout, sizes: sizer, appSizes: sizer)
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await scanner.scan(for: tool, installedApps: [tool]).candidates
            }
            let result = await task.value
            #expect(result.count == 2 && result.allSatisfy { $0.size == .unknown })
            #expect(sizer.calls == 0)
        }
    }

    @Test func displayOrderPutsSafeFirst() {
        let safe = LeftoverCandidate(path: "/b", kind: .caches, confidence: .safe)
        let uncertain = LeftoverCandidate(path: "/a", kind: .caches, confidence: .uncertain)
        let earlier = LeftoverCandidate(path: "/a", kind: .caches, confidence: .safe)
        #expect([uncertain, safe, earlier].sorted(by: LeftoverCandidate.displayOrder) == [earlier, safe, uncertain])
    }

    @Test func groupContainerNames() {
        #expect(GroupContainerName("74J34U3R6X.com.apple.iWork") == .team("74J34U3R6X", rest: "com.apple.iWork"))
        #expect(GroupContainerName("group.com.apple.AppleSpell") == .group("com.apple.AppleSpell"))
        #expect(GroupContainerName("group.") == nil)
        #expect(GroupContainerName("com.apple.bird") == nil)
        #expect(GroupContainerName("74j34u3r6x.com.example") == nil)
    }

    @Test func vendorTokens() {
        #expect(VendorToken.of("com.valvesoftware.steam") == "valvesoftware")
        #expect(VendorToken.of("io.github.wickenico.wailbrew") == nil)
        #expect(VendorToken.of("com.hnc.Discord") == nil)  // zu kurz
        #expect(VendorToken.of("com.apple.Keynote") == nil)
        #expect(VendorToken.of("org.darktable") == nil)
    }
}
