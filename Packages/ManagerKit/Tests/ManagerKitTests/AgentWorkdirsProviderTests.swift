import Darwin
import Foundation
import Testing
import TestSupport
@testable import ManagerKit

/// Nur temporäre Fixture-Ordner; echte Agenten-Arbeitsordner werden nie angefasst (#229).
@Suite struct AgentWorkdirsProviderTests {
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)
    private static let old = now.addingTimeInterval(-3 * 86_400)
    private static let recent = now.addingTimeInterval(-3_600)

    private struct Fixture {
        let claude: URL
        let codex: URL
        let home: String
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        try await ScratchDirectory.withCanonical(prefix: "agent-workdirs") { scratch in
            let fixture = Fixture(claude: scratch.appending(path: "tmp/claude-\(getuid())"),
                                  codex: scratch.appending(path: "home/.codex/.tmp"),
                                  home: "/Users/tester")
            try await body(fixture)
        }
    }

    /// Echte Zählung (`FileSizeCalculator`): Größe und jüngste Änderung kommen aus demselben Durchgang.
    private func provider(_ fixture: Fixture, openFiles: any OpenFileProbing = FakeOpenFileProbe(),
                          measurer: any FileSizeMeasuring = FileSizeCalculator(),
                          userID: uid_t = getuid()) -> AgentWorkdirsProvider {
        AgentWorkdirsProvider(claudeRoot: fixture.claude.path, codexRoot: fixture.codex.path, home: fixture.home,
                              minimumAgeDays: 2, measurer: measurer, openFiles: openFiles, now: { Self.now },
                              userID: userID)
    }

    /// Legt `relative/inner/file` an und setzt alle Zeitstempel von innen nach außen auf `modified`.
    @discardableResult
    private func session(_ root: URL, _ relative: String, modified: Date) throws -> URL {
        let folder = root.appending(path: relative)
        let file = folder.appending(path: "scratchpad/result.txt")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        for url in [file, file.deletingLastPathComponent(), folder] { try touch(url, modified) }
        return folder
    }

    private func touch(_ url: URL, _ modified: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    @Test func listsOneRowPerSessionAndPreselectsOnlyIdleOnes() async throws {
        try await withFixture { fixture in
            let idle = try session(fixture.claude, "-Users-tester-orca-homelab-app/8657d882-520d-41df-a11a-2d093f677028",
                                   modified: Self.old)
            try session(fixture.claude, "-Users-tester-orca-homelab-app/11111111-2222-3333-4444-555555555555",
                        modified: Self.recent)
            let codex = try session(fixture.codex, "git-0kZroH", modified: Self.old)
            let report = await provider(fixture).scan()
            #expect(report.status == .available)
            #expect(report.category.id == AgentWorkdirsProvider.categoryID)
            #expect(report.category.risk == .low)
            #expect(report.items.map(\.title) == ["orca-homelab-app – Session 11111111",
                                                  "orca-homelab-app – Session 8657d882", "Codex – git-0kZroH"])
            #expect(report.items.map(\.isPreselected) == [false, true, true])
            #expect(report.items.map(\.path) == [
                fixture.claude.path + "/-Users-tester-orca-homelab-app/11111111-2222-3333-4444-555555555555",
                idle.path, codex.path,
            ])
            #expect(report.items.allSatisfy { $0.removal == .trash && $0.identity != nil && ($0.size.bytes ?? 0) > 0 })
            #expect(report.items[1].detail?.hasPrefix("Claude Code, zuletzt geändert am ") == true)
            #expect(report.items[2].detail?.hasPrefix("Codex, zuletzt geändert am ") == true)
        }
    }

    /// „Zuletzt geändert“ ist die jüngste mtime im ganzen Unterbaum, nicht die des Session-Ordners.
    @Test func newestChangeInSubtreeKeepsSessionActive() async throws {
        try await withFixture { fixture in
            let folder = try session(fixture.claude, "-Users-tester-p/aaaaaaaa-0000", modified: Self.old)
            try touch(folder.appending(path: "scratchpad/result.txt"), Self.recent)
            let item = try #require(await provider(fixture).scan().items.first)
            #expect(!item.isPreselected)
            #expect(item.detail == "Claude Code, zuletzt geändert am "
                    + Self.recent.formatted(date: .abbreviated, time: .shortened))
        }
    }

    /// Ein Symlink im Unterbaum wird nicht verfolgt: Das junge Ziel außerhalb hält die Session nicht aktiv.
    @Test func symlinksAreNotFollowed() async throws {
        try await withFixture { fixture in
            let folder = try session(fixture.claude, "-Users-tester-p/aaaaaaaa-0000", modified: Self.old)
            let target = fixture.claude.deletingLastPathComponent().appending(path: "fresh")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data("y".utf8).write(to: target.appending(path: "new.txt"))
            let link = folder.appending(path: "link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            var times = [timeval(tv_sec: Int(Self.old.timeIntervalSince1970), tv_usec: 0),
                         timeval(tv_sec: Int(Self.old.timeIntervalSince1970), tv_usec: 0)]
            #expect(lutimes(link.path, &times) == 0)
            try touch(folder, Self.old)
            // Ein Symlink als Session- oder Projekteintrag erscheint gar nicht.
            try FileManager.default.createSymbolicLink(at: fixture.claude.appending(path: "-Users-tester-p/linked"),
                                                       withDestinationURL: target)
            let items = await provider(fixture).scan().items
            #expect(items.map(\.title) == ["p – Session aaaaaaaa"])
            #expect(items.first?.isPreselected == true)
        }
    }

    /// Offene Dateien oder Arbeitsordner eines beliebigen eigenen Prozesses sperren die Session (wie dieser Worker).
    @Test func sessionsInUseByAnyProcessAreNotPreselected() async throws {
        try await withFixture { fixture in
            let folder = try session(fixture.claude, "-Users-tester-p/aaaaaaaa-0000", modified: Self.old)
            let probe = FakeOpenFileProbe([OpenPath(processName: "zsh", path: folder.path + "/tasks/b1.output")])
            let report = await provider(fixture, openFiles: probe).scan()
            #expect(report.category.processLock == ProcessLock.anyProcess)
            let item = try #require(report.items.first)
            #expect(!item.isPreselected)
            #expect(item.detail == "Wird gerade benutzt von zsh")
        }
    }

    /// Ist die Prozessliste nicht lesbar, lässt sich „unbenutzt“ nicht belegen: nichts vorausgewählt.
    @Test func unreadableProcessListPreselectsNothing() async throws {
        try await withFixture { fixture in
            try session(fixture.claude, "-Users-tester-p/aaaaaaaa-0000", modified: Self.old)
            let items = await provider(fixture, openFiles: FakeOpenFileProbe(nil)).scan().items
            #expect(items.count == 1 && items.allSatisfy { !$0.isPreselected })
        }
    }

    /// Begrenzter Aufwand: Ohne vollständige Zählung (Frist, nicht lesbar) ist die jüngste Änderung nicht belegt – nicht
    /// vorausgewählt, ehrlich benannt.
    @Test func unprovenChangeLeavesSessionUnselected() async throws {
        try await withFixture { fixture in
            try session(fixture.claude, "-Users-tester-p/aaaaaaaa-0000", modified: Self.old)
            let item = try #require(await provider(fixture, measurer: FixedSizeMeasurer()).scan().items.first)
            #expect(!item.isPreselected)
            #expect(item.detail == "Claude Code, zuletzt geändert: nicht vollständig geprüft")
        }
    }

    @Test func foreignOwnedRootsAreIgnored() async throws {
        try await withFixture { fixture in
            try session(fixture.claude, "-Users-tester-p/aaaaaaaa-0000", modified: Self.old)
            let report = await provider(fixture, userID: getuid() + 1).scan()
            #expect(report.items.isEmpty)
            #expect(report.status == .notInstalled)
        }
    }

    @Test func missingRootsAreNotInstalled() async throws {
        try await withFixture { fixture in
            #expect(await provider(fixture).scan().status == .notInstalled)
        }
    }

    @Test func projectNamesDropTheEncodedHomeFolder() {
        #expect(AgentWorkdirsProvider.projectName("-Users-tester-orca-homelab-app", home: "/Users/tester") == "orca-homelab-app")
        #expect(AgentWorkdirsProvider.projectName("-Users-tester", home: "/Users/tester") == "~")
        #expect(AgentWorkdirsProvider.projectName("-Users-tester-x.y-z", home: "/Users/tester.x") == "-Users-tester-x.y-z")
        #expect(AgentWorkdirsProvider.projectName("-private-var-folders-T", home: "/Users/tester") == "-private-var-folders-T")
    }
}
