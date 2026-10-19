import Foundation
import GrantryShared
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct SimulatorRuntimesProviderTests {
    private static let listCommand = "/usr/bin/env PATH=/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/xcrun simctl runtime list -j"
    private static let now = Date(timeIntervalSince1970: 1_792_000_000) // 2026-10-15

    /// Gekürzt aus echter Ausgabe (Xcode 27), ergänzt um eine ältere und eine nicht löschbare Laufzeit.
    private static let listing = """
    {
      "7A7E8BB1-BD3E-4C55-A1B9-97C019EA0E9C" : {
        "build" : "24R362", "deletable" : true, "identifier" : "7A7E8BB1-BD3E-4C55-A1B9-97C019EA0E9C",
        "kind" : "Patchable Cryptex Disk Image", "platformIdentifier" : "com.apple.platform.watchsimulator",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.watchOS-27-0", "sizeBytes" : 3814435665,
        "state" : "Ready", "version" : "27.0"
      },
      "7DF402E9-FCB8-4316-9E68-99A206D93E7F" : {
        "build" : "24A434", "deletable" : true, "identifier" : "7DF402E9-FCB8-4316-9E68-99A206D93E7F",
        "lastUsedAt" : "2026-10-14T19:16:59Z", "platformIdentifier" : "com.apple.platform.iphonesimulator",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "sizeBytes" : 8067000161,
        "state" : "Ready", "version" : "27.0"
      },
      "07FA28BC-1161-4943-A2D3-C75840AE789A" : {
        "build" : "23F77", "deletable" : true, "identifier" : "07FA28BC-1161-4943-A2D3-C75840AE789A",
        "lastUsedAt" : "2026-09-15T08:00:00.250Z", "platformIdentifier" : "com.apple.platform.iphonesimulator",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-26-5", "sizeBytes" : 8494282293,
        "state" : "Unusable", "version" : "26.5"
      },
      "all" : {
        "build" : "22A1", "deletable" : true, "identifier" : "all",
        "platformIdentifier" : "com.apple.platform.iphonesimulator",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-9-0", "version" : "9.0"
      },
      "11111111-2222-3333-4444-555555555555" : {
        "build" : "22B1", "deletable" : false, "identifier" : "11111111-2222-3333-4444-555555555555",
        "platformIdentifier" : "com.apple.platform.iphonesimulator",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-18-0", "sizeBytes" : 1000, "version" : "18.0"
      }
    }
    """

    private func provider(_ runner: MockCommandRunner, devices: Bool = true) -> SimulatorRuntimesProvider {
        let locator = ToolLocator(home: "/home", isExecutable: { $0 == "/usr/bin/xcrun" }, isDirectory: { _ in devices })
        return SimulatorRuntimesProvider(requiredPath: "/home/Library/Developer/CoreSimulator/Devices", runner: runner,
                                         locator: locator, now: { Self.now })
    }

    private func deleteCommand(_ identifier: String) -> RemovalMethod {
        .command(CommandSpec.tool("/usr/bin/xcrun", ["simctl", "runtime", "delete", identifier]))
    }

    @Test func listsEachRuntimeNewestFirstPerPlatform() async throws {
        let runner = MockCommandRunner([Self.listCommand: CommandResult(exitCode: 0, stdout: Self.listing)])
        let report = await provider(runner).scan()
        #expect(report.status == .available)
        #expect(report.category.risk == .medium)
        #expect(report.items.map(\.title) == ["iOS 27.0 (24A434)", "iOS 26.5 (23F77)", "iOS 18.0 (22B1)", "iOS 9.0 (22A1)",
                                              "watchOS 27.0 (24R362)"])
        #expect(report.items.allSatisfy { !$0.isPreselected && $0.commandRemovesItem && $0.path == nil })
        let newest = try #require(report.items.first)
        #expect(newest.size == .bytes(8_067_000_161))
        #expect(newest.removal == deleteCommand("7DF402E9-FCB8-4316-9E68-99A206D93E7F"))
        #expect(newest.detail?.hasPrefix("neueste iOS-Laufzeit · Zuletzt benutzt") == true)
        let older = report.items[1]
        #expect(older.detail?.contains("neueste") == false)
        #expect(older.detail?.contains("Zustand: Unusable") == true)
        #expect(older.detail?.contains("Zuletzt benutzt: unbekannt") == false)
        #expect(report.items[4].detail?.hasPrefix("neueste watchOS-Laufzeit") == true)
    }

    @Test func neverOffersNonDeletableRuntimesOrTheAllAlias() async throws {
        let runner = MockCommandRunner([Self.listCommand: CommandResult(exitCode: 0, stdout: Self.listing)])
        let items = await provider(runner).scan().items
        let notDeletable = try #require(items.first { $0.title == "iOS 18.0 (22B1)" })
        #expect(notDeletable.removal == .none && !notDeletable.isSelectable)
        #expect(notDeletable.detail?.hasSuffix("laut simctl nicht löschbar") == true)
        let alias = try #require(items.first { $0.title == "iOS 9.0 (22A1)" })
        #expect(alias.removal == .none && alias.size == .unknown)
    }

    @Test func withoutSimulatorDevicesNothingRuns() async {
        let runner = MockCommandRunner()
        #expect(await provider(runner, devices: false).scan().status == .notInstalled)
        #expect(runner.calls.isEmpty)
    }

    @Test func failingOrUnreadableListingIsAnError() async {
        let failing = MockCommandRunner([Self.listCommand: CommandResult(exitCode: 1, stdout: "", stderr: "boom\nmore")])
        #expect(await provider(failing).scan().status == .failed("simctl: boom"))
        let garbage = MockCommandRunner([Self.listCommand: CommandResult(exitCode: 0, stdout: "not json")])
        #expect(await provider(garbage).scan().status == .failed("Ausgabe von simctl nicht lesbar"))
    }
}
