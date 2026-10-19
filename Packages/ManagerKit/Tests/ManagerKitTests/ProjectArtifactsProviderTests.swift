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

    private func provider(roots: [String]) -> ProjectArtifactsProvider {
        ProjectArtifactsProvider(roots: roots, minimumAgeDays: 30, now: { Self.now }, measurer: FixedSizeMeasurer())
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
}
