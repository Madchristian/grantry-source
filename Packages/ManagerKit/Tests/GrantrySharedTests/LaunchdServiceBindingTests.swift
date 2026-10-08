import Testing
import Foundation
import TestSupport
@testable import GrantryShared

@Suite struct LaunchdServiceBindingTests {
    private static let dockPrint = """
    gui/501/com.apple.Dock.agent = {
    \tactive count = 1
    \tpath = /System/Library/LaunchAgents/com.apple.Dock.plist
    \ttype = LaunchAgent
    \tstdout path = /dev/null
    \targuments = {
    \t\t/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock
    \t}
    }
    """

    @Test func parsesServicePlistPath() {
        #expect(LaunchdServiceBinding.servicePlistPath(in: Self.dockPrint) == "/System/Library/LaunchAgents/com.apple.Dock.plist")
    }

    /// Nur die oberste Ebene zählt: Verschachtelte Blöcke (Argumente, Umgebung) enthalten frei wählbare Texte. Bei
    /// mehreren Treffern gilt der erste – der echte Plist-Pfad steht vor allen frei wählbaren Blöcken.
    @Test func servicePathIgnoresNestedAndLaterLines() {
        #expect(LaunchdServiceBinding.servicePlistPath(in: "x = {\n\targuments = {\n\t\tpath = /Users/x/a.plist\n\t}\n}") == nil)
        #expect(LaunchdServiceBinding.servicePlistPath(in: "x = {\n\tpath = /a.plist\n\tpath = /b.plist\n}") == "/a.plist")
        #expect(LaunchdServiceBinding.servicePlistPath(in: "x = {\n\tpath = \n}") == nil)
        #expect(LaunchdServiceBinding.servicePlistPath(in: "") == nil)
    }

    @Test func printArgumentsAddressTheServiceInItsDomain() {
        #expect(LaunchdServiceBinding.printArguments(domain: "gui/501", label: "com.example.agent") == ["print", "gui/501/com.example.agent"])
        #expect(LaunchdServiceBinding.printArguments(domain: "system", label: "com.docker.helper") == ["print", "system/com.docker.helper"])
    }

    @Test func exitCode113MeansNotLoaded() {
        let result = CommandResult(exitCode: 113, stdout: "", stderr: "Could not find service \"x\" in domain for system")
        #expect(LaunchdServiceBinding(printResult: result, plistPath: "/Library/LaunchDaemons/x.plist") == .notLoaded)
    }

    @Test func serviceLoadedFromThisPlist() {
        let result = CommandResult(exitCode: 0, stdout: Self.dockPrint)
        #expect(LaunchdServiceBinding(printResult: result, plistPath: "/System/Library/LaunchAgents/com.apple.Dock.plist") == .loadedFromPlist)
    }

    @Test func serviceLoadedFromAnotherOrNoPlistIsElsewhere() {
        let fromOther = CommandResult(exitCode: 0, stdout: Self.dockPrint)
        #expect(LaunchdServiceBinding(printResult: fromOther, plistPath: "/Users/x/Library/LaunchAgents/com.apple.Dock.agent.plist") == .loadedFromElsewhere)
        let withoutPath = CommandResult(exitCode: 0, stdout: "gui/501/x = {\n\ttype = LaunchAgent\n}\n")
        #expect(LaunchdServiceBinding(printResult: withoutPath, plistPath: "/Users/x/Library/LaunchAgents/x.plist") == .loadedFromElsewhere)
    }

    /// Pfade werden nach Auflösen von Symlinks und `.`-Komponenten verglichen.
    @Test func pathsAreComparedCanonically() throws {
        try ScratchDirectory.with { dir in
            let real = dir.appending(path: "LaunchDaemons")
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: real)
            let link = dir.appending(path: "link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            let viaLink = link.appending(path: "./com.example.daemon.plist").path
            let result = CommandResult(exitCode: 0, stdout: "x = {\n\tpath = \(viaLink)\n}\n")
            #expect(LaunchdServiceBinding(printResult: result, plistPath: plist.path) == .loadedFromPlist)
        }
    }

    /// Jeder andere Exit-Code ist ein gescheiterter Aufruf, kein Zustand.
    @Test(arguments: [Int32(1), 5, 112, 114, 127])
    func otherFailuresYieldNoBinding(exitCode: Int32) {
        let result = CommandResult(exitCode: exitCode, stdout: "\tpath = /a.plist\n", stderr: "boom")
        #expect(LaunchdServiceBinding(printResult: result, plistPath: "/a.plist") == nil)
    }
}
