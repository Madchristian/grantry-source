import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct DownloadedInstallersProviderTests {
    private static let now = Date(timeIntervalSince1970: 1_792_000_000)

    private func provider(_ root: URL, measurer: FixedSizeMeasurer = FixedSizeMeasurer(otherwise: .bytes(1)))
        -> DownloadedInstallersProvider {
        DownloadedInstallersProvider(
            category: StorageCategory(id: "virtualBuddyDownloads", title: "VirtualBuddy-Downloads", summary: "", risk: .low,
                                      roots: [root.path]),
            extensions: ["ipsw"], minimumAgeDays: 90, now: { Self.now }, measurer: measurer)
    }

    private func file(_ name: String, in root: URL, daysOld: Double) throws {
        let url = root.appending(path: name)
        try Data("x".utf8).write(to: url)
        let date = Self.now.addingTimeInterval(-daysOld * 86_400)
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
    }

    @Test func offersInstallersAndPreselectsOnlyOldOnes() async throws {
        try await ScratchDirectory.withCanonical(prefix: "installers") { scratch in
            let root = scratch.appending(path: "_Downloads")
            try FileManager.default.createDirectory(at: root.appending(path: "folder.ipsw"), withIntermediateDirectories: true)
            try file("UniversalMac_26.0_Restore.IPSW", in: root, daysOld: 120)
            try file("UniversalMac_27.0_Restore.ipsw", in: root, daysOld: 10)
            try file("notes.txt", in: root, daysOld: 200)
            try FileManager.default.createSymbolicLink(at: root.appending(path: "link.ipsw"),
                                                       withDestinationURL: root.appending(path: "notes.txt"))
            let report = await provider(root).scan()
            #expect(report.status == .available)
            #expect(report.items.map(\.title) == ["UniversalMac_26.0_Restore.IPSW", "UniversalMac_27.0_Restore.ipsw"])
            #expect(report.items.map(\.isPreselected) == [true, false])
            #expect(report.items.allSatisfy { $0.removal == .trash && $0.identity != nil && $0.detail?.hasPrefix("Vom ") == true })
        }
    }

    @Test func oldInstallerWithoutFinishedMeasurementIsNotPreselected() async throws {
        try await ScratchDirectory.withCanonical(prefix: "installers") { root in
            try file("UniversalMac_26.0_Restore.ipsw", in: root, daysOld: 120)
            let report = await provider(root, measurer: FixedSizeMeasurer()).scan()
            #expect(report.items.map(\.isPreselected) == [false])
        }
    }

    @Test func missingFolderIsNotInstalled() async {
        #expect(await provider(URL(filePath: "/nonexistent-\(UUID().uuidString)")).scan().status == .notInstalled)
    }

    @Test func unreadableFolderIsNamed() async throws {
        try await ScratchDirectory.withCanonical(prefix: "installers") { scratch in
            let root = scratch.appending(path: "_Downloads")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
            let report = await provider(root).scan()
            #expect(report.status == .needsFullDiskAccess)
            #expect(report.unreadablePaths == [root.path])
            #expect(report.uncoveredPaths == [root.path])
        }
    }
}
