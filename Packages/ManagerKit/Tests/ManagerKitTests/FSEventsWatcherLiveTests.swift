import Testing
import Foundation
import TestSupport
@testable import ManagerKit

private struct NoSignal: Error {}

/// Opt-in-Test gegen echtes FSEvents; läuft nur mit `MANAGERKIT_LIVE=1`, weil er echte Wartezeiten hat.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MANAGERKIT_LIVE"] == "1"))
struct FSEventsWatcherLiveTests {
    @Test func signalsFileCreationWithinFiveSeconds() async throws {
        try await ScratchDirectory.with(prefix: "fsevents") { directory in
            let changes = FSEventsWatcher().changes(in: [directory.path])
            try Data("x".utf8).write(to: directory.appending(path: "new.txt"))
            try await expectSignal(from: changes, within: .seconds(5))
        }
    }

    /// Ohne Datei-Ereignisse meldet FSEvents Verzeichnisse: Änderungen in einem Geschwisterordner des Ziels zählen nicht.
    @Test func ignoresChangesInSiblingDirectories() async throws {
        try await ScratchDirectory.with(prefix: "fsevents") { directory in
            let agents = directory.appending(path: "LaunchAgents")
            let other = directory.appending(path: "Other")
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            let changes = FSEventsWatcher().changes(in: [agents.path])
            try Data("x".utf8).write(to: other.appending(path: "unrelated.txt"))
            await #expect(throws: NoSignal.self) {
                try await expectSignal(from: changes, within: .seconds(2))
            }
        }
    }

    /// Ein anfangs fehlendes Verzeichnis wird über den Elternordner beobachtet; fremde Änderungen in dessen anderen
    /// Unterordnern zählen nicht, sein Anlegen samt Inhalt schon.
    @Test func signalsCreationOfInitiallyMissingDirectory() async throws {
        try await ScratchDirectory.with(prefix: "fsevents") { directory in
            let agents = directory.appending(path: "Library/LaunchAgents")
            let other = directory.appending(path: "Other")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            // Solange das Ziel fehlt, zählen Änderungen im Elternordner – auch das eben erfolgte Anlegen der
            // Verzeichnisse, wenn FSEvents es erst nach dem Start des Streams meldet. Deshalb kurz zur Ruhe kommen.
            try await Task.sleep(for: .seconds(1))
            let unrelatedChanges = FSEventsWatcher().changes(in: [agents.path])
            try Data("x".utf8).write(to: other.appending(path: "unrelated.txt"))
            await #expect(throws: NoSignal.self) {
                try await expectSignal(from: unrelatedChanges, within: .seconds(2))
            }
            // Ein abgebrochener Konsument beendet den Strom, deshalb ein frischer Watcher.
            let changes = FSEventsWatcher().changes(in: [agents.path])
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: agents.appending(path: "agent.plist"))
            try await expectSignal(from: changes, within: .seconds(5))
        }
    }

    /// Eine anfangs fehlende Datei: Nachbardateien lösen nichts aus, ihr Erscheinen und eine spätere Änderung schon.
    @Test func signalsAppearanceAndChangeOfInitiallyMissingFile() async throws {
        try await ScratchDirectory.with(prefix: "fsevents") { directory in
            let file = directory.appending(path: "com.apple.networkextension.plist")
            try await Task.sleep(for: .seconds(1))
            let changes = FSEventsWatcher().changes(in: [], files: [file.path])
            try Data("n".utf8).write(to: directory.appending(path: "neighbor.plist"))
            await #expect(throws: NoSignal.self) {
                try await expectSignal(from: changes, within: .seconds(2))
            }
            let appearing = FSEventsWatcher().changes(in: [], files: [file.path])
            try Data("1".utf8).write(to: file)
            try await expectSignal(from: appearing, within: .seconds(5))
            try await Task.sleep(for: .seconds(1))
            let changing = FSEventsWatcher().changes(in: [], files: [file.path])
            try Data("2".utf8).write(to: file)
            try await expectSignal(from: changing, within: .seconds(5))
        }
    }

    /// #279: Konfigurationsdateien direkt im Home und in einem fehlenden Home-Ordner. Viele fremde Dateien im Home
    /// lösen nichts aus; das Anlegen der fehlenden Datei und der atomare Austausch der vorhandenen schon.
    @Test func homeConfigFilesSignalDespiteUnrelatedHomeActivity() async throws {
        try await ScratchDirectory.with(prefix: "fsevents") { home in
            let config = home.appending(path: ".claude.json")
            let missing = home.appending(path: ".cursor/mcp.json")
            let simulator = home.appending(path: "Library/Developer/CoreSimulator")
            try FileManager.default.createDirectory(at: simulator, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: config)
            try await Task.sleep(for: .seconds(1))
            let files = [config.path, missing.path]
            let quiet = FSEventsWatcher().changes(in: [], files: files)
            for index in 0..<200 {
                try Data("\(index)".utf8).write(to: simulator.appending(path: "device-\(index).log"))
            }
            try Data("x".utf8).write(to: home.appending(path: ".claude.json.backup"))
            await #expect(throws: NoSignal.self) {
                try await expectSignal(from: quiet, within: .seconds(2))
            }
            let appearing = FSEventsWatcher().changes(in: [], files: files)
            try FileManager.default.createDirectory(at: missing.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: missing)
            try await expectSignal(from: appearing, within: .seconds(5))
            try await Task.sleep(for: .seconds(1))
            let replacing = FSEventsWatcher().changes(in: [], files: files)
            try Data("{\"mcpServers\":{}}".utf8).write(to: config, options: .atomic)
            try await expectSignal(from: replacing, within: .seconds(5))
        }
    }

    /// App-Ordner: Ein Hersteller, der in seinen Unterordner schreibt (iCUE), löst nichts aus; eine neue App schon.
    @Test func appFolderSignalsOnlyBundleChanges() async throws {
        try await ScratchDirectory.with(prefix: "fsevents") { directory in
            let vendor = directory.appending(path: "Vendor Software")
            try FileManager.default.createDirectory(at: vendor.appending(path: "Tool.app/Contents"), withIntermediateDirectories: true)
            try await Task.sleep(for: .seconds(1))
            let quiet = FSEventsWatcher().changes(in: [], files: [], shallowPaths: [directory.path])
            try Data("log".utf8).write(to: vendor.appending(path: "service.log"))
            await #expect(throws: NoSignal.self) {
                try await expectSignal(from: quiet, within: .seconds(2))
            }
            let changes = FSEventsWatcher().changes(in: [], files: [], shallowPaths: [directory.path])
            try FileManager.default.createDirectory(at: directory.appending(path: "New.app/Contents"), withIntermediateDirectories: true)
            try await expectSignal(from: changes, within: .seconds(5))
        }
    }

    /// Der Pfad wäre nur über `/` zu beobachten – das wird verweigert, der Strom endet sofort.
    @Test func refusesPathsThatWouldRequireWatchingTheRoot() async {
        var changes = FSEventsWatcher().changes(in: ["/gibt-es-nicht-\(UUID().uuidString)/x"]).makeAsyncIterator()
        #expect(await changes.next() == nil)
    }
}

/// Wartet höchstens `timeout` auf ein Signal aus `changes`; sonst `NoSignal`.
private func expectSignal(from changes: AsyncStream<String>, within timeout: Duration) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            for await _ in changes { return }
            throw NoSignal()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw NoSignal()
        }
        defer { group.cancelAll() }
        try await group.next()
    }
}
