import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct ProjectArtifactsProviderTests {
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)
    private static let old = now.addingTimeInterval(-40 * 86_400)

    private func project(_ root: URL, _ relative: String, manifest: String, artifact: String, modified: Date) throws {
        let fileManager = FileManager.default
        let folder = root.appending(path: relative)
        try fileManager.createDirectory(at: folder.appending(path: artifact + "/x"), withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: manifest))
        for path in [folder.appending(path: manifest), folder.appending(path: artifact), folder] {
            try fileManager.setAttributes([.modificationDate: modified], ofItemAtPath: path.path)
        }
    }

    private func touch(_ url: URL, _ modified: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private func provider(_ root: URL) -> ProjectArtifactsProvider {
        provider(roots: [root.path])
    }

    private func provider(roots: [String], deepEntryBudget: Int = ProjectArtifactsProvider.deepEntryBudget)
        -> ProjectArtifactsProvider {
        ProjectArtifactsProvider(roots: roots, minimumAgeDays: 30, now: { Self.now }, deepEntryBudget: deepEntryBudget,
                                 measurer: FixedSizeMeasurer())
    }

    /// Legt `relative` mit alten Ordnern an; nur die Datei selbst trägt `modified`.
    private func file(_ root: URL, _ relative: String, modified: Date) throws {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        var folder = url.deletingLastPathComponent()
        while folder.path.count > root.path.count {
            try touch(folder, Self.old)
            folder = folder.deletingLastPathComponent()
        }
        try touch(url, modified)
    }

    @Test func findsArtifactsOfStaleProjectsOnly() async throws {
        try await ScratchDirectory.withCanonical(prefix: "projects") { root in
            try project(root, "Old", manifest: "Package.swift", artifact: ".build", modified: Self.old)
            try project(root, "web/Site", manifest: "package.json", artifact: "node_modules", modified: Self.old)
            try project(root, "Fresh", manifest: "Package.swift", artifact: ".build", modified: Self.now)
            let titles = await provider(root).scan().items.map(\.title)
            #expect(titles.sorted() == ["Old/.build", "web/Site/node_modules"])
        }
    }

    @Test func artifactWithoutManifestIsIgnored() async throws {
        try await ScratchDirectory.withCanonical(prefix: "projects") { root in
            try FileManager.default.createDirectory(at: root.appending(path: "Loose/node_modules"), withIntermediateDirectories: true)
            #expect(await provider(root).scan().items.isEmpty)
        }
    }

    @Test func searchStopsBelowMaximumDepth() async throws {
        try await ScratchDirectory.withCanonical(prefix: "projects") { root in
            try project(root, "a/b/c/d/e", manifest: "Package.swift", artifact: ".build", modified: Self.old)
            try project(root, "a/b/c/d", manifest: "Package.swift", artifact: ".build", modified: Self.old)
            #expect(await provider(root).scan().items.map(\.title) == ["a/b/c/d/.build"])
        }
    }

    @Test func doesNotDescendIntoArtifactsOrSymlinks() async throws {
        try await ScratchDirectory.withCanonical(prefix: "projects") { root in
            try project(root, "App", manifest: "package.json", artifact: "node_modules", modified: Self.old)
            try project(root, "App/node_modules/dep", manifest: "package.json", artifact: "node_modules", modified: Self.old)
            try FileManager.default.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: root.appending(path: "App"))
            #expect(await provider(root).scan().items.map(\.title) == ["App/node_modules"])
        }
    }

    @Test func itemsGoToTrashAndAreNotPreselected() async throws {
        try await ScratchDirectory.withCanonical(prefix: "projects") { root in
            try project(root, "Old", manifest: "Package.swift", artifact: ".build", modified: Self.old)
            let item = try #require(await provider(root).scan().items.first)
            #expect(item.removal == .trash && !item.isPreselected && item.identity != nil)
        }
    }

    @Test func recentlyModifiedArtifactFolderKeepsProjectFresh() async throws {
        try await ScratchDirectory.withCanonical(prefix: "projects") { root in
            try project(root, "Nested", manifest: "Package.swift", artifact: ".build", modified: Self.old)
            try touch(root.appending(path: "Nested/.build"), Self.now)
            #expect(await provider(root).scan().items.isEmpty)
        }
    }

    @Test func recentlyModifiedEntryInsideArtifactKeepsProjectFresh() async throws {
        try await ScratchDirectory.withCanonical(prefix: "projects") { root in
            try project(root, "Nested", manifest: "package.json", artifact: "node_modules", modified: Self.old)
            try touch(root.appending(path: "Nested/node_modules/x"), Self.now)
            #expect(await provider(root).scan().items.isEmpty)
        }
    }

    @Test func recentActivityOfSiblingArtifactKeepsProjectFresh() async throws {
        try await ScratchDirectory.withCanonical(prefix: "projects") { root in
            try project(root, "Both", manifest: "Package.swift", artifact: ".build", modified: Self.old)
            try project(root, "Both", manifest: "package.json", artifact: "node_modules", modified: Self.old)
            try touch(root.appending(path: "Both/node_modules"), Self.now)
            #expect(await provider(root).scan().items.isEmpty)
        }
    }

    @Test func overlappingRootsReportEachArtifactOnce() async throws {
        try await ScratchDirectory.withCanonical(prefix: "projects") { root in
            try project(root, "work/Old", manifest: "Package.swift", artifact: ".build", modified: Self.old)
            let provider = provider(roots: [root.path, root.appending(path: "work").path, root.path])
            #expect(await provider.scan().items.map(\.title) == ["work/Old/.build"])
            #expect(provider.category.roots == [root.path])
        }
    }

    @Test func trailingSlashOfRootDoesNotBreakTitles() async throws {
        try await ScratchDirectory.withCanonical(prefix: "projects") { root in
            try project(root, "Old", manifest: "Package.swift", artifact: ".build", modified: Self.old)
            let provider = provider(roots: [root.path + "/"])
            #expect(await provider.scan().items.map(\.title) == ["Old/.build"])
            #expect(provider.category.roots == [root.path])
        }
    }

    @Test func deepChangeWithoutBuildOrCommitKeepsProjectFresh() async throws {
        // #220: Nur eine tief liegende Quelldatei wurde bearbeitet; Ordner und direkte Einträge sind alt.
        try await ScratchDirectory.withCanonical(prefix: "projects") { root in
            try project(root, "Edited", manifest: "Package.swift", artifact: ".build", modified: Self.old)
            try file(root, "Edited/Sources/Feature/Deep/File.swift", modified: Self.now)
            try project(root, "Old", manifest: "Package.swift", artifact: ".build", modified: Self.old)
            try file(root, "Old/Sources/Feature/Deep/File.swift", modified: Self.old)
            #expect(await provider(root).scan().items.map(\.title) == ["Old/.build"])
        }
    }

    @Test func recentGitIndexOrHeadKeepsProjectFresh() async throws {
        try await ScratchDirectory.withCanonical(prefix: "projects") { root in
            for (name, marker) in [("Staged", ".git/index"), ("Switched", ".git/HEAD")] {
                try project(root, name, manifest: "package.json", artifact: "node_modules", modified: Self.old)
                try file(root, name + "/" + marker, modified: Self.now)
                try touch(root.appending(path: name + "/.git"), Self.old)
                try touch(root.appending(path: name), Self.old)
            }
            #expect(await provider(root).scan().items.isEmpty)
        }
    }

    @Test func recentGitMarkersOfLinkedWorktreeKeepProjectFresh() async throws {
        // #250: In einem verknüpften Worktree ist `.git` eine Datei; HEAD und Index liegen im Git-Ordner des Worktrees.
        try await ScratchDirectory.withCanonical(prefix: "projects") { root in
            let cases = [("Staged", "index", root.path + "/main/.git/worktrees/staged"),
                         ("Switched", "HEAD", "../main/.git/worktrees/switched"),
                         ("Old", "HEAD", root.path + "/main/.git/worktrees/old")]
            for (name, marker, gitDirectory) in cases {
                let worktreeGitDirectory = gitDirectory.hasPrefix("/") ? gitDirectory : root.path + "/" + name + "/" + gitDirectory
                try project(root, name, manifest: "package.json", artifact: "node_modules", modified: Self.old)
                try Data("gitdir: \(gitDirectory)\n".utf8).write(to: root.appending(path: name + "/.git"))
                try touch(root.appending(path: name + "/.git"), Self.old)
                try touch(root.appending(path: name), Self.old)
                try FileManager.default.createDirectory(atPath: worktreeGitDirectory, withIntermediateDirectories: true)
                try Data().write(to: URL(filePath: worktreeGitDirectory + "/" + marker))
                try touch(URL(filePath: worktreeGitDirectory + "/" + marker), name == "Old" ? Self.old : Self.now)
            }
            try touch(root.appending(path: "main"), Self.old)
            #expect(await provider(root).scan().items.map(\.title) == ["Old/node_modules"])
        }
    }

    @Test func deepWalkIgnoresSymlinkTargetsHiddenFoldersAndNestedArtifacts() async throws {
        try await ScratchDirectory.withCanonical(prefix: "projects") { root in
            try file(root, "elsewhere/new.txt", modified: Self.now)
            try project(root, "Old", manifest: "Package.swift", artifact: ".build", modified: Self.old)
            try FileManager.default.createDirectory(at: root.appending(path: "Old/Sources"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: root.appending(path: "Old/Sources/link"),
                                                       withDestinationURL: root.appending(path: "elsewhere"))
            try touch(root.appending(path: "Old/Sources"), Self.old)
            try file(root, "Old/.swiftpm/deep/state.json", modified: Self.now)
            try file(root, "Old/Packages/Lib/node_modules/dep/index.js", modified: Self.now)
            try touch(root.appending(path: "Old"), Self.old)
            #expect(await provider(roots: [root.appending(path: "Old").path]).scan().items.map(\.title) == [".build"])
        }
    }

    @Test func projectBeyondTheEntryBudgetCountsAsUsed() async throws {
        // Im Zweifel nicht anbieten: Ein Projekt, dessen Einträge das Budget übersteigen, gilt als benutzt.
        try await ScratchDirectory.withCanonical(prefix: "projects") { root in
            try project(root, "Big", manifest: "Package.swift", artifact: ".build", modified: Self.old)
            for index in 0..<4 { try file(root, "Big/Sources/A/file\(index).swift", modified: Self.old) }
            try touch(root.appending(path: "Big"), Self.old)
            #expect(await provider(roots: [root.path], deepEntryBudget: 3).scan().items.isEmpty)
            #expect(await provider(roots: [root.path], deepEntryBudget: 6).scan().items.map(\.title) == ["Big/.build"])
        }
    }
}
