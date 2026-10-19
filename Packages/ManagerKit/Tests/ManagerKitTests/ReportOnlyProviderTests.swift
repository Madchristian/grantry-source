import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct ReportOnlyProviderTests {
    private static let category = StorageCategory(id: "llm", title: "LLM-Modelle", summary: "", risk: .reportOnly, roots: [])

    @Test func existingPathsAreUnselectableItems() async throws {
        try await ScratchDirectory.withCanonical(prefix: "report-only") { scratch in
            let models = scratch.appending(path: "models")
            try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
            let provider = ReportOnlyProvider(category: Self.category, paths: { [models.path, "/nonexistent-x"] },
                                              measurer: FixedSizeMeasurer([models.path: .bytes(9)]))
            let report = await provider.scan()
            #expect(report.items.map(\.path) == [models.path])
            #expect(report.items.allSatisfy { !$0.isSelectable && $0.size == .bytes(9) })
        }
    }

    @Test func onlyUnreadablePathsNeedFullDiskAccess() async throws {
        try await ScratchDirectory.withCanonical(prefix: "report-only") { scratch in
            let provider = ReportOnlyProvider(category: Self.category, paths: { [scratch.path] },
                                              measurer: FixedSizeMeasurer([scratch.path: .unreadable]))
            #expect(await provider.scan().status == .needsFullDiskAccess)
        }
    }

    @Test func timeMachineListsSnapshotsWithDeleteHint() async throws {
        let runner = MockCommandRunner()
        runner.stub("/usr/bin/tmutil listlocalsnapshots /", CommandResult(exitCode: 0, stdout: """
            Snapshots for disk /:
            com.apple.TimeMachine.2026-10-18-101010.local
            com.apple.TimeMachine.2026-10-18-111111.local
            com.apple.TimeMachine.2026-10-12-121509.local (dataless)
            """))
        let report = await TimeMachineSnapshotsProvider(runner: runner).scan()
        #expect(report.status == .available)
        #expect(report.items.map(\.title) == ["2026-10-18-101010", "2026-10-18-111111", "2026-10-12-121509"])
        #expect(try #require(report.items.first).hint == "sudo tmutil deletelocalsnapshots 2026-10-18-101010")
        #expect(try #require(report.items.last).hint == "sudo tmutil deletelocalsnapshots 2026-10-12-121509")
        #expect(report.items.allSatisfy { !$0.isSelectable })
    }

    @Test func timeMachineHeaderOnlyMeansNoSnapshots() async {
        let runner = MockCommandRunner()
        runner.stub("/usr/bin/tmutil listlocalsnapshots /", CommandResult(exitCode: 0, stdout: "Snapshots for disk /:\n"))
        let report = await TimeMachineSnapshotsProvider(runner: runner).scan()
        #expect(report.status == .available)
        #expect(report.items.isEmpty)
    }

    @Test func timeMachineIgnoresNamesWithUnsafeCharacters() async {
        let runner = MockCommandRunner()
        runner.stub("/usr/bin/tmutil listlocalsnapshots /", CommandResult(exitCode: 0, stdout: """
            com.apple.TimeMachine.2026-10-18;rm.local
            com.apple.TimeMachine..local
            """))
        #expect(await TimeMachineSnapshotsProvider(runner: runner).scan().items.isEmpty)
    }

    @Test func mixedReadableAndUnreadablePathsStayAvailable() async throws {
        try await ScratchDirectory.withCanonical(prefix: "report-only") { scratch in
            let readable = scratch.appending(path: "readable"), locked = scratch.appending(path: "locked")
            for url in [readable, locked] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            let provider = ReportOnlyProvider(
                category: Self.category, paths: { [readable.path, locked.path] },
                measurer: FixedSizeMeasurer([readable.path: .bytes(5), locked.path: .unreadable]))
            let report = await provider.scan()
            #expect(report.status == .available)
            #expect(report.items.map(\.size) == [.bytes(5), .unreadable])
        }
    }

    @Test func timeMachineFailureIsReported() async {
        let report = await TimeMachineSnapshotsProvider(runner: MockCommandRunner()).scan()
        #expect(report.status == .failed("not stubbed: /usr/bin/tmutil listlocalsnapshots /"))
    }

    @Test func timeMachineFailureFallsBackToStdoutThenExitCode() async {
        let withStdout = MockCommandRunner()
        withStdout.stub("/usr/bin/tmutil listlocalsnapshots /", CommandResult(exitCode: 1, stdout: "kein Zugriff\n"))
        #expect(await TimeMachineSnapshotsProvider(runner: withStdout).scan().status == .failed("kein Zugriff"))

        let silent = MockCommandRunner()
        silent.stub("/usr/bin/tmutil listlocalsnapshots /", CommandResult(exitCode: 7, stdout: ""))
        #expect(await TimeMachineSnapshotsProvider(runner: silent).scan().status == .failed("Exit-Code 7"))
    }
}
