import Foundation
import Testing
import TestSupport
@testable import ManagerKit

/// Regressionstests für Audit C2: Projekt-, Einstellungs- und Programmpfade werden einschließlich übergeordneter
/// Symlinks vorab gegen die Einhängetabelle geprüft. Netz-Ziele sind Lücken statt gelesener Konfigurationen;
/// lokale Symlinks bleiben nutzbar. Alle Ziele und Einhängepunkte sind isolierte Test-Fixtures.
@Suite struct PenetrationAgentConfigNetworkSymlinkTests {
    private func write(_ text: String, to relative: String, in home: URL) throws {
        let url = home.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Nur Benutzerdateien; Einhängepunkte kommen aus dem Test, nie vom echten Mac.
    private func source(home: URL, volumes: [MountedVolume]) -> AgentConfigSource {
        AgentConfigSource(catalog: TestData.userCatalog, home: home.path,
                          inspector: RecordingSigningInspector(result: .unknown), volumes: { volumes })
    }

    /// Registriert `projects` in `~/.claude.json` (Claude Code liest dort `.mcp.json` der Projekte).
    private func register(_ projects: [String], in home: URL) throws {
        let entries = projects.map { #""\#($0)": {"enabledMcpjsonServers": ["p"]}"# }.joined(separator: ", ")
        try write(#"{"projects": {\#(entries)}}"#, to: ".claude.json", in: home)
    }

    private func networkVolume() -> (path: String, volumes: [MountedVolume]) {
        let nas = "/Volumes/nas-\(UUID().uuidString)"
        return (nas, [MountedVolume(path: "/", isLocal: true), MountedVolume(path: nas, isLocal: false)])
    }

    /// Befund C2a: Die Projektdatei ist ein Symlink aufs Netzlaufwerk.
    @Test func projectFileSymlinkedOntoANetworkVolumeIsAGapNotARead() async throws {
        try await ScratchDirectory.withCanonical { home in
            let (nas, volumes) = networkVolume()
            let project = home.appending(path: "web").path
            try register([project], in: home)
            try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: project + "/.mcp.json", withDestinationPath: nas + "/x.json")
            let contribution = try await source(home: home, volumes: volumes).collect()
            #expect(contribution.agents.incompleteFiles.contains(project + "/.mcp.json"))
            #expect(contribution.limitations == ["Projekte auf Netzlaufwerk \(nas) nicht gelesen"])
        }
    }

    /// Befund C2b: Der Projektordner selbst ist ein Symlink aufs Netzlaufwerk (`~/code` → `/Volumes/NAS/code`).
    @Test func projectFolderSymlinkedOntoANetworkVolumeIsAGapNotARead() async throws {
        try await ScratchDirectory.withCanonical { home in
            let (nas, volumes) = networkVolume()
            let project = home.appending(path: "code").path
            try register([project], in: home)
            try FileManager.default.createSymbolicLink(atPath: project, withDestinationPath: nas + "/code")
            let contribution = try await source(home: home, volumes: volumes).collect()
            #expect(Set(contribution.agents.incompleteFiles) == Set([
                project + "/.mcp.json", project + "/.claude/settings.json", project + "/.claude/settings.local.json"
            ]))
            #expect(contribution.limitations == ["Projekte auf Netzlaufwerk \(nas) nicht gelesen"])
        }
    }

    @Test(arguments: [".mcp.json", ".claude/settings.json", ".claude/settings.local.json"])
    func readableNetworkTargetsAreSkippedAndReportedOnce(relativePath: String) async throws {
        try await ScratchDirectory.withCanonical { home in
            let share = home.appending(path: "nas")
            try write(#"{"mcpServers": {"p": {"command": "p"}}, "enableAllProjectMcpServers": true}"#,
                      to: "nas/config.json", in: home)
            let projects = ["one", "two"].map { home.appending(path: $0).path }
            try register(projects, in: home)
            for project in projects {
                try FileManager.default.createDirectory(atPath: project + "/.claude", withIntermediateDirectories: true)
                try Data(#"{"mcpServers": {"p": {"command": "p"}}}"#.utf8).write(to: URL(filePath: project + "/.mcp.json"))
                let file = project + "/" + relativePath
                if relativePath == ".mcp.json" { try FileManager.default.removeItem(atPath: file) }
                try FileManager.default.createSymbolicLink(atPath: file, withDestinationPath: share.path + "/config.json")
            }
            let volumes = [MountedVolume(path: "/", isLocal: true), MountedVolume(path: share.path, isLocal: false)]
            let contribution = try await source(home: home, volumes: volumes).collect()
            #expect(contribution.agents.mcpServers.isEmpty)
            for project in projects {
                #expect(contribution.agents.incompleteFiles.contains(project + "/" + relativePath))
                #expect(contribution.agents.incompleteFiles.contains(project + "/.mcp.json"))
            }
            #expect(contribution.limitations == ["Projekte auf Netzlaufwerk \(share.path) nicht gelesen"])
        }
    }

    @Test func globalSettingsOnNetworkVolumeLeaveProjectApprovalUnknown() async throws {
        try await ScratchDirectory.withCanonical { home in
            let project = home.appending(path: "web").path
            try register([project], in: home)
            try write(#"{"mcpServers": {"p": {"command": "p"}}}"#, to: "web/.mcp.json", in: home)
            try write(#"{"enableAllProjectMcpServers": true}"#, to: "nas/settings.json", in: home)
            try FileManager.default.createSymbolicLink(atPath: home.path + "/.claude", withDestinationPath: "nas")
            let share = home.appending(path: "nas").path
            let volumes = [MountedVolume(path: "/", isLocal: true), MountedVolume(path: share, isLocal: false)]
            let contribution = try await source(home: home, volumes: volumes).collect()
            #expect(contribution.agents.mcpServers.isEmpty)
            #expect(contribution.agents.incompleteFiles.contains(home.path + "/.claude/settings.json"))
            #expect(contribution.agents.incompleteFiles.contains(project + "/.mcp.json"))
            #expect(contribution.limitations == ["Projekte auf Netzlaufwerk \(share) nicht gelesen"])
        }
    }

    @Test(arguments: [false, true])
    func programSymlinksOnNetworkVolumeRemainUnknown(parentLink: Bool) async throws {
        try await ScratchDirectory.withCanonical { home in
            try write("binary", to: "nas/server", in: home)
            let share = home.appending(path: "nas").path
            let link = home.appending(path: "program").path
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: parentLink ? share : share + "/server")
            let program = parentLink ? link + "/server" : link
            try write(#"{"mcpServers": {"p": {"command": "\#(program)"}}}"#, to: ".cursor/mcp.json", in: home)
            let inspector = RecordingSigningInspector(result: .unknown)
            let volumes = [MountedVolume(path: "/", isLocal: true), MountedVolume(path: share, isLocal: false)]
            let source = AgentConfigSource(catalog: TestData.userCatalog, home: home.path,
                                           inspector: inspector, volumes: { volumes })
            let contribution = try await source.collect()
            let server = try #require(contribution.agents.mcpServers.first)
            #expect(server.programPresence == .unknown)
            #expect(server.programSigning == nil)
            #expect(inspector.paths.isEmpty)
        }
    }

    @Test func unknownMountTableLeavesCatalogFilesIncomplete() async throws {
        try await ScratchDirectory.withCanonical { home in
            try write(#"{"mcpServers": {"p": {"command": "p"}}}"#, to: ".cursor/mcp.json", in: home)
            let contribution = try await source(home: home, volumes: []).collect()
            #expect(contribution.agents.mcpServers.isEmpty)
            #expect(Set(contribution.agents.incompleteFiles) == Set(TestData.userCatalog.staticPaths(home: home.path)))
            #expect(contribution.limitations.count == 1)
        }
    }

    @Test func localProjectAndFileSymlinksAreRead() async throws {
        try await ScratchDirectory.withCanonical { home in
            let project = home.appending(path: "code").path
            try register([project], in: home)
            try write(#"{"mcpServers": {"p": {"command": "p"}}}"#, to: "web/server.json", in: home)
            try FileManager.default.createSymbolicLink(atPath: project, withDestinationPath: "web")
            try FileManager.default.createSymbolicLink(atPath: project + "/.mcp.json", withDestinationPath: "server.json")
            let contribution = try await source(home: home, volumes: [MountedVolume(path: "/", isLocal: true)]).collect()
            #expect(contribution.agents.mcpServers.map(\.name) == ["p"])
            #expect(contribution.agents.incompleteFiles.isEmpty)
            #expect(contribution.limitations.isEmpty)
        }
    }

    /// Gegenprobe (heute korrekt): Ein wörtlich auf dem Netzlaufwerk liegendes Projekt wird als Lücke gemeldet.
    @Test func projectLiterallyOnANetworkVolumeIsAGap() async throws {
        try await ScratchDirectory.withCanonical { home in
            let (nas, volumes) = networkVolume()
            try register([nas + "/web"], in: home)
            let contribution = try await source(home: home, volumes: volumes).collect()
            #expect(contribution.agents.incompleteFiles.contains(nas + "/web/.mcp.json"))
            #expect(contribution.limitations == ["Projekte auf Netzlaufwerk \(nas) nicht gelesen"])
        }
    }
}
