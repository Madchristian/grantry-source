import Testing
import Foundation
@testable import ManagerKit

@Suite struct LaunchdPlistTests {
    private func plist(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    private func binaryPlist(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
    }

    @Test func decodesProgramArgumentsAndAssociatedBundleArray() throws {
        let data = try plist([
            "Label": "com.docker.helper",
            "ProgramArguments": ["/Applications/Docker.app/Contents/MacOS/helper", "--run"],
            "AssociatedBundleIdentifiers": ["com.docker.docker"],
        ])
        let decoded = try LaunchdPlist.decode(data)
        #expect(decoded.label == "com.docker.helper")
        #expect(decoded.executable == "/Applications/Docker.app/Contents/MacOS/helper")
        #expect(decoded.associatedBundleIdentifiers == ["com.docker.docker"])
        #expect(decoded.disabled == false)
    }

    @Test func prefersProgramAndAcceptsSingleAssociatedBundleString() throws {
        let data = try plist([
            "Label": "a", "Program": "/usr/local/bin/a", "ProgramArguments": ["ignored"],
            "AssociatedBundleIdentifiers": "com.a", "Disabled": true,
        ])
        let decoded = try LaunchdPlist.decode(data)
        #expect(decoded.executable == "/usr/local/bin/a")
        #expect(decoded.associatedBundleIdentifiers == ["com.a"])
        #expect(decoded.disabled)
    }

    /// Ein eigener `PATH` in `EnvironmentVariables` ändert, was `env` findet. Ein unlesbares Dictionary gilt im Zweifel
    /// ebenfalls als eigener `PATH`.
    @Test func detectsPathOverride() throws {
        let cases: [(variables: Any?, expected: Bool)] = [
            (nil, false),
            (["LANG": "C"], false),
            (["PATH": "/Users/x/.bin:/usr/bin"], true),
            (["PATH": "/usr/bin", "N": 1] as [String: Any], true),
            ("PATH=/Users/x", true),
        ]
        for (variables, expected) in cases {
            var dict: [String: Any] = ["Label": "x"]
            dict["EnvironmentVariables"] = variables
            #expect(try LaunchdPlist.decode(plist(dict)).overridesPath == expected, "\(String(describing: variables))")
        }
    }

    /// Ein Interpreter mit Argumenten führt fremden Code aus; ohne Argumente (oder ein anderes Programm) nicht.
    private static let interpreterCases: [(arguments: [String], expected: Bool)] = [
        (["/bin/sh", "-c", "~/Library/.x/evil"], true),
        (["/bin/zsh", "/Users/x/run.zsh"], true),
        (["bash", "-c", "x"], true),
        (["/usr/bin/osascript", "-e", "x"], true),
        (["/usr/bin/python3", "x.py"], true),
        (["/opt/homebrew/bin/python3.12", "x.py"], true),
        (["/usr/bin/perl", "x.pl"], true),
        (["/usr/bin/ruby", "x.rb"], true),
        (["/usr/bin/curl", "-s", "https://example.com"], true),
        (["/usr/bin/env", "node", "server.js"], true),
        (["/bin/SH", "-c", "x"], true),
        (["/bin/sh"], false),
        (["/usr/local/bin/shellcheck", "x"], false),
        (["/usr/libexec/sharingd", "x"], false),
        (["/Applications/Foo.app/Contents/MacOS/foo", "--agent"], false),
    ]

    @Test(arguments: interpreterCases)
    func detectsInterpreterLaunches(arguments: [String], expected: Bool) {
        let plist = LaunchdPlist(label: "x", program: nil, programArguments: arguments, disabled: false, associatedBundleIdentifiers: [])
        #expect(plist.launchesInterpreter == expected, "\(arguments)")
    }

    /// `Program` ist das Programm, `ProgramArguments` dann `argv` einschließlich `argv[0]`.
    @Test func interpreterViaProgramKeyNeedsFurtherArguments() {
        let withScript = LaunchdPlist(label: "x", program: "/bin/sh", programArguments: ["sh", "-c", "x"], disabled: false,
                                      associatedBundleIdentifiers: [])
        let alone = LaunchdPlist(label: "x", program: "/bin/sh", programArguments: nil, disabled: false, associatedBundleIdentifiers: [])
        #expect(withScript.launchesInterpreter)
        #expect(!alone.launchesInterpreter)
    }

    @Test func owningAppBundleIsDerivedFromExecutablePath() {
        let item = LaunchdPlist(label: "x", program: "/Applications/Foo.app/Contents/Library/LoginItems/Bar.app/Contents/MacOS/Bar", programArguments: nil, disabled: false, associatedBundleIdentifiers: [])
        #expect(item.owningAppBundlePath == "/Applications/Foo.app")
    }

    @Test func decodesSessionTypesFromStringOrArray() throws {
        #expect(try LaunchdPlist.decode(plist(["Label": "a", "LimitLoadToSessionType": "Background"])).sessionTypes == ["Background"])
        let array = try LaunchdPlist.decode(plist(["Label": "b", "LimitLoadToSessionType": ["Aqua", "LoginWindow"]]))
        #expect(array.sessionTypes == ["Aqua", "LoginWindow"])
    }

    @Test func missingOrMalformedSessionTypesAreNil() throws {
        #expect(try LaunchdPlist.decode(plist(["Label": "a"])).sessionTypes == nil)
        #expect(try LaunchdPlist.decode(plist(["Label": "b", "LimitLoadToSessionType": 3])).sessionTypes == nil)
    }

    @Test func rejectsPlistWithoutLabel() throws {
        #expect(throws: DecodingError.self) { try LaunchdPlist.decode(try plist(["Program": "/x"])) }
    }

    /// Realer Fall: `/System/Library/LaunchDaemons/com.apple.usbaudiod.plist` trägt `Disabled` als
    /// Bedingungs-Dictionary (`{"#IfFeatureFlagDisabled…": …, "#Then": true}`) statt als Bool. Nur `Label`
    /// bleibt Pflicht – ein falscher Typ in `Disabled`, `Program` oder `ProgramArguments` darf den ganzen
    /// Eintrag nicht zu Fall bringen.
    @Test func toleratesUnexpectedTypeInDisabledField() throws {
        let data = try plist([
            "Label": "com.apple.usbaudiod",
            "Program": "/usr/libexec/usbaudiod",
            "Disabled": ["#Then": true],
        ])
        let decoded = try LaunchdPlist.decode(data)
        #expect(decoded.label == "com.apple.usbaudiod")
        #expect(decoded.executable == "/usr/libexec/usbaudiod")
        #expect(decoded.disabled == false)
    }

    @Test func decodesBinaryFormatPlist() throws {
        let data = try binaryPlist(["Label": "com.apple.binary", "Program": "/usr/bin/true"])
        let decoded = try LaunchdPlist.decode(data)
        #expect(decoded.label == "com.apple.binary")
        #expect(decoded.executable == "/usr/bin/true")
    }

    @Test func emptyProgramArgumentsYieldsNoExecutable() throws {
        let data = try plist(["Label": "x", "ProgramArguments": []])
        let decoded = try LaunchdPlist.decode(data)
        #expect(decoded.executable == nil)
    }

    @Test func owningAppBundleIsNilWithoutProperAppSuffix() {
        let backupPath = LaunchdPlist(
            label: "a", program: "/Users/x/My.app.backup/bin/tool", programArguments: nil,
            disabled: false, associatedBundleIdentifiers: []
        )
        #expect(backupPath.owningAppBundlePath == nil)

        let appexPath = LaunchdPlist(
            label: "b", program: "/System/Library/ExtensionKit/Extensions/Foo.appex/Contents/MacOS/Foo",
            programArguments: nil, disabled: false, associatedBundleIdentifiers: []
        )
        #expect(appexPath.owningAppBundlePath == nil)

        let plainPath = LaunchdPlist(
            label: "c", program: "/usr/libexec/foo", programArguments: nil, disabled: false,
            associatedBundleIdentifiers: []
        )
        #expect(plainPath.owningAppBundlePath == nil)
    }
}
