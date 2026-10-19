import Foundation
import GrantryShared
import Testing
import TestSupport
@testable import ManagerKit

/// Wirft beim Ausführen einen festen Fehler; `cancelsTask` bricht vorher den laufenden Task ab (wie ein Abbruch
/// während des Befehls).
private struct ThrowingCommandRunner: CommandRunning {
    let error: any Error
    var cancelsTask = false

    func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> CommandResult {
        if cancelsTask { withUnsafeCurrentTask { $0?.cancel() } }
        throw error
    }
}

@Suite struct StorageRemoverTests {
    private struct Fixture {
        let scratch: URL
        let root: URL
        let remover: StorageRemover
        let trash: RecordingTrash
        let runner: MockCommandRunner
        let measurer: FixedSizeMeasurer
    }

    private func withFixture(runner custom: (any CommandRunning)? = nil, openFiles: any OpenFileProbing = FakeOpenFileProbe(),
                             _ body: (Fixture) async throws -> Void) async throws {
        try await ScratchDirectory.withCanonical(prefix: "storage-remover") { scratch in
            let root = scratch.appending(path: "root")
            let bin = scratch.appending(path: "bin")
            for folder in [root, bin] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            let trash = RecordingTrash(destination: bin)
            let runner = MockCommandRunner()
            let measurer = FixedSizeMeasurer()
            let remover = StorageRemover(pathGuard: StoragePathGuard(layout: LibraryLayout(home: scratch.path, systemRoot: scratch.path)),
                                         trash: trash, runner: custom ?? runner, measurer: measurer, openFiles: openFiles)
            try await body(Fixture(scratch: scratch, root: root, remover: remover, trash: trash, runner: runner,
                                   measurer: measurer))
        }
    }

    private func category(_ risk: StorageRisk, _ root: URL) -> StorageCategory {
        StorageCategory(id: "c", title: "C", summary: "", risk: risk, roots: [root.path])
    }

    private func entry(_ root: URL, _ name: String, _ removal: RemovalMethod,
                       size: FileSize = .bytes(100)) throws -> StorageItem {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return StorageItem(id: url.path, title: name, path: url.path, size: size, removal: removal,
                           isPreselected: true, identity: FileIdentity.of(url.path))
    }

    private func command(_ spec: CommandSpec) -> StorageItem {
        StorageItem(id: "command:c", title: "cmd", path: nil, size: .unknown, removal: .command(spec), isPreselected: true)
    }

    @Test func deletesLowRiskEntry() async throws {
        try await withFixture { fixture in
            let item = try entry(fixture.root, "a", .delete)
            let outcomes = await fixture.remover.clean([item], in: category(.low, fixture.root))
            #expect(outcomes == [StorageCleanOutcome(categoryID: "c", target: item.path!, method: .delete, freedBytes: 100, result: .removed)])
            #expect(!FileManager.default.fileExists(atPath: item.path!))
        }
    }

    @Test func refusesPermanentDeleteAboveLowRisk() async throws {
        try await withFixture { fixture in
            let item = try entry(fixture.root, "a", .delete)
            let outcome = try #require(await fixture.remover.clean([item], in: category(.medium, fixture.root)).first)
            #expect(outcome.result == .skipped("Endgültiges Löschen nur bei geringem Risiko"))
            #expect(FileManager.default.fileExists(atPath: item.path!))
        }
    }

    @Test func refusesDeleteOutsideCategoryRoots() async throws {
        try await withFixture { fixture in
            let other = fixture.scratch.appending(path: "other")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            let item = try entry(other, "a", .delete)
            let outcome = try #require(await fixture.remover.clean([item], in: category(.low, fixture.root)).first)
            #expect(outcome.result == .skipped("Außerhalb der erlaubten Orte"))
            #expect(FileManager.default.fileExists(atPath: item.path!))
        }
    }

    @Test func skipsEntryABuildIsUsingRightBeforeDeleting() async throws {
        try await withFixture { fixture in
            // Der Build-Pfad steht erst mit dem Fixture fest; daher ein eigener Remover mit passender Probe.
            let busy = try entry(fixture.root, "App-busy", .delete), idle = try entry(fixture.root, "App-idle", .delete)
            let locked = FakeOpenFileProbe([OpenPath(processName: "SWBBuildService", path: busy.path! + "/build.db")])
            let remover = StorageRemover(pathGuard: fixture.remover.pathGuard, trash: fixture.trash, runner: fixture.runner,
                                         measurer: fixture.measurer, openFiles: locked)
            let category = StorageCategory(id: "c", title: "C", summary: "", risk: .low, roots: [fixture.root.path],
                                           processLock: ProcessLock(processes: ["SWBBuildService"]))
            let outcomes = await remover.clean([busy, idle], in: category)
            #expect(outcomes.map(\.result) == [.skipped("Wird gerade benutzt von SWBBuildService"), .removed])
            #expect(FileManager.default.fileExists(atPath: busy.path!))
            #expect(!FileManager.default.fileExists(atPath: idle.path!))
        }
    }

    @Test func sharedCacheIsSkippedWhileABuildRuns() async throws {
        try await withFixture(openFiles: FakeOpenFileProbe([], running: ["SWBBuildService"])) { fixture in
            let cache = try entry(fixture.root, "ModuleCache.noindex", .delete)
            let category = StorageCategory(id: "derivedData", title: "D", summary: "", risk: .low, roots: [fixture.root.path],
                                           processLock: StorageCatalog.buildLock)
            let outcome = try #require(await fixture.remover.clean([cache], in: category).first)
            #expect(outcome.result == .skipped("Geteilter Cache, SWBBuildService läuft"))
            #expect(FileManager.default.fileExists(atPath: cache.path!))
        }
    }

    @Test func unreadableProcessListBlocksLockedCategoriesOnly() async throws {
        try await withFixture(openFiles: FakeOpenFileProbe(nil)) { fixture in
            let locked = try entry(fixture.root, "locked", .delete), free = try entry(fixture.root, "free", .delete)
            let lockedCategory = StorageCategory(id: "c", title: "C", summary: "", risk: .low, roots: [fixture.root.path],
                                                 processLock: ProcessLock(processes: ["xcodebuild"]))
            let lockedOutcome = try #require(await fixture.remover.clean([locked], in: lockedCategory).first)
            #expect(lockedOutcome.result == .skipped("Nicht prüfbar, ob ein Prozess den Ordner benutzt"))
            let freeOutcome = try #require(await fixture.remover.clean([free], in: category(.low, fixture.root)).first)
            #expect(freeOutcome.result == .removed)
        }
    }

    @Test func trashesMediumRiskEntry() async throws {
        try await withFixture { fixture in
            let item = try entry(fixture.root, "a", .trash)
            let outcome = try #require(await fixture.remover.clean([item], in: category(.medium, fixture.root)).first)
            #expect(outcome.result == .removed && outcome.method == .trash)
            #expect(fixture.trash.movedPaths == [item.path!])
        }
    }

    @Test func skipsEntryChangedSinceScanAndContinues() async throws {
        try await withFixture { fixture in
            let changed = try entry(fixture.root, "changed", .delete)
            try FileManager.default.removeItem(atPath: changed.path!)
            try FileManager.default.createDirectory(atPath: changed.path!, withIntermediateDirectories: true)
            let other = try entry(fixture.root, "other", .delete)
            let outcomes = await fixture.remover.clean([changed, other], in: category(.low, fixture.root))
            #expect(outcomes.map(\.result) == [.skipped("Geändert seit Scan"), .removed])
            #expect(FileManager.default.fileExists(atPath: changed.path!))
        }
    }

    @Test func commandReportsFreedBytesFromBeforeAndAfter() async throws {
        try await withFixture { fixture in
            let spec = CommandSpec(executable: "/opt/homebrew/bin/uv", arguments: ["cache", "prune"])
            fixture.runner.stub(spec.commandLine, CommandResult(exitCode: 0, stdout: ""))
            fixture.measurer.set(.bytes(1_000), for: "/m")
            let item = StorageItem(id: "command:c", title: "uv cache prune", path: "/m", size: .bytes(1_000),
                                   removal: .command(spec), isPreselected: true)
            let measurer = fixture.measurer
            let outcomes = await fixture.remover.clean([item], in: category(.low, fixture.root)) {
                measurer.set(.bytes(400), for: "/m")
            }
            #expect(outcomes == [StorageCleanOutcome(categoryID: "c", target: spec.commandLine, method: .command,
                                                     freedBytes: 600, result: .removed)])
        }
    }

    @Test func failingCommandReportsExitCodeAndStderrTail() async throws {
        try await withFixture { fixture in
            let spec = CommandSpec(executable: "/usr/local/bin/docker", arguments: ["system", "prune", "-f"])
            fixture.runner.stub(spec.commandLine, CommandResult(exitCode: 1, stdout: "", stderr: "a\nb\nc\nd\ne\nf\ng\n"))
            let item = StorageItem(id: "command:c", title: "docker", path: nil, size: .unknown, removal: .command(spec),
                                   isPreselected: false)
            let outcome = try #require(await fixture.remover.clean([item], in: category(.medium, fixture.root)).first)
            #expect(outcome.result == .failed("Exit 1: c\nd\ne\nf\ng"))
            #expect(outcome.freedBytes == nil)
        }
    }

    @Test func reportOnlyItemIsNeverTouched() async throws {
        try await withFixture { fixture in
            let item = try entry(fixture.root, "a", .none)
            let outcome = try #require(await fixture.remover.clean([item], in: category(.reportOnly, fixture.root)).first)
            #expect(outcome.result == .skipped("Nur Bericht"))
            #expect(FileManager.default.fileExists(atPath: item.path!))
        }
    }

    @Test func reportOnlyCategoryNeverRemovesEvenWithRemovalMethod() async throws {
        try await withFixture { fixture in
            let item = try entry(fixture.root, "a", .trash)
            let outcome = try #require(await fixture.remover.clean([item], in: category(.reportOnly, fixture.root)).first)
            #expect(outcome.result == .skipped("Nur Bericht") && outcome.method == .trash)
            #expect(fixture.trash.movedPaths.isEmpty)
            #expect(FileManager.default.fileExists(atPath: item.path!))
        }
    }

    @Test func trashOutcomesAreReportedPerEntry() async throws {
        try await withFixture { fixture in
            let blocked = try entry(fixture.root, "blocked", .trash)
            let remaining = try entry(fixture.root, "remaining", .trash)
            let missing = try entry(fixture.root, "missing", .trash)
            let silent = try entry(fixture.root, "silent", .trash)
            fixture.trash.force(.outcome(.blocked("Geschützter Ort")), for: blocked.path!)
            fixture.trash.force(.outcome(.remaining("Noch vorhanden")), for: remaining.path!)
            fixture.trash.force(.missing(failure: "Finder antwortet nicht"), for: missing.path!)
            fixture.trash.force(.missing(failure: nil), for: silent.path!)
            let outcomes = await fixture.remover.clean([blocked, remaining, missing, silent], in: category(.medium, fixture.root))
            #expect(outcomes.map(\.result) == [.skipped("Geschützter Ort"), .failed("Noch vorhanden"),
                                               .failed("Finder antwortet nicht"), .failed("Kein Ergebnis vom Finder")])
            #expect(outcomes.allSatisfy { $0.freedBytes == nil && $0.method == .trash })
        }
    }

    @Test func recreatedEntryCountsAsRemovedWithoutFreedBytes() async throws {
        try await withFixture { fixture in
            let item = try entry(fixture.root, "a", .trash)
            fixture.trash.force(.outcome(.recreated), for: item.path!)
            let outcome = try #require(await fixture.remover.clean([item], in: category(.medium, fixture.root)).first)
            #expect(outcome.result == .removed)
            #expect(outcome.freedBytes == nil)
        }
    }

    @Test func unknownSizeReportsNoFreedBytes() async throws {
        try await withFixture { fixture in
            let item = try entry(fixture.root, "a", .delete, size: .unknown)
            let outcome = try #require(await fixture.remover.clean([item], in: category(.low, fixture.root)).first)
            #expect(outcome.result == .removed)
            #expect(outcome.freedBytes == nil)
        }
    }

    @Test func deleteWithoutPathIsSkipped() async throws {
        try await withFixture { fixture in
            let item = StorageItem(id: "x", title: "x", path: nil, size: .bytes(1), removal: .delete, isPreselected: true)
            let outcome = try #require(await fixture.remover.clean([item], in: category(.low, fixture.root)).first)
            #expect(outcome == StorageCleanOutcome(categoryID: "c", target: "x", method: .delete, freedBytes: nil,
                                                   result: .skipped("Kein Pfad")))
        }
    }

    @Test func timedOutCommandReportsTimeout() async throws {
        let runner = ThrowingCommandRunner(error: CommandError.timedOut(executable: "/usr/bin/true", seconds: 600))
        try await withFixture(runner: runner) { fixture in
            let spec = CommandSpec(executable: "/usr/bin/true", arguments: [])
            let outcome = try #require(await fixture.remover.clean([command(spec)], in: category(.low, fixture.root)).first)
            #expect(outcome.result == .failed("Zeitüberschreitung"))
            #expect(outcome.target == spec.commandLine)
        }
    }

    @Test func cancellationSkipsCurrentAndRemainingEntries() async throws {
        let runner = ThrowingCommandRunner(error: CancellationError(), cancelsTask: true)
        try await withFixture(runner: runner) { fixture in
            let spec = CommandSpec(executable: "/usr/bin/true", arguments: [])
            let later = try entry(fixture.root, "later", .delete)
            let remover = fixture.remover
            let low = category(.low, fixture.root)
            let outcomes = await Task { await remover.clean([command(spec), later], in: low) }.value
            #expect(outcomes.map(\.result) == [.skipped("Abgebrochen"), .skipped("Abgebrochen")])
            #expect(outcomes.map(\.target) == [spec.commandLine, later.path!])
            #expect(FileManager.default.fileExists(atPath: later.path!))
        }
    }
}
