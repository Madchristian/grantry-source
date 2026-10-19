import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct PathCategoryProviderTests {
    private func provider(_ roots: [String], risk: StorageRisk = .low, excluded: Set<String> = []) -> PathCategoryProvider {
        PathCategoryProvider(category: StorageCategory(id: "caches", title: "Caches", summary: "", risk: risk, roots: roots),
                             excludedNames: excluded, measurer: FixedSizeMeasurer())
    }

    @Test func childrenBecomeItemsWithRiskBasedRemoval() async throws {
        try await ScratchDirectory.withCanonical(prefix: "path-provider") { scratch in
            for name in ["b", "a", ".hidden", "com.apple.Safari", "Homebrew"] {
                try FileManager.default.createDirectory(at: scratch.appending(path: name), withIntermediateDirectories: true)
            }
            let low = await provider([scratch.path], excluded: ["Homebrew"]).scan()
            #expect(low.items.map(\.title) == ["a", "b"])
            #expect(low.items.allSatisfy { $0.removal == .delete && $0.isPreselected && $0.identity != nil })
            let medium = await provider([scratch.path], risk: .medium).scan()
            #expect(medium.items.allSatisfy { $0.removal == .trash && !$0.isPreselected })
        }
    }

    @Test func symlinkChildrenAreSkipped() async throws {
        try await ScratchDirectory.withCanonical(prefix: "path-provider") { scratch in
            let root = scratch.appending(path: "root")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: scratch)
            #expect(await provider([root.path]).scan().items.isEmpty)
        }
    }

    @Test func entryUsedByARunningBuildIsNamedAndNotPreselected() async throws {
        try await ScratchDirectory.withCanonical(prefix: "path-provider") { scratch in
            let busy = "Busy-abcdefghijklmnopqrstuvwxyzab", idle = "Idle-abcdefghijklmnopqrstuvwxyzab"
            for name in [busy, idle, "ModuleCache.noindex"] {
                try FileManager.default.createDirectory(at: scratch.appending(path: name), withIntermediateDirectories: true)
            }
            let probe = FakeOpenFileProbe([OpenPath(processName: "xcodebuild", path: scratch.path + "/" + busy + "/Build/x.o")])
            let category = StorageCategory(id: "derivedData", title: "DerivedData", summary: "", risk: .low,
                                           roots: [scratch.path], processLock: StorageCatalog.buildLock)
            let items = await PathCategoryProvider(category: category, measurer: FixedSizeMeasurer(), openFiles: probe).scan().items
            #expect(items.map(\.title) == [busy, idle, "ModuleCache.noindex"])
            #expect(items.map(\.isPreselected) == [false, true, false])
            #expect(items.map(\.detail) == ["Wird gerade benutzt von xcodebuild", nil, "Geteilter Cache, xcodebuild läuft"])
            #expect(items.allSatisfy { $0.isSelectable })
        }
    }

    @Test func categoriesWithoutLockingProcessesNeverReadOpenFiles() async throws {
        try await ScratchDirectory.withCanonical(prefix: "path-provider") { scratch in
            try FileManager.default.createDirectory(at: scratch.appending(path: "a"), withIntermediateDirectories: true)
            let probe = FakeOpenFileProbe(nil)
            let category = StorageCategory(id: "caches", title: "Caches", summary: "", risk: .low, roots: [scratch.path])
            let items = await PathCategoryProvider(category: category, measurer: FixedSizeMeasurer(), openFiles: probe).scan().items
            #expect(items.map(\.isPreselected) == [true])
            #expect(probe.callCount == 0)
        }
    }

    @Test func missingRootsAreNotInstalled() async {
        #expect(await provider(["/nonexistent-\(UUID().uuidString)"]).scan().status == .notInstalled)
    }

    @Test func unreadableRootNeedsFullDiskAccess() async throws {
        try await ScratchDirectory.withCanonical(prefix: "path-provider") { scratch in
            let root = scratch.appending(path: "locked")
            try FileManager.default.createDirectory(at: root.appending(path: "x"), withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
            let report = await provider([root.path]).scan()
            #expect(report.status == .needsFullDiskAccess)
            #expect(report.unreadablePaths == [root.path])
        }
    }

    @Test func looseFilesAreItemsButNeverPreselected() async throws {
        try await ScratchDirectory.withCanonical(prefix: "path-provider") { scratch in
            try FileManager.default.createDirectory(at: scratch.appending(path: "folder"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: scratch.appending(path: "INSTALLATION"))
            let items = await provider([scratch.path]).scan().items
            #expect(items.map(\.title) == ["INSTALLATION", "folder"])
            #expect(items.map(\.isPreselected) == [false, true])
            #expect(items.allSatisfy { $0.id == $0.path })
        }
    }

    @Test func readableRootIsAvailableBesideUnreadableRoot() async throws {
        try await ScratchDirectory.withCanonical(prefix: "path-provider") { scratch in
            let locked = scratch.appending(path: "locked"), open = scratch.appending(path: "open")
            try FileManager.default.createDirectory(at: locked.appending(path: "x"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: open.appending(path: "y"), withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
            let report = await provider([locked.path, open.path]).scan()
            #expect(report.status == .available)
            #expect(report.items.map(\.path) == [open.path + "/y"])
        }
    }
}
