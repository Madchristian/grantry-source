import Darwin
import Foundation
import Testing
@testable import ManagerKit
import TestSupport

@Suite struct LaunchdSearchPathTests {
    @Test func standardPathIsLaunchdsDefault() {
        #expect(LaunchdSearchPath.standardDirectories == ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        #expect(LaunchdSearchPath.executable(named: "python3") == "/usr/bin/python3")
        #expect(LaunchdSearchPath.executable(named: "grantry-missing-program") == nil)
    }

    /// Wie `execvp`: das erste Verzeichnis mit einer ausführbaren regulären Datei des Namens. Nicht ausführbare
    /// Dateien, Verzeichnisse und FIFOs werden übersprungen.
    @Test func findsTheFirstExecutableRegularFile() throws {
        try ScratchDirectory.with(prefix: "search-path") { root in
            let directories = try ["a", "b", "c", "d", "e"].map { name in
                let directory = root.appending(path: name)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                return directory
            }
            try Data("x".utf8).write(to: directories[0].appending(path: "tool"))
            try FileManager.default.createDirectory(at: directories[1].appending(path: "tool"), withIntermediateDirectories: true)
            _ = try FIFOFixture.make(in: directories[2], named: "tool")
            let executable = directories[3].appending(path: "tool")
            try Data("x".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let found = LaunchdSearchPath.executable(named: "tool", in: directories.map(\.path))
            #expect(found == executable.path)
            #expect(LaunchdSearchPath.executable(named: "tool", in: [directories[4].path]) == nil)
        }
    }
}
