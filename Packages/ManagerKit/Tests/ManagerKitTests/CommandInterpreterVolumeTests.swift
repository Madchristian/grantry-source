import Darwin
import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct CommandInterpreterVolumeTests {
    private let volumes = [MountedVolume(path: "/", isLocal: true),
                           MountedVolume(path: "/Volumes/nas", isLocal: false),
                           MountedVolume(mountPoint: "/System/Volumes/Data/home", isLocal: false)]

    @Test func oneMountSnapshotPerRedactionAndFreshSnapshotForTheNext() {
        var queries = 0
        let snapshot = { queries += 1; return self.volumes }
        let fileSystem = CommandInterpreterPath.FileSystem(
            entry: { _ in .directory }, contents: { _ in Issue.record("Verzeichnisse nicht öffnen"); return nil }
        )
        let resolver = CommandInterpreterPath.makeResolver(volumes: snapshot, fileSystem: fileSystem)
        let ordinary = ["tool", "a b", "relative/path"]
        #expect(ArgumentRedactor.redact(arguments: ordinary, resolvingPath: resolver).values == ordinary)
        #expect(queries == 0)
        let paths = ["/local/tool", "/local/one", "/local/two /local/three"]
        #expect(ArgumentRedactor.redact(arguments: paths, resolvingPath: resolver).values == paths)
        #expect(queries == 1)
        let next = CommandInterpreterPath.makeResolver(volumes: snapshot, fileSystem: fileSystem)
        #expect(ArgumentRedactor.redact(arguments: paths, resolvingPath: next).values == paths)
        #expect(queries == 2)
    }

    @Test func failedMountSnapshotIsAlsoCached() {
        var queries = 0
        let resolver = CommandInterpreterPath.makeResolver(volumes: { queries += 1; return [] })
        #expect(resolver("/one") == "/bin/sh")
        #expect(resolver("/two") == "/bin/sh")
        #expect(queries == 1)
    }

    /// The injected boundary fails on any filesystem access to the simulated unavailable mount.
    /// No SMB connection, sleeps or abandoned workers are needed to reproduce the scan hazard.
    @Test(arguments: ["/Volumes/nas/runner", "/Volumes/NAS/runner", "/volumes/nas/runner",
                      "/Volumes/nas/../runner", "/System/Volumes/Data/Volumes/nas/runner",
                      "/home/user/runner", "/System/Volumes/Data/home/user/runner",
                      "/Volumes/unmounted/runner"])
    func remoteAndUnmountedPathsNeverReachFileSystem(_ path: String) {
        let masked = ArgumentRedactor.redact(arguments: ["env", path, "-c", "true&&API_TOKEN=fixture193 run"],
            resolvingPath: { candidate in
                CommandInterpreterPath.resolve(candidate, volumes: volumes, fileSystem: .init(
                    entry: { _ in Issue.record("An unavailable path must not reach metadata or readlink"); return .unavailable },
                    contents: { _ in Issue.record("An unavailable path must not be opened"); return nil }
                ))
            })
        #expect(masked.values.last == "•••")
        #expect(masked.hasHiddenScript)
    }

    @Test func unknownMountTableDoesNotTouchEvenLocalLookingPaths() {
        let result = CommandInterpreterPath.resolve("/local/runner", volumes: [], fileSystem: .init(
            entry: { _ in Issue.record("No mount information: no metadata"); return .unavailable },
            contents: { _ in Issue.record("No mount information: no contents"); return nil }
        ))
        #expect(result == "/bin/sh")
    }

    @Test(arguments: ["/local/link/runner", "/local/link/../runner", "/local/runner"])
    func localLinksAreCheckedBeforeFollowingRemoteTargets(_ path: String) {
        var accessed: [String] = []
        let result = CommandInterpreterPath.resolve(path, volumes: volumes, fileSystem: .init(
            entry: { path in
                accessed.append(path)
                switch path {
                case "/local", "/Volumes": return .directory
                case "/local/link": return .symbolicLink("../Volumes/nas")
                case "/local/runner": return .symbolicLink("/Volumes/nas/runner")
                default: Issue.record("Unexpected metadata access: \(path)"); return .unavailable
                }
            },
            contents: { _ in Issue.record("Remote target must not be read"); return nil }
        ))
        #expect(result == "/bin/sh")
        #expect(accessed == (path == "/local/runner" ? ["/local", "/local/runner"] : ["/local", "/local/link", "/Volumes"]))
    }

    @Test(arguments: ["arguments", "env", "program", "parentLink"])
    func launchdScanSkipsRemoteProgramInspection(mode: String) async throws {
        try await ScratchDirectory.with { directory in
            let remote = directory.appending(path: "share")
            try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
            let bundle = remote.appending(path: "Tool.app/Contents/MacOS")
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            let executable = bundle.appending(path: "runner")
            try FileManager.default.copyItem(atPath: "/bin/echo", toPath: executable.path)
            let link = directory.appending(path: "link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: remote)
            let program = mode == "parentLink" ? link.appending(path: "Tool.app/Contents/MacOS/runner").path : executable.path
            let behindEnv = mode == "env"
            let arguments = (behindEnv ? ["/usr/bin/env"] : [])
                + [mode == "program" ? "neutral-argv-zero" : program, "-c", "true&&API_TOKEN=fixture193 run"]
            var plist: [String: Any] = ["Label": "fixture193", "ProgramArguments": arguments]
            if mode == "program" { plist["Program"] = program }
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: directory.appending(path: "agent.plist"))
            let runner = MockCommandRunner()
            runner.stub("/bin/launchctl print-disabled gui/501", CommandResult(exitCode: 0, stdout: "disabled services = {\n}\n"))
            runner.stub("/bin/launchctl print gui/501", CommandResult(exitCode: 0, stdout: "gui/501 = {\n services = {\n }\n}\n"))
            let source = LaunchdSource(
                directories: [LaunchdDirectory(path: directory.path, kind: .launchAgent, domain: .user, launchctlDomain: "gui/501")],
                runner: runner, resolver: StubAppResolver(), inspector: LocalInspector(),
                volumes: { MountedVolume.current() + [MountedVolume(path: remote.path, isLocal: false)] }
            )
            let coordinator = ScanCoordinator(sources: [source], sourceTimeout: .seconds(2))
            for _ in 0..<3 {
                let snapshot = try await coordinator.scan()
                #expect(snapshot.failedSources.isEmpty)
                let item = try #require(snapshot.autostartItems.first)
                #expect(item.programArguments?.last == "•••")
                #expect(item.hasHiddenScript)
                if !behindEnv {
                    #expect(item.programPresence == .unknown)
                    #expect(item.programSigning == nil)
                    #expect(item.programScript == nil)
                    #expect(item.owner?.presence == .unknown)
                }
            }
        }
    }

    @Test func localParentLinkIsResolvedBeforeDotDot() {
        let target = LocalPathResolver.resolve("/alias/../runner", volumes: volumes, entry: { path in
            switch path {
            case "/alias": .symbolicLink("/local/subdir")
            case "/local", "/local/subdir": .directory
            case "/local/runner": .regularFile(42)
            default: .unavailable
            }
        })
        #expect(target?.path == "/local/runner")
    }

    @Test func failedLocalMetadataIsConservativeButProvenMissingStaysMissing() {
        for entry in [LocalPathResolver.Entry.unavailable, .missing] {
            let masked = ArgumentRedactor.redact(arguments: ["/runner", "-c", "true&&API_TOKEN=fixture193 run"],
                resolvingPath: { path in
                    CommandInterpreterPath.resolve(path, volumes: volumes, fileSystem: .init(
                        entry: { _ in entry }, contents: { _ in Issue.record("No file to read"); return nil }
                    ))
                })
            if case .unavailable = entry {
                #expect(masked.values.last == "•••")
                #expect(masked.hasHiddenScript)
            } else {
                #expect(!masked.hasHiddenScript)
            }
        }
    }

    private struct LocalInspector: SigningInspecting {
        func inspect(path: String) -> SigningInfo {
            #expect(path == "/usr/bin/env")
            return SigningInfo(kind: .adHoc)
        }
    }

    @Test func localSymlinkLoopIsBounded() {
        var calls = 0
        let result = CommandInterpreterPath.resolve("/loop", volumes: volumes, fileSystem: .init(
            entry: { _ in calls += 1; return .symbolicLink("/loop") },
            contents: { _ in Issue.record("Loop must not be read"); return nil }
        ))
        #expect(result == "/bin/sh")
        #expect(calls <= 40)
    }
}
