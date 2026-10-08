import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct AgentContentStampTests {
    /// Claude Code schreibt `~/.claude.json` laufend (Statistiken): Nur geänderte Server/Freigaben ändern den Stempel.
    @Test func unrelatedChangesKeepTheStamp() throws {
        try ScratchDirectory.with { home in
            let file = home.appending(path: ".claude.json")
            try Data(#"{"numStartups": 1, "mcpServers": {"a": {"command": "a"}}}"#.utf8).write(to: file)
            let stamps = AgentConfigSource.contentStamps(catalog: TestData.userCatalog, home: home.path)
            let stamp = try #require(stamps[file.path])
            let first = stamp()
            try Data(#"{"numStartups": 2, "tipsHistory": {}, "mcpServers": {"a": {"command": "a"}}}"#.utf8).write(to: file)
            #expect(stamp() == first)
            try Data(#"{"numStartups": 2, "mcpServers": {"a": {"command": "a"}, "b": {"command": "b"}}}"#.utf8).write(to: file)
            #expect(stamp() != first)
        }
    }

    /// Werte unter `env` liest der Parser nie – ihre Änderung ändert den Stempel nicht.
    @Test func secretValueChangesDoNotChangeTheStamp() throws {
        try ScratchDirectory.with { home in
            let file = home.appending(path: ".cursor/mcp.json")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"mcpServers": {"a": {"command": "a", "env": {"K": "1"}}}}"#.utf8).write(to: file)
            let stamp = try #require(AgentConfigSource.contentStamps(catalog: TestData.userCatalog, home: home.path)[file.path])
            let first = stamp()
            try Data(#"{"mcpServers": {"a": {"command": "a", "env": {"K": "geändert"}}}}"#.utf8).write(to: file)
            #expect(stamp() == first)
        }
    }

    /// Der Stempel parst mit derselben Regel wie der Scan: Ein Server namens `env` (auch im Projektobjekt) zählt mit.
    @Test func serversNamedLikeRedactedKeysChangeTheStamp() throws {
        try ScratchDirectory.with { home in
            let file = home.appending(path: ".claude.json")
            try Data(#"{"projects": {"/p": {"mcpServers": {"env": {"command": "a"}}}}}"#.utf8).write(to: file)
            let stamp = try #require(AgentConfigSource.contentStamps(catalog: TestData.userCatalog, home: home.path)[file.path])
            let first = stamp()
            try Data(#"{"projects": {"/p": {"mcpServers": {"env": {"command": "/tmp/x"}}}}}"#.utf8).write(to: file)
            #expect(stamp() != first)
        }
    }

    @Test func missingFileHasNoStampAndAppearingFileHasOne() throws {
        try ScratchDirectory.with { home in
            let file = home.appending(path: ".cursor/mcp.json")
            let stamp = try #require(AgentConfigSource.contentStamps(catalog: TestData.userCatalog, home: home.path)[file.path])
            #expect(stamp() == nil)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"mcpServers": {}}"#.utf8).write(to: file)
            #expect(stamp() != nil)
        }
    }

    /// Eine nicht parsebare Datei hat einen eigenen Stempel (Einschränkung), ihre Reparatur ändert ihn wieder.
    @Test func unparsableFileChangesTheStamp() throws {
        try ScratchDirectory.with { home in
            let file = home.appending(path: ".cursor/mcp.json")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"mcpServers": {"a": {"command": "a"}}}"#.utf8).write(to: file)
            let stamp = try #require(AgentConfigSource.contentStamps(catalog: TestData.userCatalog, home: home.path)[file.path])
            let valid = stamp()
            try Data(#"{"mcpServers": {"a": "#.utf8).write(to: file)
            let broken = stamp()
            #expect(broken != nil)
            #expect(broken != valid)
        }
    }

    /// Ein neu registriertes Projekt kann eine Projektdatei mitbringen: Seine Registrierung ändert den Stempel.
    @Test func newlyRegisteredProjectChangesTheStamp() throws {
        try ScratchDirectory.with { home in
            let file = home.appending(path: ".claude.json")
            try Data(#"{"projects": {"/p/one": {}}}"#.utf8).write(to: file)
            let stamp = try #require(AgentConfigSource.contentStamps(catalog: TestData.userCatalog, home: home.path)[file.path])
            let first = stamp()
            try Data(#"{"projects": {"/p/one": {"lastCost": 1}}}"#.utf8).write(to: file)
            #expect(stamp() == first)
            try Data(#"{"projects": {"/p/one": {}, "/p/two": {}}}"#.utf8).write(to: file)
            #expect(stamp() != first)
        }
    }

    /// Freigabelisten der Projektdatei (`enabledMcpjsonServers` …) im Projektobjekt ändern den Stempel, Statistiken
    /// daneben nicht. Die Pfade kommen aus `ProjectFile`.
    @Test func projectApprovalListsChangeTheStamp() throws {
        try ScratchDirectory.with { home in
            let file = home.appending(path: ".claude.json")
            try Data(#"{"projects": {"/p/one": {"lastCost": 1}}}"#.utf8).write(to: file)
            let stamp = try #require(AgentConfigSource.contentStamps(catalog: TestData.userCatalog, home: home.path)[file.path])
            let first = stamp()
            try Data(#"{"projects": {"/p/one": {"lastCost": 22}}}"#.utf8).write(to: file)
            #expect(stamp() == first)
            try Data(#"{"projects": {"/p/one": {"lastCost": 22, "enabledMcpjsonServers": ["a"]}}}"#.utf8).write(to: file)
            let enabled = stamp()
            #expect(enabled != first)
            try Data(#"{"projects": {"/p/one": {"lastCost": 22, "disabledMcpjsonServers": ["a"]}}}"#.utf8).write(to: file)
            #expect(stamp() != enabled)
            try Data(#"{"projects": {"/p/one": {"lastCost": 22, "enableAllProjectMcpServers": true}}}"#.utf8).write(to: file)
            #expect(stamp() != first)
        }
    }

    /// Globale Namenslisten (`~/.claude/settings.json`) bestimmen die Freigabe der `.mcp.json`-Server mit.
    @Test func globalServerApprovalListsChangeTheStamp() throws {
        try ScratchDirectory.with { home in
            let file = home.appending(path: ".claude/settings.json")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"model": "a"}"#.utf8).write(to: file)
            let stamp = try #require(AgentConfigSource.contentStamps(catalog: TestData.userCatalog, home: home.path)[file.path])
            let first = stamp()
            try Data(#"{"model": "bbb"}"#.utf8).write(to: file)
            #expect(stamp() == first)
            try Data(#"{"model": "bbb", "disabledMcpjsonServers": ["x"]}"#.utf8).write(to: file)
            let disabled = stamp()
            #expect(disabled != first)
            try Data(#"{"model": "bbb", "enabledMcpjsonServers": ["xy"]}"#.utf8).write(to: file)
            #expect(stamp() != disabled)
        }
    }

    /// Bei unverändertem Fingerabdruck wird der Stempel nicht neu gerechnet, bei geändertem schon.
    @Test func stampIsRecomputedOnlyWhenTheFingerprintChanges() throws {
        try ScratchDirectory.with { home in
            let file = home.appending(path: ".claude.json")
            try Data(#"{"numStartups": 1}"#.utf8).write(to: file)
            let calls = Mutex(0)
            let stamper = AgentConfigSource.ContentStamper(home: home.path) { _, _, _ in
                calls.withLock { $0 += 1 }
                return 7
            }
            let tool = try #require(TestData.userCatalog.tools.first { tool in
                tool.files.contains { $0.expandedPath(home: home.path) == file.path }
            })
            let configFile = try #require(tool.files.first { $0.expandedPath(home: home.path) == file.path })
            #expect(stamper.stamp(configFile, of: tool) == 7)
            #expect(stamper.stamp(configFile, of: tool) == 7)
            #expect(calls.withLock { $0 } == 1)
            try Data(#"{"numStartups": 22}"#.utf8).write(to: file)
            #expect(stamper.stamp(configFile, of: tool) == 7)
            #expect(calls.withLock { $0 } == 2)
            try FileManager.default.removeItem(at: file)
            #expect(stamper.stamp(configFile, of: tool) == nil)
            #expect(calls.withLock { $0 } == 2)
        }
    }

    /// Lockerere Dateirechte (`o+w`) zählen wie im Scan (`configFileMode`).
    @Test func permissionChangesChangeTheStamp() throws {
        try ScratchDirectory.with { home in
            let file = home.appending(path: ".cursor/mcp.json")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"mcpServers": {"a": {"command": "a"}}}"#.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let stamp = try #require(AgentConfigSource.contentStamps(catalog: TestData.userCatalog, home: home.path)[file.path])
            let first = stamp()
            try FileManager.default.setAttributes([.posixPermissions: 0o602], ofItemAtPath: file.path)
            #expect(stamp() != first)
        }
    }

    /// Ist die Konfiguration ein Symlink, zählt der Fingerabdruck des Ziels: Eine Änderung am Ziel ändert den Stempel.
    @Test func changesBehindASymlinkChangeTheStamp() throws {
        try ScratchDirectory.with { home in
            let dotfiles = home.appending(path: "dotfiles/mcp.json")
            try FileManager.default.createDirectory(at: dotfiles.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"mcpServers": {"a": {"command": "a"}}}"#.utf8).write(to: dotfiles)
            let file = home.appending(path: ".cursor/mcp.json")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: dotfiles)
            let stamp = try #require(AgentConfigSource.contentStamps(catalog: TestData.userCatalog, home: home.path)[file.path])
            let first = stamp()
            #expect(first != nil)
            try Data(#"{"mcpServers": {"a": {"command": "a"}, "b": {"command": "b"}}}"#.utf8).write(to: dotfiles)
            #expect(stamp() != first)
        }
    }
}
