import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct AppUsageStoreTests {
    /// Symlinkfreier Pfad: `PrivateDirectory` öffnet Ordner ohne Symlink-Auflösung (`/var` → `/private/var`).
    private func withStore(_ body: (AppUsageStore) throws -> Void) throws {
        try ScratchDirectory.withCanonical(prefix: "app-usage") { scratch in
            try body(AppUsageStore(url: scratch.appending(path: "Grantry/AppUsageHistory.json")))
        }
    }

    private func permissions(of url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    private func history() -> AppUsageHistory {
        var history = AppUsageHistory()
        history.add(AppUsageHistoryTests.sample(at: AppUsageHistoryTests.tenOClock, [
            (AppUsageHistoryTests.claude, AppUsageHistoryTests.totals(cpu: 12)),
        ]))
        return history
    }

    @Test func missingFileIsEmptyHistory() throws {
        try withStore { store in try #expect(store.load().isEmpty) }
    }

    @Test func savedHistoryLoadsAgainAndIsPrivate() throws {
        try withStore { store in
            try store.save(history())
            try #expect(store.load() == history())
            #expect(try permissions(of: store.url) == 0o600)
            #expect(try permissions(of: store.url.deletingLastPathComponent()) == 0o700)
        }
    }

    private func folderNames(of store: AppUsageStore) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path).sorted()
    }

    private func place(_ content: String, at store: AppUsageStore) throws {
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(content.utf8).write(to: store.url)
    }

    /// Eine unlesbare Datei wird beiseitegelegt statt beim nächsten Speichern ersetzt (#353).
    @Test func damagedFileIsSetAsideAndSurvivesTheNextSave() throws {
        try withStore { store in
            try place("kein JSON", at: store)
            let problem = try #require(throws: AppUsageLoadProblem.self) { try store.load() }
            guard case .setAside(let name) = problem else { Issue.record("\(problem)"); return }
            #expect(name.hasPrefix("AppUsageHistory.unreadable-") && name.hasSuffix(".json"))
            #expect(try folderNames(of: store) == [name])
            try store.save(history())
            let copy = store.url.deletingLastPathComponent().appending(path: name)
            #expect(try String(contentsOf: copy, encoding: .utf8) == "kein JSON")
            try #expect(store.load() == history())
        }
    }

    @Test func fileOfUnknownVersionIsSetAside() throws {
        try withStore { store in
            try place(#"{"version":99,"subjects":{},"hours":[]}"#, at: store)
            #expect(throws: AppUsageLoadProblem.self) { try store.load() }
            #expect(!FileManager.default.fileExists(atPath: store.url.path))
            #expect(try folderNames(of: store).count == 1)
        }
    }

    /// Lässt sich die unlesbare Datei nicht beiseitelegen (Ordner schreibgeschützt), meldet `load()` das eigens.
    @Test func unreadableFileThatCannotBeSetAsideIsReported() throws {
        try withStore { store in
            try place("kein JSON", at: store)
            let folder = store.url.deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
            let problem = try #require(throws: AppUsageLoadProblem.self) { try store.load() }
            guard case .unreadable = problem else { Issue.record("\(problem)"); return }
            #expect(FileManager.default.fileExists(atPath: store.url.path))
        }
    }

    @Test func removeAlsoDeletesSetAsideCopies() throws {
        try withStore { store in
            try place("kein JSON", at: store)
            _ = try? store.load()
            try store.save(history())
            try store.remove()
            #expect(try folderNames(of: store).isEmpty)
        }
    }

    /// Beiseitegelegte Fassungen unterliegen derselben Aufbewahrung von 30 Tagen wie der Verlauf.
    @Test func saveDeletesSetAsideCopiesOlderThanRetention() throws {
        try withStore { store in
            try place("kein JSON", at: store)
            let problem = try #require(throws: AppUsageLoadProblem.self) { try store.load() }
            guard case .setAside(let name) = problem else { Issue.record("\(problem)"); return }
            let copy = store.url.deletingLastPathComponent().appending(path: name)
            try store.save(history())
            #expect(FileManager.default.fileExists(atPath: copy.path))
            let expired = Date().addingTimeInterval(-AppUsageHistory.retention - 3_600)
            try FileManager.default.setAttributes([.modificationDate: expired], ofItemAtPath: copy.path)
            try store.save(history())
            #expect(try folderNames(of: store) == [store.url.lastPathComponent])
        }
    }

    @Test func removeDeletesFileAndToleratesMissingFile() throws {
        try withStore { store in
            try store.save(history())
            try store.remove()
            #expect(!FileManager.default.fileExists(atPath: store.url.path))
            try store.remove()
        }
    }

    @Test func removeToleratesMissingFolder() throws {
        try withStore { store in try store.remove() }
    }

    /// Eine Zwischendatei des atomaren Schreibens, wie sie ein Abbruch zwischen Anlegen und Umbenennen hinterließe.
    private func leftover(nextTo store: AppUsageStore) throws -> URL {
        let url = store.url.deletingLastPathComponent().appending(path: ".AppUsageHistory.json.\(UUID().uuidString)")
        try Data("Rest".utf8).write(to: url)
        return url
    }

    @Test func removeDeletesLeftoversOfInterruptedWritesButNoOtherFile() throws {
        try withStore { store in
            try store.save(history())
            let rest = try leftover(nextTo: store)
            let other = store.url.deletingLastPathComponent().appending(path: "CleanupLog.jsonl")
            try Data("fremd".utf8).write(to: other)
            try store.remove()
            #expect(!FileManager.default.fileExists(atPath: rest.path))
            #expect(!FileManager.default.fileExists(atPath: store.url.path))
            #expect(FileManager.default.fileExists(atPath: other.path))
        }
    }

    @Test func removeDeletesLeftoversEvenWithoutMainFile() throws {
        try withStore { store in
            try store.save(history())
            try FileManager.default.removeItem(at: store.url)
            let rest = try leftover(nextTo: store)
            try store.remove()
            #expect(!FileManager.default.fileExists(atPath: rest.path))
        }
    }

    @Test func saveSweepsStaleLeftoversAndLeavesNoneBehind() throws {
        try withStore { store in
            try store.save(history())
            let rest = try leftover(nextTo: store)
            try store.save(history())
            #expect(!FileManager.default.fileExists(atPath: rest.path))
            let names = try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path)
            #expect(names == [store.url.lastPathComponent])
        }
    }
}
