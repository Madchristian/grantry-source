import Foundation
import Testing
import TestSupport
@testable import ManagerKit

/// Nur temporäre Fixture-Ordner; echte Orca-Worktrees werden nie angefasst (#255).
@Suite struct OrcaWorktreesProviderTests {
    private func withWorkspaces(_ body: (URL, URL) async throws -> Void) async throws {
        try await ScratchDirectory.withCanonical(prefix: "orca-worktrees") { scratch in
            try await body(scratch.appending(path: "orca/workspaces"), scratch.appending(path: "repo/.git"))
        }
    }

    /// Verknüpfter Worktree wie von `git worktree add`: `.git` ist eine Datei mit `gitdir: <Pfad>`, dort steht `HEAD`.
    @discardableResult
    private func worktree(_ folder: URL, gitDirectory: URL, gitdirLine: String? = nil, head: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try Data("gitdir: \(gitdirLine ?? gitDirectory.path)\n".utf8).write(to: folder.appending(path: ".git"))
        try Data(head.utf8).write(to: gitDirectory.appending(path: "HEAD"))
        try Data("x".utf8).write(to: folder.appending(path: "README.md"))
        return folder
    }

    private func provider(_ workspaces: URL,
                          measurer: any FileSizeMeasuring = FixedSizeMeasurer()) -> OrcaWorktreesProvider {
        OrcaWorktreesProvider(workspaceRoot: workspaces.path, measurer: measurer)
    }

    @Test func listsNestedAndFlatWorktreesWithBranchAsReportOnly() async throws {
        try await withWorkspaces { workspaces, git in
            let nested = try worktree(workspaces.appending(path: "grantry/feature-x"),
                                      gitDirectory: git.appending(path: "worktrees/feature-x"),
                                      head: "ref: refs/heads/Madchristian/feature-x\n")
            let flat = try worktree(workspaces.appending(path: "hotfix"), gitDirectory: git.appending(path: "worktrees/hotfix"),
                                    head: "0123456789abcdef0123456789abcdef01234567\n")
            let report = await provider(workspaces, measurer: FixedSizeMeasurer([nested.path: .bytes(7)])).scan()
            #expect(report.status == .available)
            #expect(report.category.id == OrcaWorktreesProvider.categoryID)
            #expect(report.category.risk == .reportOnly)
            #expect(report.items.map(\.title) == ["grantry – feature-x", "hotfix"])
            #expect(report.items.map(\.path) == [nested.path, flat.path])
            #expect(report.items.allSatisfy { !$0.isSelectable && !$0.isPreselected && $0.hint == nil })
            #expect(report.items.first?.size == .bytes(7))
            #expect(report.items.map(\.detail) == [
                "Branch Madchristian/feature-x, zuletzt geändert: nicht vollständig geprüft",
                "Losgelöster HEAD, zuletzt geändert: nicht vollständig geprüft",
            ])
        }
    }

    /// Ein relativer `gitdir` gilt ab dem Worktree; die jüngste Änderung kommt aus der echten Zählung.
    @Test func relativeGitDirectoryAndNewestChange() async throws {
        try await withWorkspaces { workspaces, git in
            let folder = workspaces.appending(path: "grantry/relative")
            try worktree(folder, gitDirectory: git.appending(path: "worktrees/relative"),
                         gitdirLine: "../../../../repo/.git/worktrees/relative", head: "ref: refs/heads/main\n")
            let item = try #require(await provider(workspaces, measurer: FileSizeCalculator()).scan().items.first)
            #expect(item.detail?.hasPrefix("Branch main, zuletzt geändert am ") == true)
            #expect((item.size.bytes ?? 0) > 0)
        }
    }

    /// Nur verknüpfte Worktrees: kein Hauptklon (`.git`-Ordner), kein Ordner ohne `.git`, nichts Verstecktes, keine
    /// Symlinks, keine `.git`-Datei ohne `gitdir:`. Unlesbarer `HEAD` bleibt ehrlich offen.
    @Test func ignoresEverythingButLinkedWorktrees() async throws {
        try await withWorkspaces { workspaces, git in
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: workspaces.appending(path: "grantry/main-clone/.git"),
                                            withIntermediateDirectories: true)
            try fileManager.createDirectory(at: workspaces.appending(path: "grantry/plain"), withIntermediateDirectories: true)
            try worktree(workspaces.appending(path: ".hidden"), gitDirectory: git.appending(path: "worktrees/hidden"),
                         head: "ref: refs/heads/hidden\n")
            let bogus = workspaces.appending(path: "bogus")
            try fileManager.createDirectory(at: bogus, withIntermediateDirectories: true)
            try Data("nonsense\n".utf8).write(to: bogus.appending(path: ".git"))
            let real = try worktree(workspaces.appending(path: "grantry/real"), gitDirectory: git.appending(path: "worktrees/real"),
                                    head: "ref: refs/heads/real\n")
            try fileManager.createSymbolicLink(at: workspaces.appending(path: "grantry/linked"), withDestinationURL: real)
            try fileManager.removeItem(at: git.appending(path: "worktrees/real/HEAD"))
            let items = await provider(workspaces).scan().items
            #expect(items.map(\.title) == ["grantry – real"])
            #expect(items.first?.detail == "Branch unbekannt, zuletzt geändert: nicht vollständig geprüft")
        }
    }

    @Test func missingWorkspaceFolderIsNotInstalled() async throws {
        try await withWorkspaces { workspaces, _ in
            let report = await provider(workspaces).scan()
            #expect(report.status == .notInstalled)
            #expect(report.items.isEmpty)
        }
    }
}
