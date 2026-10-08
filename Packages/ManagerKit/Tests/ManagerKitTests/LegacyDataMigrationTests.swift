import Foundation
import Testing
import ManagerKit
import TestSupport

@Suite struct LegacyDataMigrationTests {
    private struct MoveFailed: Error {}

    /// Dateien eines typischen alten Ablageorts mit ihrem Inhalt.
    private static let legacyFiles = [
        "History.store": "store",
        "History.store-wal": "wal",
        "History.store-shm": "shm",
        "Receipts.json": "[]",
        "Backups/20260926-120000-000/LaunchAgents/com.example.agent.plist": "plist",
        "Instance.lock": "running 1\n",
    ]

    /// Alter und neuer Ablageort in einem frischen Verzeichnis; der neue liegt in einem noch fehlenden Unterordner.
    private func withDirectories(_ body: (_ legacy: URL, _ current: URL) throws -> Void) throws {
        try ScratchDirectory.with(prefix: "legacy-migration") { root in
            try body(
                root.appending(path: "MacManager", directoryHint: .isDirectory),
                root.appending(path: "Support/Grantry", directoryHint: .isDirectory)
            )
        }
    }

    private func writeLegacyFiles(to directory: URL) throws {
        for (path, contents) in Self.legacyFiles {
            let url = directory.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
    }

    private func contents(of directory: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for path in Self.legacyFiles.keys {
            result[path] = try String(contentsOf: directory.appending(path: path), encoding: .utf8)
        }
        return result
    }

    private func migration(
        legacy: URL, current: URL, legacyDefaults: (any SettingsStore)? = nil, defaults: any SettingsStore = InMemorySettingsStore(),
        move: ((URL, URL) throws -> Void)? = nil, legacyApp: LegacyAppProbe = LegacyAppProbe(running: false)
    ) -> LegacyDataMigration {
        LegacyDataMigration(
            legacyDirectory: legacy, currentDirectory: current, legacyDefaults: legacyDefaults, defaults: defaults,
            isLegacyAppRunning: { legacyApp.isRunning }, quitLegacyApp: { legacyApp.quit() }, quitTimeout: .zero, move: move
        )
    }

    /// Alte App, die sich auf Aufforderung beendet (`quits`) oder weiterläuft.
    final class LegacyAppProbe: @unchecked Sendable {
        private(set) var isRunning: Bool
        private(set) var quitRequests = 0
        private let quits: Bool

        init(running: Bool, quits: Bool = true) {
            isRunning = running
            self.quits = quits
        }

        func quit() {
            quitRequests += 1
            if quits { isRunning = false }
        }
    }

    @Test func movesTheLegacyDirectoryWithAllFiles() throws {
        try withDirectories { legacy, current in
            try writeLegacyFiles(to: legacy)
            #expect(migration(legacy: legacy, current: current).migrateStorage() == .moved)
            #expect(try contents(of: current) == Self.legacyFiles)
            #expect(!FileManager.default.fileExists(atPath: legacy.path))
        }
    }

    @Test func runsOnlyOnce() throws {
        try withDirectories { legacy, current in
            try writeLegacyFiles(to: legacy)
            let migration = migration(legacy: legacy, current: current)
            #expect(migration.migrateStorage() == .moved)
            #expect(migration.migrateStorage() == .nothingToMigrate)
        }
    }

    @Test func keepsBothDirectoriesWhenTheNewOneExists() throws {
        try withDirectories { legacy, current in
            try writeLegacyFiles(to: legacy)
            try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
            try Data("neu".utf8).write(to: current.appending(path: "Receipts.json"))

            #expect(migration(legacy: legacy, current: current).migrateStorage() == .alreadyMigrated)
            #expect(try contents(of: legacy) == Self.legacyFiles)
            #expect(try String(contentsOf: current.appending(path: "Receipts.json"), encoding: .utf8) == "neu")
        }
    }

    @Test func doesNothingWithoutALegacyDirectory() throws {
        try withDirectories { legacy, current in
            #expect(migration(legacy: legacy, current: current).migrateStorage() == .nothingToMigrate)
            #expect(!FileManager.default.fileExists(atPath: current.path))
        }
    }

    @Test func ignoresALegacyFile() throws {
        try withDirectories { legacy, current in
            try Data("kein Ordner".utf8).write(to: legacy)
            #expect(migration(legacy: legacy, current: current).migrateStorage() == .nothingToMigrate)
            #expect(FileManager.default.fileExists(atPath: legacy.path))
        }
    }

    @Test func failedMoveKeepsTheLegacyDirectory() throws {
        try withDirectories { legacy, current in
            try writeLegacyFiles(to: legacy)
            let outcome = migration(legacy: legacy, current: current) { _, _ in throw MoveFailed() }.migrateStorage()

            guard case .failed = outcome else {
                Issue.record("Erwartet .failed, erhalten \(outcome)")
                return
            }
            #expect(try contents(of: legacy) == Self.legacyFiles)
            #expect(!FileManager.default.fileExists(atPath: current.path))
        }
    }

    @Test func quitsARunningLegacyAppBeforeMoving() throws {
        try withDirectories { legacy, current in
            try writeLegacyFiles(to: legacy)
            let app = LegacyAppProbe(running: true)

            #expect(migration(legacy: legacy, current: current, legacyApp: app).migrateStorage() == .moved)
            #expect(app.quitRequests == 1)
            #expect(try contents(of: current) == Self.legacyFiles)
        }
    }

    @Test func movesNothingWhileTheLegacyAppKeepsRunning() throws {
        try withDirectories { legacy, current in
            try writeLegacyFiles(to: legacy)
            let app = LegacyAppProbe(running: true, quits: false)

            #expect(migration(legacy: legacy, current: current, legacyApp: app).migrateStorage() == .legacyAppRunning)
            #expect(try contents(of: legacy) == Self.legacyFiles)
            #expect(!FileManager.default.fileExists(atPath: current.path))
        }
    }

    @Test func leavesTheLegacyAppAloneWithoutLegacyData() throws {
        try withDirectories { legacy, current in
            let app = LegacyAppProbe(running: true)

            #expect(migration(legacy: legacy, current: current, legacyApp: app).migrateStorage() == .nothingToMigrate)
            #expect(app.quitRequests == 0)
        }
    }

    @Test func copiesMissingDefaults() throws {
        try withDirectories { legacy, current in
            let legacyDefaults = InMemorySettingsStore()
            let defaults = InMemorySettingsStore()
            legacyDefaults.set(true, forKey: OnboardingModel.completedKey)
            legacyDefaults.set("egal", forKey: "NSWindow Frame main")
            let migration = migration(legacy: legacy, current: current, legacyDefaults: legacyDefaults, defaults: defaults)

            #expect(migration.migrateDefaults() == [OnboardingModel.completedKey])
            #expect(defaults.bool(forKey: OnboardingModel.completedKey))
            #expect(defaults.object(forKey: "NSWindow Frame main") == nil)
            #expect(migration.migrateDefaults().isEmpty)
        }
    }

    @Test func neverOverwritesExistingDefaults() throws {
        try withDirectories { legacy, current in
            let legacyDefaults = InMemorySettingsStore()
            let defaults = InMemorySettingsStore()
            legacyDefaults.set(true, forKey: OnboardingModel.completedKey)
            defaults.set(false, forKey: OnboardingModel.completedKey)
            let migration = migration(legacy: legacy, current: current, legacyDefaults: legacyDefaults, defaults: defaults)

            #expect(migration.migrateDefaults().isEmpty)
            #expect(!defaults.bool(forKey: OnboardingModel.completedKey))
        }
    }

    @Test func withoutLegacyDefaultsNothingIsCopied() throws {
        try withDirectories { legacy, current in
            let defaults = InMemorySettingsStore()
            #expect(migration(legacy: legacy, current: current, legacyDefaults: nil, defaults: defaults).migrateDefaults().isEmpty)
            #expect(defaults.object(forKey: OnboardingModel.completedKey) == nil)
        }
    }

    @Test func legacyIdentifiersMatchTheOldApp() {
        #expect(LegacyDataMigration.legacyBundleID == "de.cstrube.MacManager")
        #expect(LegacyDataMigration.legacyDirectoryName == "MacManager")
        #expect(LegacyDataMigration.migratedDefaultsKeys == [OnboardingModel.completedKey])
    }
}
