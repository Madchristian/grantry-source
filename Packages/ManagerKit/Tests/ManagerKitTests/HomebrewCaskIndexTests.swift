import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct HomebrewCaskIndexTests {
    /// Gekürzt aus `/opt/homebrew/Caskroom/darktable/.metadata/INSTALL_RECEIPT.json` (Homebrew 6.0.19).
    static let darktableReceipt = Data("""
    {"homebrew_version":"6.0.19","installed_on_request":true,"uninstall_artifacts":[{"uninstall":[{"quit":"org.darktable"}]},\
    {"app":["darktable.app"]},{"zap":[{"trash":["~/.cache/darktable","~/Library/Saved Application State/org.darktable.savedState"]}]}]}
    """.utf8)

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func receiptListsOnlyAppArtifacts() {
        #expect(HomebrewCaskIndex.appArtifacts(inReceipt: Self.darktableReceipt) == [.init(source: "darktable.app", target: nil)])
    }

    @Test func receiptTargetAppliesToThePrecedingApp() {
        let receipt = Data(#"{"uninstall_artifacts":[{"app":["Foo.app",{"target":"Bar.app"},"Baz.app"]}]}"#.utf8)
        #expect(HomebrewCaskIndex.appArtifacts(inReceipt: receipt) == [
            .init(source: "Foo.app", target: "Bar.app"), .init(source: "Baz.app", target: nil),
        ])
    }

    @Test(arguments: ["{}", "[]", "kaputt", #"{"uninstall_artifacts":"app"}"#])
    func malformedReceiptHasNoArtifacts(text: String) {
        #expect(HomebrewCaskIndex.appArtifacts(inReceipt: Data(text.utf8)).isEmpty)
    }

    @Test func configNamesTheAppDirectory() {
        let config = Data(#"{"default":{"languages":["de-DE"],"appdir":"/Applications"},"env":{},"explicit":{}}"#.utf8)
        #expect(HomebrewCaskIndex.appDirectory(inConfig: config) == "/Applications")
        #expect(HomebrewCaskIndex.appDirectory(inConfig: Data("{}".utf8)) == nil)
    }

    /// Reihenfolge wie Homebrew: `explicit` (`--appdir`) → `env` (`HOMEBREW_CASK_OPTS`) → `default`; `~` = Benutzerordner.
    @Test func configPrefersExplicitThenEnvThenDefault() {
        func directory(_ json: String) -> String? {
            HomebrewCaskIndex.appDirectory(inConfig: Data(json.utf8), home: "/Users/test")
        }
        #expect(directory(#"{"default":{"appdir":"/Applications"},"env":{"appdir":"/Env"},"explicit":{"appdir":"/Explicit"}}"#) == "/Explicit")
        #expect(directory(#"{"default":{"appdir":"/Applications"},"env":{"appdir":"/Env"},"explicit":{}}"#) == "/Env")
        #expect(directory(#"{"default":{"appdir":"/Applications"},"env":{},"explicit":{}}"#) == "/Applications")
        #expect(directory(#"{"default":{"appdir":"/Applications"},"env":{},"explicit":{"appdir":"~/Applications"}}"#) == "/Users/test/Applications")
        #expect(directory(#"{"default":{"appdir":"/Applications"},"env":{"appdir":""},"explicit":{}}"#) == "/Applications")
    }

    @Test func explicitAppDirectoryWithTildeLocatesTheReceiptApp() throws {
        try ScratchDirectory.with(prefix: "cask") { directory in
            let home = directory.appending(path: "home")
            let app = try AppFixture.make(in: home.appending(path: "Applications"), named: "Tool", bundleID: "com.example.tool")
            let metadata = directory.appending(path: "Caskroom/tool/.metadata")
            try write(#"{"uninstall_artifacts":[{"app":["Tool.app"]}]}"#, to: metadata.appending(path: "INSTALL_RECEIPT.json"))
            try write(#"{"default":{"appdir":"/Applications"},"env":{},"explicit":{"appdir":"~/Applications"}}"#,
                      to: metadata.appending(path: "config.json"))
            let index = HomebrewCaskIndex.load(caskrooms: [directory.appending(path: "Caskroom").path], home: home.path)
            #expect(index.cask(forAppAt: app.path) == "tool")
        }
    }

    /// Ein ins Leere zeigender Symlink im Versionsordner (App von Hand gelöscht) belegt nichts und stört nicht.
    @Test func deadCaskroomSymlinkIsIgnored() throws {
        try ScratchDirectory.with(prefix: "cask") { directory in
            let version = directory.appending(path: "Caskroom/gone/1.0")
            try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
            let missing = directory.appending(path: "Applications/Gone.app")
            try FileManager.default.createSymbolicLink(atPath: version.appending(path: "Gone.app").path, withDestinationPath: missing.path)
            let index = HomebrewCaskIndex.load(caskrooms: [directory.appending(path: "Caskroom").path])
            #expect(index.cask(forAppAt: missing.path) == nil)
        }
    }

    @Test func symlinkInVersionFolderMapsTheApp() throws {
        try ScratchDirectory.with(prefix: "cask") { directory in
            let app = try AppFixture.make(in: directory.appending(path: "Applications"), named: "darktable", bundleID: "org.darktable")
            let version = directory.appending(path: "Caskroom/darktable/5.6.1")
            try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: version.appending(path: "darktable.app").path, withDestinationPath: app.path)
            // Unter Homebrew 6 leer – darf nicht stören.
            try write("{}", to: directory.appending(path: "Caskroom/darktable/.metadata/5.6.1/20260828080101.280/Casks/darktable.json"))
            let index = HomebrewCaskIndex.load(caskrooms: [directory.appending(path: "Caskroom").path])
            #expect(index.cask(forAppAt: app.path) == "darktable")
            #expect(index.cask(forAppAt: app.path.uppercased()) == "darktable", "APFS unterscheidet keine Groß-/Kleinschreibung")
        }
    }

    /// Ein Bundle, das nur im Caskroom liegt (kein `app`-Artefakt wie bei `sbx`), ist kein Beleg.
    @Test func bundleInsideTheCaskroomIsNoEvidence() throws {
        try ScratchDirectory.with(prefix: "cask") { directory in
            let bundle = try AppFixture.make(in: directory.appending(path: "Caskroom/sbx/1.0"), named: "sbx", bundleID: "com.example.sbx")
            let index = HomebrewCaskIndex.load(caskrooms: [directory.appending(path: "Caskroom").path])
            #expect(index == .empty)
            #expect(index.cask(forAppAt: bundle.path) == nil)
        }
    }

    @Test func receiptWithoutSymlinkUsesTheConfiguredAppDirectory() throws {
        try ScratchDirectory.with(prefix: "cask") { directory in
            let apps = directory.appending(path: "Programme")
            let app = try AppFixture.make(in: apps, named: "WailBrew", bundleID: "io.github.wickenico.wailbrew")
            let metadata = directory.appending(path: "Caskroom/wailbrew/.metadata")
            try write(#"{"uninstall_artifacts":[{"app":["WailBrew.app"]}]}"#, to: metadata.appending(path: "INSTALL_RECEIPT.json"))
            try write(#"{"default":{"appdir":"\#(apps.path)"}}"#, to: metadata.appending(path: "config.json"))
            let index = HomebrewCaskIndex.load(caskrooms: [directory.appending(path: "Caskroom").path])
            #expect(index.cask(forAppAt: app.path) == "wailbrew")
        }
    }

    @Test func targetWithTildeUsesHome() throws {
        try ScratchDirectory.with(prefix: "cask") { directory in
            let home = directory.appending(path: "home")
            let app = try AppFixture.make(in: home.appending(path: "Applications"), named: "Tool", bundleID: "com.example.tool")
            try write(#"{"uninstall_artifacts":[{"app":["Tool-1.0.app",{"target":"~/Applications/Tool.app"}]}]}"#,
                      to: directory.appending(path: "Caskroom/tool/.metadata/INSTALL_RECEIPT.json"))
            let index = HomebrewCaskIndex.load(caskrooms: [directory.appending(path: "Caskroom").path], home: home.path)
            #expect(index.cask(forAppAt: app.path) == "tool")
        }
    }

    @Test func unrelatedAppsAndMissingCaskroomsAreNotHomebrew() throws {
        try ScratchDirectory.with(prefix: "cask") { directory in
            let app = try AppFixture.make(in: directory, named: "Other", bundleID: "com.example.other")
            #expect(HomebrewCaskIndex.load(caskrooms: [directory.appending(path: "missing").path]).cask(forAppAt: app.path) == nil)
        }
    }

    @Test func fifoReceiptDoesNotBlock() async throws {
        try await ScratchDirectory.with(prefix: "cask") { directory in
            let metadata = directory.appending(path: "Caskroom/trap/.metadata")
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
            let fifo = try FIFOFixture.make(in: metadata, named: "INSTALL_RECEIPT.json")
            let caskroom = directory.appending(path: "Caskroom").path
            let result = await FIFOFixture.completes(unblocking: fifo) { HomebrewCaskIndex.load(caskrooms: [caskroom]) == .empty }
            #expect(result == true)
        }
    }

    @Test func fifoConfigDoesNotBlock() async throws {
        try await ScratchDirectory.with(prefix: "cask") { directory in
            let metadata = directory.appending(path: "Caskroom/trap/.metadata")
            try write(#"{"uninstall_artifacts":[{"app":["Trap.app"]}]}"#, to: metadata.appending(path: "INSTALL_RECEIPT.json"))
            let fifo = try FIFOFixture.make(in: metadata, named: "config.json")
            let caskroom = directory.appending(path: "Caskroom").path
            let result = await FIFOFixture.completes(unblocking: fifo) {
                HomebrewCaskIndex.load(caskrooms: [caskroom]).cask(forAppAt: "/Applications/Trap.app")
            }
            #expect(result == "trap", "ohne lesbare config.json gilt /Applications")
        }
    }
}
