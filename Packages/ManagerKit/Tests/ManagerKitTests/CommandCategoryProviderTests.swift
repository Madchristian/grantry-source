import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct CommandCategoryProviderTests {
    private func provider(installed: Set<String>, measured: String? = "/home/.cache/uv",
                          arguments: [String] = ["cache", "prune"], risk: StorageRisk = .low,
                          companions: [String] = [], requiredPath: String? = nil,
                          directories: Set<String> = [], kind: ExecutableKind? = nil,
                          sizes: [String: FileSize] = ["/home/.cache/uv": .bytes(2_048)]) -> CommandCategoryProvider {
        CommandCategoryProvider(
            category: StorageCategory(id: "uv", title: "uv-Cache", summary: "", risk: risk, roots: []),
            tool: "uv", arguments: arguments, measuredPath: measured, requiredCompanions: companions,
            requiredPath: requiredPath,
            locator: ToolLocator(home: "/home", isExecutable: { installed.contains($0) },
                                 isDirectory: { directories.contains($0) }, kind: { _ in kind }),
            measurer: FixedSizeMeasurer(sizes)
        )
    }

    @Test func findsToolOnlyAtFixedLocations() {
        let locator = ToolLocator(home: "/home") { $0 == "/home/.local/bin/uv" }
        #expect(locator.locate("uv") == "/home/.local/bin/uv")
        #expect(ToolLocator(home: "/home") { _ in false }.locate("uv") == nil)
        #expect(ToolLocator(home: "/home") { $0 == "/usr/bin/xcrun" }.locate("xcrun", candidates: ["/usr/bin/xcrun"])
                == "/usr/bin/xcrun")
    }

    @Test func givenCandidatesReplaceStandardLocations() {
        // Ein untergeschobenes ~/.local/bin/xcrun darf nie gewählt werden, auch wenn /usr/bin/xcrun fehlt.
        let planted = ToolLocator(home: "/home") { $0 == "/home/.local/bin/xcrun" }
        #expect(planted.locate("xcrun", candidates: ["/usr/bin/xcrun"]) == nil)
        let both = ToolLocator(home: "/home") { $0 == "/home/.local/bin/xcrun" || $0 == "/usr/bin/xcrun" }
        #expect(both.locate("xcrun", candidates: ["/usr/bin/xcrun"]) == "/usr/bin/xcrun")
    }

    @Test func homebrewWinsOverUserLocalBin() {
        let locator = ToolLocator(home: "/home") { $0 == "/opt/homebrew/bin/uv" || $0 == "/home/.local/bin/uv" }
        #expect(locator.locate("uv") == "/opt/homebrew/bin/uv")
    }

    @Test func missingToolIsNotInstalled() async {
        let report = await provider(installed: []).scan()
        #expect(report.status == .notInstalled)
        #expect(report.items.isEmpty)
    }

    @Test func installedToolYieldsOneCommandItem() async throws {
        let report = await provider(installed: ["/opt/homebrew/bin/uv"]).scan()
        let item = try #require(report.items.first)
        #expect(report.status == .available)
        #expect(item.removal == .command(CommandSpec(
            executable: "/usr/bin/env",
            arguments: ["PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "/opt/homebrew/bin/uv", "cache", "prune"])))
        // Der Titel bleibt der lesbare Befehl ohne `env`-Vorsatz.
        #expect(item.title == "/opt/homebrew/bin/uv cache prune")
        #expect(item.size == .bytes(2_048))
        #expect(item.isPreselected)
    }

    @Test func mediumRiskCommandIsNotPreselected() async throws {
        let report = await provider(installed: ["/opt/homebrew/bin/uv"], risk: .medium).scan()
        #expect(try #require(report.items.first).isPreselected == false)
    }

    @Test func unmeasuredCommandHasUnknownSize() async throws {
        let report = await provider(installed: ["/opt/homebrew/bin/uv"], measured: nil).scan()
        #expect(try #require(report.items.first).size == .unknown)
    }

    @Test func expiredMeasurementIsNotPreselected() async throws {
        // #220: Die Messung lief in die Frist – im Zweifel nicht vorauswählen.
        let report = await provider(installed: ["/opt/homebrew/bin/uv"], sizes: [:]).scan()
        let item = try #require(report.items.first)
        #expect(item.size == .unknown && !item.isPreselected)
        // Ohne Messort ist „unbekannt“ gewollt und kein Zweifel.
        let unmeasured = await provider(installed: ["/opt/homebrew/bin/uv"], measured: nil).scan()
        #expect(try #require(unmeasured.items.first).isPreselected)
    }

    @Test func pathStartsWithTheToolsOwnDirectory() async throws {
        let report = await provider(installed: ["/home/.local/bin/uv"]).scan()
        guard case .command(let spec) = try #require(report.items.first).removal else {
            Issue.record("Kein Befehl")
            return
        }
        #expect(spec.arguments.first == "PATH=/home/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func missingCompanionIsNotInstalled() async {
        // npm ohne `node` daneben scheiterte mit „env: node: No such file or directory“.
        let report = await provider(installed: ["/opt/homebrew/bin/uv"], companions: ["node"]).scan()
        #expect(report.status == .notInstalled)
        #expect(report.items.isEmpty)
    }

    @Test func companionNextToTheToolMakesItAvailable() async {
        let elsewhere = await provider(installed: ["/opt/homebrew/bin/uv", "/usr/local/bin/node"],
                                       companions: ["node"]).scan()
        #expect(elsewhere.status == .notInstalled)
        let beside = await provider(installed: ["/opt/homebrew/bin/uv", "/opt/homebrew/bin/node"],
                                    companions: ["node"]).scan()
        #expect(beside.status == .available)
    }

    @Test func nativeBinaryNeedsNoCompanion() async {
        // #220: Homebrew-pnpm ist ein eigenständiges Programm mit eingebautem Node.
        let report = await provider(installed: ["/opt/homebrew/bin/uv"], companions: ["node"], kind: .binary).scan()
        #expect(report.status == .available)
    }

    @Test func environmentScriptStillNeedsCompanionBesideIt() async {
        let report = await provider(installed: ["/opt/homebrew/bin/uv", "/usr/local/bin/node"], companions: ["node"],
                                    kind: .environmentScript("node")).scan()
        #expect(report.status == .notInstalled)
    }

    @Test func scriptWithOwnInterpreterNeedsThatInterpreter() async {
        let node = "/opt/homebrew/Cellar/pnpm/9.0.0/libexec/node"
        let bundled = await provider(installed: ["/opt/homebrew/bin/uv", node], companions: ["node"],
                                     kind: .script(interpreter: node)).scan()
        #expect(bundled.status == .available)
        let missing = await provider(installed: ["/opt/homebrew/bin/uv"], companions: ["node"],
                                     kind: .script(interpreter: node)).scan()
        #expect(missing.status == .notInstalled)
        // Ein Shell-Wrapper bringt kein Node mit: `node` muss weiter daneben liegen.
        let shell = await provider(installed: ["/opt/homebrew/bin/uv", "/bin/bash"], companions: ["node"],
                                   kind: .script(interpreter: "/bin/bash")).scan()
        #expect(shell.status == .notInstalled)
    }

    @Test func missingRequiredPathIsNotInstalled() async {
        let report = await provider(installed: ["/opt/homebrew/bin/uv"], requiredPath: "/home/Devices").scan()
        #expect(report.status == .notInstalled)
        #expect(report.items.isEmpty)
    }

    @Test func presentRequiredPathIsAvailable() async {
        let report = await provider(installed: ["/opt/homebrew/bin/uv"], requiredPath: "/home/Devices",
                                    directories: ["/home/Devices"]).scan()
        #expect(report.status == .available)
        #expect(report.items.count == 1)
    }

    @Test func defaultDirectoryCheckSeesRealFolders() throws {
        try ScratchDirectory.withCanonical(prefix: "locator") { scratch in
            let locator = ToolLocator(home: scratch.path)
            #expect(locator.isDirectory(scratch.path))
            #expect(!locator.isDirectory(scratch.appending(path: "missing").path))
        }
    }
}
