import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct AgentConfigReaderTests {
    @Test func missingFile() throws {
        try ScratchDirectory.with { dir in
            #expect(AgentConfigReader.read(path: dir.appending(path: "nope.json").path, home: .init(dir.path)) == .missing)
        }
    }

    @Test func readsContentsAndMode() throws {
        try ScratchDirectory.with { dir in
            let file = dir.appending(path: "a.json")
            try Data("{}".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
            #expect(AgentConfigReader.read(path: file.path, home: .init(dir.path)) == .contents(Data("{}".utf8), mode: 0o640))
        }
    }

    @Test func rejectsOversizedFiles() throws {
        try ScratchDirectory.with { dir in
            let file = dir.appending(path: "big.json")
            try Data(repeating: 0x20, count: 11).write(to: file)
            #expect(AgentConfigReader.read(path: file.path, home: .init(dir.path), maximumSize: 10) == .unreadable("größer als 10 Bytes"))
        }
    }

    /// Lässt sich das Home nicht auflösen, wird darin nichts gelesen (fail-closed); Dateien außerhalb bleiben lesbar.
    @Test func refusesFilesInAnUnresolvableHome() throws {
        try ScratchDirectory.with { dir in
            let file = dir.appending(path: "a.json")
            try Data("{}".utf8).write(to: file)
            let unresolved = AgentConfigReader.Home(path: dir.path, canonicalPath: nil)
            #expect(AgentConfigReader.read(path: file.path, home: unresolved) == .unreadable(AgentConfigReader.unreadableText))
            let elsewhere = AgentConfigReader.Home(path: "/nonexistent-home", canonicalPath: nil)
            #expect(AgentConfigReader.read(path: file.path, home: elsewhere) == .contents(Data("{}".utf8), mode: 0o644))
        }
    }

    @Test func refusesSymlinkLeavingHome() throws {
        try ScratchDirectory.with { outside in
            try ScratchDirectory.with { home in
                let target = outside.appending(path: "secret.json")
                try Data("{}".utf8).write(to: target)
                let link = home.appending(path: "mcp.json")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
                #expect(AgentConfigReader.read(path: link.path, home: .init(home.path))
                    == .unreadable("verweist aus dem Benutzerordner heraus"))
            }
        }
    }

    @Test func followsSymlinkInsideHome() throws {
        try ScratchDirectory.with { home in
            let target = home.appending(path: "real.json")
            try Data("{}".utf8).write(to: target)
            let link = home.appending(path: "link.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            guard case .contents = AgentConfigReader.read(path: link.path, home: .init(home.path)) else {
                Issue.record("Link im Home muss lesbar sein")
                return
            }
        }
    }

    @Test func sizeLimitTextFollowsTheLimit() {
        #expect(AgentConfigReader.sizeLimitText(AgentConfigReader.maximumFileSize) == "größer als 5 MB")
        #expect(AgentConfigReader.sizeLimitText(64 * 1024) == "größer als 64 KB")
        #expect(AgentConfigReader.sizeLimitText(10) == "größer als 10 Bytes")
    }

    @Test func acceptsFileAtTheLimit() throws {
        try ScratchDirectory.with { dir in
            let file = dir.appending(path: "edge.json")
            try Data(repeating: 0x20, count: 10).write(to: file)
            guard case .contents(let data, _) = AgentConfigReader.read(path: file.path, home: .init(dir.path), maximumSize: 10) else {
                Issue.record("Datei genau an der Grenze muss lesbar sein")
                return
            }
            #expect(data.count == 10)
        }
    }

    @Test func emptyFileHasNoContents() throws {
        try ScratchDirectory.with { dir in
            let file = dir.appending(path: "empty.json")
            try Data().write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            #expect(AgentConfigReader.read(path: file.path, home: .init(dir.path)) == .contents(Data(), mode: 0o600))
        }
    }

    @Test func rejectsDirectory() throws {
        try ScratchDirectory.with { dir in
            let folder = dir.appending(path: "mcp.json")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            #expect(AgentConfigReader.read(path: folder.path, home: .init(dir.path)) == .unreadable("keine reguläre Datei"))
        }
    }

    @Test func reportsFileWithoutReadPermission() throws {
        try ScratchDirectory.with { dir in
            let file = dir.appending(path: "locked.json")
            try Data("{}".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
            #expect(AgentConfigReader.read(path: file.path, home: .init(dir.path)) == .unreadable("nicht lesbar"))
        }
    }

    @Test func reportsSymlinkLoop() throws {
        try ScratchDirectory.with { dir in
            let first = dir.appending(path: "a.json")
            let second = dir.appending(path: "b.json")
            try FileManager.default.createSymbolicLink(atPath: first.path, withDestinationPath: second.path)
            try FileManager.default.createSymbolicLink(atPath: second.path, withDestinationPath: first.path)
            #expect(AgentConfigReader.read(path: first.path, home: .init(dir.path)) == .unreadable("Symlink-Schleife"))
        }
    }

    @Test func danglingSymlinkIsMissing() throws {
        try ScratchDirectory.with { dir in
            let link = dir.appending(path: "mcp.json")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: dir.appending(path: "weg").path)
            #expect(AgentConfigReader.read(path: link.path, home: .init(dir.path)) == .missing)
        }
    }

    /// Ein Pfad, der nur wörtlich im Home liegt, per `..` aber hinausführt, gilt als Verweis aus dem Home heraus.
    @Test func refusesDotDotLeavingHome() throws {
        try ScratchDirectory.with { outside in
            try ScratchDirectory.with { home in
                try Data("{}".utf8).write(to: outside.appending(path: "secret.json"))
                let path = home.path + "/../" + outside.lastPathComponent + "/secret.json"
                #expect(AgentConfigReader.read(path: path, home: .init(home.path)) == .unreadable("verweist aus dem Benutzerordner heraus"))
            }
        }
    }

    @Test func readsFilesOutsideHomeDirectly() throws {
        try ScratchDirectory.with { outside in
            try ScratchDirectory.with { home in
                let file = outside.appending(path: "project.json")
                try Data("{}".utf8).write(to: file)
                guard case .contents = AgentConfigReader.read(path: file.path, home: .init(home.path)) else {
                    Issue.record("Dateien außerhalb des Homes (Projekte) sind lesbar")
                    return
                }
            }
        }
    }

    /// Ein Socket wird gar nicht erst geöffnet (`open` schlüge sonst mit `EOPNOTSUPP` fehl): Vorprüfung per `stat`.
    @Test func rejectsSocketWithoutOpening() throws {
        try ScratchDirectory.with { dir in
            let path = dir.appending(path: "s").path
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            #expect(fd >= 0)
            defer { close(fd) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            try #require(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.copyBytes(from: bytes)
                buffer[bytes.count] = 0
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            try #require(bound == 0)
            #expect(AgentConfigReader.read(path: path, home: .init(dir.path)) == .unreadable("keine reguläre Datei"))
        }
    }

    /// Home in Firmlink-Schreibweise (`/System/Volumes/Data/…`): `realpath` behält sie, `F_GETPATH` nicht – beide Seiten
    /// werden daher gleich (per `F_GETPATH`) aufgelöst.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/System/Volumes/Data/private/var")))
    func homeInFirmlinkSpellingIsInsideHome() throws {
        try ScratchDirectory.with { dir in
            let home = "/System/Volumes/Data" + (try #require(AgentConfigReader.canonicalPath(dir.path)))
            let file = dir.appending(path: "a.json")
            try Data("{}".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            #expect(AgentConfigReader.read(path: home + "/a.json", home: .init(home)) == .contents(Data("{}".utf8), mode: 0o600))
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/System/Volumes/Data/private/var")))
    func symlinkLeavingFirmlinkSpelledHomeIsRefused() throws {
        try ScratchDirectory.with { outside in
            try ScratchDirectory.with { dir in
                let home = "/System/Volumes/Data" + (try #require(AgentConfigReader.canonicalPath(dir.path)))
                let target = outside.appending(path: "secret.json")
                try Data("{}".utf8).write(to: target)
                try FileManager.default.createSymbolicLink(at: dir.appending(path: "mcp.json"), withDestinationURL: target)
                #expect(AgentConfigReader.read(path: home + "/mcp.json", home: .init(home))
                    == .unreadable("verweist aus dem Benutzerordner heraus"))
            }
        }
    }

    @Test func rejectsFIFO() throws {
        try ScratchDirectory.with { dir in
            let fifo = dir.appending(path: "fifo")
            #expect(mkfifo(fifo.path, 0o600) == 0)
            #expect(AgentConfigReader.read(path: fifo.path, home: .init(dir.path)) == .unreadable("keine reguläre Datei"))
        }
    }
}
