import Foundation
import Testing
import TestSupport
@testable import ManagerKit

/// Grenzfälle der Agenten-Quelle: fehlende Programme, Projekte auf Volumes und Netzlaufwerken, unlesbare oder
/// ausbrechende Projektpfade, leere Dateien.
@Suite struct AgentConfigSourceRobustnessTests {
    private func write(_ text: String, to relative: String, in home: URL) throws {
        let url = home.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Nur Benutzerdateien; Einhängepunkte kommen aus dem Test, nie vom echten Mac.
    private func source(
        home: URL, inspector: any SigningInspecting = RecordingSigningInspector(result: .unknown),
        volumes: [MountedVolume] = [MountedVolume(path: "/", isLocal: true)]
    ) -> AgentConfigSource {
        AgentConfigSource(catalog: TestData.userCatalog, home: home.path, inspector: inspector, volumes: { volumes })
    }

    /// Registriert `projects` in `~/.claude.json` (Claude Code liest dort `.mcp.json` der Projekte).
    private func register(_ projects: [String], in home: URL) throws {
        let entries = projects.map { #""\#($0)": {"enabledMcpjsonServers": ["p"]}"# }.joined(separator: ", ")
        try write(#"{"projects": {\#(entries)}}"#, to: ".claude.json", in: home)
    }

    /// Alle Dateien, die der Scan je Projekt liest – in dieser Reihenfolge als Lücke gemeldet.
    private func projectFiles(of project: String) -> [String] {
        [project + "/.mcp.json", project + "/.claude/settings.json", project + "/.claude/settings.local.json"]
    }

    // MARK: Programme

    @Test func danglingProgramSymlinkIsMissingAndNotInspected() async throws {
        try await ScratchDirectory.with { home in
            let link = home.appending(path: "bin/server")
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: home.appending(path: "weg").path)
            try write(#"{"mcpServers": {"l": {"command": "\#(link.path)"}}}"#, to: ".cursor/mcp.json", in: home)
            let inspector = RecordingSigningInspector(result: SigningInfo(kind: .adHoc))
            let contribution = try await source(home: home, inspector: inspector).collect()
            let server = try #require(contribution.agents.mcpServers.first)
            #expect(server.programPresence == .missing)
            #expect(server.programSigning == nil)
            #expect(inspector.paths.isEmpty)
        }
    }

    /// Ein Programm auf einem Netzlaufwerk wird nicht berührt: Vorhandensein unbekannt, keine Signaturprüfung – auch
    /// wenn die Datei da ist.
    @Test func programOnNetworkVolumeIsUnknownAndNotInspected() async throws {
        try await ScratchDirectory.with { home in
            let program = home.appending(path: "bin/server")
            try write("binär", to: "bin/server", in: home)
            try write(#"{"mcpServers": {"n": {"command": "\#(program.path)"}}}"#, to: ".cursor/mcp.json", in: home)
            let inspector = RecordingSigningInspector(result: SigningInfo(kind: .adHoc))
            let volumes = [MountedVolume(path: "/", isLocal: true),
                           MountedVolume(path: home.appending(path: "bin").path, isLocal: false)]
            let contribution = try await source(home: home, inspector: inspector, volumes: volumes).collect()
            let server = try #require(contribution.agents.mcpServers.first)
            #expect(server.programPresence == .unknown)
            #expect(server.programSigning == nil)
            #expect(inspector.paths.isEmpty)
        }
    }

    /// Ein Programm auf einem nicht eingehängten Volume gilt nicht als fehlend, sondern als unbekannt.
    @Test func programOnUnmountedVolumeIsUnknown() async throws {
        try await ScratchDirectory.with { home in
            let program = "/Volumes/grantry-test-\(UUID().uuidString)/bin/server"
            try write(#"{"mcpServers": {"u": {"command": "\#(program)"}}}"#, to: ".cursor/mcp.json", in: home)
            let inspector = RecordingSigningInspector(result: SigningInfo(kind: .adHoc))
            let contribution = try await source(home: home, inspector: inspector,
                                                volumes: [MountedVolume(path: "/", isLocal: true)]).collect()
            let server = try #require(contribution.agents.mcpServers.first)
            #expect(server.programPresence == .unknown)
            #expect(inspector.paths.isEmpty)
        }
    }

    // MARK: Volumes

    @Test func projectOnUnmountedVolumeIsGapWithoutLimitation() async throws {
        try await ScratchDirectory.with { home in
            let project = "/Volumes/grantry-test-\(UUID().uuidString)/web"
            try register([project], in: home)
            let contribution = try await source(home: home).collect()
            #expect(contribution.agents.incompleteFiles == projectFiles(of: project))
            #expect(contribution.limitations.isEmpty)
            #expect(contribution.agents.mcpServers.isEmpty)
        }
    }

    @Test func projectsOnNetworkVolumeAreNotReadButGaps() async throws {
        try await ScratchDirectory.with { home in
            let volume = "/Volumes/nas-\(UUID().uuidString)"
            try register([volume + "/a", volume + "/b"], in: home)
            let contribution = try await source(home: home, volumes: [MountedVolume(path: "/", isLocal: true), MountedVolume(path: volume, isLocal: false)]).collect()
            #expect(Set(contribution.agents.incompleteFiles) == Set(projectFiles(of: volume + "/a") + projectFiles(of: volume + "/b")))
            #expect(contribution.limitations == ["Projekte auf Netzlaufwerk \(volume) nicht gelesen"])
        }
    }

    /// Ein lokales Volume wird normal gelesen – auch wenn es unter `/Volumes` hängt.
    @Test func projectOnLocalVolumeIsRead() async throws {
        try await ScratchDirectory.with { home in
            let project = home.appending(path: "Projekte/web").path
            try register([project], in: home)
            try write(#"{"mcpServers": {"p": {"command": "p"}}}"#, to: "Projekte/web/.mcp.json", in: home)
            let contribution = try await source(home: home, volumes: [MountedVolume(path: "/", isLocal: true), MountedVolume(path: home.path, isLocal: true)]).collect()
            #expect(contribution.agents.mcpServers.map(\.name) == ["p"])
            #expect(contribution.agents.incompleteFiles.isEmpty)
        }
    }

    /// Das innerste Volume entscheidet: ein lokaler Ordner unter einem Netz-Einhängepunkt bleibt Netz, umgekehrt nicht.
    @Test func innermostMountDecides() {
        let volumes = [MountedVolume(path: "/", isLocal: true), MountedVolume(path: "/Volumes/nas", isLocal: false)]
        #expect(MountedVolume.containing("/Volumes/nas/a/.mcp.json", in: volumes)?.path == "/Volumes/nas")
        #expect(MountedVolume.containing("/Volumes/nasx/a", in: volumes)?.path == "/")
        #expect(MountedVolume.containing("/Users/x", in: volumes)?.path == "/")
    }

    /// Die Einhängetabelle des Kernels enthält immer das lokale Wurzel-Volume.
    @Test func currentMountsIncludeLocalRoot() {
        #expect(MountedVolume.current().contains(MountedVolume(path: "/", isLocal: true)))
    }

    /// autofs-Maps hängen unter dem Firmlink-Ziel (`/System/Volumes/Data/home`); Projektpfade nennen `/home/…`.
    @Test func mountPointsDropFirmlinkPrefix() {
        #expect(MountedVolume(mountPoint: "/System/Volumes/Data/home", isLocal: false).path == "/home")
        #expect(MountedVolume(mountPoint: "/System/Volumes/Data/Network/Servers", isLocal: false).path == "/Network/Servers")
        #expect(MountedVolume(mountPoint: "/System/Volumes/Data", isLocal: true).path == "/System/Volumes/Data")
        #expect(MountedVolume(mountPoint: "/System/Volumes/Database", isLocal: true).path == "/System/Volumes/Database")
        #expect(MountedVolume(mountPoint: "/Volumes/nas", isLocal: false).path == "/Volumes/nas")
        let volumes = [MountedVolume(mountPoint: "/", isLocal: true),
                       MountedVolume(mountPoint: "/System/Volumes/Data/home", isLocal: false)]
        #expect(MountedVolume.containing("/home/beispiel/web", in: volumes)?.isLocal == false)
    }

    @Test func networkHomeMapProjectIsNotRead() async throws {
        try await ScratchDirectory.with { home in
            try register(["/home/nutzer/web"], in: home)
            let volumes = [MountedVolume(mountPoint: "/", isLocal: true),
                           MountedVolume(mountPoint: "/System/Volumes/Data/home", isLocal: false)]
            let contribution = try await source(home: home, volumes: volumes).collect()
            #expect(contribution.agents.incompleteFiles == projectFiles(of: "/home/nutzer/web"))
            #expect(contribution.limitations == ["Projekte auf Netzlaufwerk /home nicht gelesen"])
        }
    }

    @Test func existingProjectWithoutProjectFileYieldsNothing() async throws {
        try await ScratchDirectory.with { home in
            let project = home.appending(path: "Projekte/leer")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try register([project.path], in: home)
            let contribution = try await source(home: home).collect()
            #expect(contribution.agents.mcpServers.isEmpty)
            #expect(contribution.agents.incompleteFiles.isEmpty)
            #expect(contribution.limitations.isEmpty)
        }
    }

    // MARK: Projektpfade

    @Test func projectPathEscapingHomeWithDotDotIsNotRead() async throws {
        try await ScratchDirectory.with { outside in
            try await ScratchDirectory.with { home in
                try write(#"{"mcpServers": {"x": {"command": "x"}}}"#, to: "web/.mcp.json", in: outside)
                let project = home.path + "/../" + outside.lastPathComponent + "/web"
                try register([project], in: home)
                let contribution = try await source(home: home).collect()
                let projectFile = project + "/.mcp.json"
                #expect(contribution.agents.mcpServers.isEmpty)
                #expect(contribution.agents.incompleteFiles == [projectFile])
                #expect(contribution.limitations
                    == ["Konfiguration von Claude Code nicht lesbar (\(projectFile)): verweist aus dem Benutzerordner heraus"])
            }
        }
    }

    @Test func unreadableProjectFileIsGap() async throws {
        try await ScratchDirectory.with { home in
            let project = home.appending(path: "Projekte/web").path
            try register([project], in: home)
            try write(#"{"mcpServers": {"p": {"command": "p"}}}"#, to: "Projekte/web/.mcp.json", in: home)
            let projectFile = project + "/.mcp.json"
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: projectFile)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: projectFile) }
            let contribution = try await source(home: home).collect()
            #expect(contribution.agents.incompleteFiles == [projectFile])
            #expect(contribution.limitations == ["Konfiguration von Claude Code nicht lesbar (\(projectFile)): nicht lesbar"])
        }
    }

    /// Ohne die Einstellungsdatei ist die Freigabe der `.mcp.json`-Server unbekannt: beide sind Lücke.
    @Test func unreadableProjectSettingsIsGapForProjectFileToo() async throws {
        try await ScratchDirectory.with { home in
            let project = home.appending(path: "Projekte/web").path
            try register([project], in: home)
            try write(#"{"mcpServers": {"p": {"command": "p"}}}"#, to: "Projekte/web/.mcp.json", in: home)
            try write(#"{"enabledMcpjsonServers": ["p"]}"#, to: "Projekte/web/.claude/settings.local.json", in: home)
            let settings = project + "/.claude/settings.local.json"
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: settings)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings) }
            let contribution = try await source(home: home).collect()
            #expect(contribution.agents.mcpServers.isEmpty)
            #expect(contribution.agents.incompleteFiles == [settings, project + "/.mcp.json"])
            #expect(contribution.limitations == ["Konfiguration von Claude Code nicht lesbar (\(settings)): nicht lesbar"])
        }
    }

    /// Ist die globale Einstellungsdatei unlesbar, ist die Freigabe aller `.mcp.json`-Server unbekannt.
    @Test func unreadableGlobalSettingsIsGapForProjectFiles() async throws {
        try await ScratchDirectory.with { home in
            let project = home.appending(path: "Projekte/web").path
            try register([project], in: home)
            try write(#"{"mcpServers": {"p": {"command": "p"}}}"#, to: "Projekte/web/.mcp.json", in: home)
            try write(#"{"enableAllProjectMcpServers": true}"#, to: ".claude/settings.json", in: home)
            let settings = home.appending(path: ".claude/settings.json").path
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: settings)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings) }
            let contribution = try await source(home: home).collect()
            #expect(contribution.agents.mcpServers.isEmpty)
            #expect(contribution.agents.incompleteFiles == [settings, project + "/.mcp.json"])
        }
    }

    /// Leere Einstellungsdateien sind keine Lücke – die Projektdatei wird normal gelesen.
    @Test func blankProjectSettingsAreNoGap() async throws {
        try await ScratchDirectory.with { home in
            let project = home.appending(path: "Projekte/web").path
            try register([project], in: home)
            try write(#"{"mcpServers": {"p": {"command": "p"}}}"#, to: "Projekte/web/.mcp.json", in: home)
            try write(" \n", to: "Projekte/web/.claude/settings.json", in: home)
            let contribution = try await source(home: home).collect()
            #expect(contribution.agents.mcpServers.map(\.isEnabled) == [true])
            #expect(contribution.agents.incompleteFiles.isEmpty)
        }
    }

    @Test func relativeProjectPathIsSkipped() async throws {
        try await ScratchDirectory.with { home in
            try register(["Projekte/web"], in: home)
            let contribution = try await source(home: home).collect()
            #expect(contribution.agents.mcpServers.isEmpty)
            #expect(contribution.agents.incompleteFiles.isEmpty)
            #expect(contribution.limitations.isEmpty)
        }
    }

    // MARK: Leere Dateien

    @Test func fileWithByteOrderMarkAndWhitespaceIsNoConfiguration() async throws {
        try await ScratchDirectory.with { home in
            try write("\u{FEFF} \n\t\r\n", to: ".cursor/mcp.json", in: home)
            let contribution = try await source(home: home).collect()
            #expect(contribution.limitations.isEmpty)
            #expect(contribution.agents.incompleteFiles.isEmpty)
        }
    }

    @Test func blankDetection() {
        #expect(ConfigParsing.isBlank(Data()))
        #expect(ConfigParsing.isBlank(Data(" \n\t\r".utf8)))
        #expect(ConfigParsing.isBlank(Data([0xEF, 0xBB, 0xBF, 0x20])))
        #expect(!ConfigParsing.isBlank(Data("{}".utf8)))
        #expect(!ConfigParsing.isBlank(Data([0xEF, 0xBB])))
    }
}
