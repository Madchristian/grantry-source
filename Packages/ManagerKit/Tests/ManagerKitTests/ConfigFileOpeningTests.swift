import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct ConfigFileOpeningTests {
    private let fileManager = FileManager.default

    @Test(arguments: ["settings.json", "mcp.JSONC", "config.toml"])
    func regularConfigFileIsOpenable(name: String) throws {
        try ScratchDirectory.with { dir in
            let file = dir.appending(path: name)
            try Data("{}".utf8).write(to: file)
            #expect(ConfigFileOpening.verdict(for: file.path) == .openable(file.resolvingSymlinksInPath()))
        }
    }

    @Test func tildeUsesHome() throws {
        try ScratchDirectory.with { dir in
            try Data("{}".utf8).write(to: dir.appending(path: ".claude.json"))
            let file = dir.appending(path: ".claude.json")
            #expect(ConfigFileOpening.verdict(for: "~/.claude.json", home: dir.path) == .openable(file.resolvingSymlinksInPath()))
        }
    }

    @Test func missingFile() throws {
        try ScratchDirectory.with { dir in
            #expect(ConfigFileOpening.verdict(for: dir.appending(path: "nope.json").path) == .missing)
        }
    }

    @Test func danglingSymlinkCountsAsMissing() throws {
        try ScratchDirectory.with { dir in
            let link = dir.appending(path: "settings.json")
            try fileManager.createSymbolicLink(at: link, withDestinationURL: dir.appending(path: "gone.json"))
            #expect(ConfigFileOpening.verdict(for: link.path) == .missing)
        }
    }

    @Test func symlinkToScriptIsNotOpenable() throws {
        try ScratchDirectory.with { dir in
            let script = dir.appending(path: "run.command")
            try Data("#!/bin/sh\n".utf8).write(to: script)
            let link = dir.appending(path: "settings.json")
            try fileManager.createSymbolicLink(at: link, withDestinationURL: script)
            #expect(ConfigFileOpening.verdict(for: link.path) == .notEditable)
        }
    }

    @Test func symlinkToConfigFileOpensTheTarget() throws {
        try ScratchDirectory.with { dir in
            let target = dir.appending(path: "real.toml")
            try Data("a = 1\n".utf8).write(to: target)
            let link = dir.appending(path: "config.toml")
            try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
            #expect(ConfigFileOpening.verdict(for: link.path) == .openable(target.resolvingSymlinksInPath()))
        }
    }

    @Test(arguments: ["settings.json", "Evil.app"])
    func directoryIsNotOpenable(name: String) throws {
        try ScratchDirectory.with { dir in
            let directory = dir.appending(path: name)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            #expect(ConfigFileOpening.verdict(for: directory.path) == .notEditable)
        }
    }

    @Test func otherExtensionIsNotOpenable() throws {
        try ScratchDirectory.with { dir in
            let file = dir.appending(path: "run.command")
            try Data("#!/bin/sh\n".utf8).write(to: file)
            #expect(ConfigFileOpening.verdict(for: file.path) == .notEditable)
        }
    }
}

/// `verdictIfLocal`: keine Prüfung auf Netzlaufwerken (Einhängepunkte aus dem Test, nie vom echten Mac).
/// Kanonische Fixture-Pfade wie in der Kernel-Mount-Tabelle; Foundation kürzt dagegen `/private/var` zu `/var`.
@Suite struct ConfigFileOpeningVolumeTests {
    @Test func folderSymlinkIntoNetworkVolumeIsNotChecked() throws {
        try ScratchDirectory.withCanonical { dir in
            let share = dir.appending(path: "nas")
            try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: share.appending(path: "settings.json"))
            let link = dir.appending(path: "project")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: share.path)
            let volumes = [MountedVolume(path: "/", isLocal: true), MountedVolume(path: share.path, isLocal: false)]
            #expect(ConfigFileOpening.verdictIfLocal(for: link.path + "/settings.json", home: dir.path, volumes: volumes) == nil)
            #expect(ConfigFileOpening.verdictIfLocal(for: link.path + "/settings.json", home: dir.path,
                                                    volumes: [MountedVolume(path: "/", isLocal: true)])
                == .openable(share.appending(path: "settings.json")))
        }
    }

    @Test func localFileGetsTheVerdict() throws {
        try ScratchDirectory.withCanonical { dir in
            let file = dir.appending(path: "settings.json")
            try Data("{}".utf8).write(to: file)
            let volumes = [MountedVolume(path: "/", isLocal: true)]
            #expect(ConfigFileOpening.verdictIfLocal(for: file.path, home: dir.path, volumes: volumes)
                == .openable(file))
        }
    }

    @Test func fileOnNetworkVolumeIsNotChecked() throws {
        try ScratchDirectory.withCanonical { dir in
            let file = dir.appending(path: "settings.json")
            try Data("{}".utf8).write(to: file)
            let volumes = [MountedVolume(path: "/", isLocal: true), MountedVolume(path: dir.path, isLocal: false)]
            #expect(ConfigFileOpening.verdictIfLocal(for: file.path, home: dir.path, volumes: volumes) == nil)
            #expect(ConfigFileOpening.verdictIfLocal(for: "~/settings.json", home: dir.path, volumes: volumes) == nil)
        }
    }

    /// Ein lokaler Symlink, dessen (relatives) Ziel auf einem Netzlaufwerk liegt, wird nicht aufgelöst.
    @Test func symlinkIntoNetworkVolumeIsNotResolved() throws {
        try ScratchDirectory.withCanonical { dir in
            let share = dir.appending(path: "nas")
            try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: share.appending(path: "real.json"))
            let link = dir.appending(path: "local/settings.json")
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../nas/real.json")
            let volumes = [MountedVolume(path: "/", isLocal: true), MountedVolume(path: share.path, isLocal: false)]
            #expect(ConfigFileOpening.verdictIfLocal(for: link.path, home: dir.path, volumes: volumes) == nil)
            let local = [MountedVolume(path: "/", isLocal: true)]
            #expect(ConfigFileOpening.verdictIfLocal(for: link.path, home: dir.path, volumes: local) != nil)
        }
    }
}
