import Darwin
import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct AgentConfigBackupStoreTests {
    private func change(
        _ path: String = "/Users/test/.cursor/mcp.json", at seconds: TimeInterval = 0, kind: AgentConfigChange.Kind = .removedServer,
        original: Data = Data("{}".utf8)
    ) -> AgentConfigChange {
        AgentConfigChange(
            id: UUID(), kind: kind,
            server: AgentServerReference(toolID: "cursor", toolName: "Cursor", configPath: path, registryPath: nil, scope: .user, name: "x"),
            changedAt: Date(timeIntervalSince1970: seconds), originalDigest: AgentConfigFileAccess.digest(of: original),
            resultDigest: "egal"
        )
    }

    private func permissions(of path: String) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
    }

    private func entries(of url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    private func grant(_ entry: String, to path: String) throws {
        try AccessControlFixture.grant(entry, to: path)
    }

    /// Ob `path` (ohne Symlink-Auflösung) eine ACL mit mindestens einem Allow-Eintrag trägt – unabhängig vom Code der Ablage.
    private func grantsAccess(_ path: String) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        return String(cString: acl_to_text(acl, nil)).contains(":allow")
    }

    @Test func savesPrivatelyAndReadsBack() throws {
        try ScratchDirectory.with { directory in
            let store = AgentConfigBackupStore(root: directory.appending(path: "AgentBackups"))
            let saved = change()
            try store.save(saved, original: Data("{}".utf8))
            #expect(store.changes() == [saved])
            #expect(try store.original(of: saved) == Data("{}".utf8))
            let folder = store.root.appending(path: saved.id.uuidString).path
            #expect(try permissions(of: store.root.path) == 0o700)
            #expect(try permissions(of: folder) == 0o700)
            #expect(try permissions(of: folder + "/original") == 0o600)
            #expect(try permissions(of: folder + "/change.json") == 0o600)
            #expect(try entries(of: store.root) == [saved.id.uuidString])
            #expect(try store.root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
            store.delete(id: saved.id)
            #expect(store.changes().isEmpty)
        }
    }

    @Test func ignoresUntrustedOrDamagedBackups() throws {
        try ScratchDirectory.with { directory in
            let store = AgentConfigBackupStore(root: directory.appending(path: "AgentBackups"))
            let saved = change()
            try store.save(saved, original: Data("{}".utf8))
            let folder = store.root.appending(path: saved.id.uuidString).path
            let original = folder + "/original"
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: original)
            #expect(throws: AgentConfigEditError.backupUnusable("fehlt oder ist nicht vertrauenswürdig")) { try store.original(of: saved) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: original)
            try Data("{ }".utf8).write(to: URL(filePath: original))
            #expect(throws: AgentConfigEditError.backupUnusable("Prüfsumme passt nicht")) { try store.original(of: saved) }
            // Ein Symlink als Beleg wird nicht verfolgt, ein zu großer nicht gelesen.
            let receipt = folder + "/change.json"
            try FileManager.default.moveItem(atPath: receipt, toPath: folder + "/elsewhere.json")
            try FileManager.default.createSymbolicLink(atPath: receipt, withDestinationPath: folder + "/elsewhere.json")
            #expect(store.change(id: saved.id) == nil)
            try FileManager.default.removeItem(atPath: receipt)
            try FileManager.default.moveItem(atPath: folder + "/elsewhere.json", toPath: receipt)
            #expect(store.change(id: saved.id) == saved)
            let padded = try Data(contentsOf: URL(filePath: receipt)) + Data(repeating: UInt8(ascii: " "), count: AgentConfigBackupStore.maximumChangeFileSize)
            try padded.write(to: URL(filePath: receipt))
            #expect(store.change(id: saved.id) == nil)
        }
    }

    /// Ein Beleg zählt nur in dem Ordner, dessen Name seine Kennung ist – eine Kopie unter anderem Namen nicht.
    @Test func ignoresReceiptsWhoseIDDoesNotMatchTheFolder() throws {
        try ScratchDirectory.with { directory in
            let store = AgentConfigBackupStore(root: directory.appending(path: "AgentBackups"))
            let saved = change()
            try store.save(saved, original: Data("{}".utf8))
            let other = UUID()
            try FileManager.default.copyItem(at: store.root.appending(path: saved.id.uuidString), to: store.root.appending(path: other.uuidString))
            #expect(store.change(id: other) == nil)
            #expect(store.changes() == [saved])
        }
    }

    /// Eine Ablage, die ein Symlink ist, wird nicht benutzt – nichts wird geschrieben, auch nicht am Ziel des Links.
    @Test func refusesASymlinkedRootWithoutWriting() throws {
        try ScratchDirectory.with { directory in
            let elsewhere = directory.appending(path: "elsewhere")
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let root = directory.appending(path: "AgentBackups")
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: elsewhere)
            let store = AgentConfigBackupStore(root: root)
            #expect(throws: AgentConfigEditError.backupUnusable("Ablage nicht vertrauenswürdig")) {
                try store.save(change(), original: Data("{}".utf8))
            }
            #expect(try entries(of: elsewhere).isEmpty)
            #expect(store.changes().isEmpty)
            store.sweep()
            #expect(try entries(of: elsewhere).isEmpty)
        }
    }

    /// Zu offene Rechte der eigenen Ablage werden auf `0700` repariert.
    @Test func repairsPermissionsOfItsOwnRoot() throws {
        try ScratchDirectory.with { directory in
            let root = directory.appending(path: "AgentBackups")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            let store = AgentConfigBackupStore(root: root)
            let saved = change()
            try store.save(saved, original: Data("{}".utf8))
            #expect(try permissions(of: root.path) == 0o700)
            #expect(store.changes() == [saved])
        }
    }

    /// Regression (Codex-Review 2026.10.6, #155): Eine vererbbare Allow-ACL eines Vorfahren macht aus `0700`/`0600`
    /// nichts Privates. Die Ablage – auch eine schon vorhandene eigene – und alles darin werden ohne ACL angelegt; eine
    /// Sicherung, die trotzdem eine gewährende ACL trägt, ist nicht vertrauenswürdig.
    @Test func stripsInheritedACLsAndRejectsGrantingOnes() throws {
        try ScratchDirectory.with { directory in
            try grant("user:nobody allow read,list,search,file_inherit,directory_inherit", to: directory.path)
            let root = directory.appending(path: "AgentBackups")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try #require(grantsAccess(root.path), "Die ACL wird nicht vererbt – Testaufbau unbrauchbar")
            let store = AgentConfigBackupStore(root: root)
            let saved = change()
            try store.save(saved, original: Data("{}".utf8))
            let folder = root.appending(path: saved.id.uuidString).path
            for path in [root.path, folder, folder + "/original", folder + "/change.json"] {
                #expect(!grantsAccess(path), Comment(rawValue: path))
                #expect(try permissions(of: path) == (path.hasSuffix("original") || path.hasSuffix("change.json") ? 0o600 : 0o700))
            }
            #expect(store.changes() == [saved])
            #expect(try store.original(of: saved) == Data("{}".utf8))

            try grant("user:nobody allow read", to: folder + "/original")
            #expect(throws: AgentConfigEditError.backupUnusable("fehlt oder ist nicht vertrauenswürdig")) { try store.original(of: saved) }
            try grant("user:nobody allow read,list,search", to: folder)
            #expect(store.change(id: saved.id) == nil)
            #expect(store.changes().isEmpty)
            // Eine Deny-ACL gewährt nichts.
            let denied = change()
            try store.save(denied, original: Data("{}".utf8))
            try grant("everyone deny write", to: root.appending(path: denied.id.uuidString).appending(path: "original").path)
            #expect(try store.original(of: denied) == Data("{}".utf8))
        }
    }

    @Test func keepsTheNewestBackupsPerFile() throws {
        try ScratchDirectory.with { directory in
            let store = AgentConfigBackupStore(root: directory.appending(path: "AgentBackups"), now: { Date(timeIntervalSince1970: 100) })
            let changes = (0..<7).map { change(at: TimeInterval($0)) }
            for change in changes {
                try store.save(change, original: Data("{}".utf8))
                store.commit(change)
            }
            let other = change("/Users/test/.codex/config.toml", at: -1)
            try store.save(other, original: Data("{}".utf8))
            store.commit(other)
            #expect(store.changes() == Array(changes.reversed().prefix(AgentConfigBackupStore.retainedChangesPerFile)) + [other])
        }
    }

    /// Schalter-Sicherungen verdrängen die Sicherung eines entfernten Servers (mit seinen Geheimwerten) nicht: Je Datei
    /// gehen zuerst die ältesten Schalter-Belege.
    @Test func togglesDoNotEvictTheBackupOfARemovedServer() throws {
        try ScratchDirectory.with { directory in
            let store = AgentConfigBackupStore(root: directory.appending(path: "AgentBackups"), now: { Date(timeIntervalSince1970: 100) })
            let removed = change(at: 0, original: Data(#"{"mcpServers":{"x":{"env":{"TOKEN":"geheim"}}}}"#.utf8))
            try store.save(removed, original: Data(#"{"mcpServers":{"x":{"env":{"TOKEN":"geheim"}}}}"#.utf8))
            store.commit(removed)
            let toggles = (1...6).map { change(at: TimeInterval($0), kind: .setEnabled($0.isMultiple(of: 2))) }
            for toggle in toggles {
                try store.save(toggle, original: Data("{}".utf8))
                store.commit(toggle)
            }
            let remaining = store.changes()
            #expect(remaining.contains(removed))
            #expect(remaining == Array(toggles.reversed().prefix(AgentConfigBackupStore.retainedChangesPerFile - 1)) + [removed])
        }
    }

    /// Dieselbe Bevorzugung bei der Obergrenze über alle Dateien: Erst gehen Schalter-Belege, dann entfernte Server.
    @Test func togglesAreEvictedFirstFromTheTotal() throws {
        try ScratchDirectory.with { directory in
            let today: TimeInterval = 1_800_000_000
            let store = AgentConfigBackupStore(root: directory.appending(path: "AgentBackups"), now: { Date(timeIntervalSince1970: today) })
            let removed = change("/Users/test/old.json", at: today - 3600)
            let toggles = (0..<AgentConfigBackupStore.retainedChangesInTotal).map { index in
                change("/Users/test/\(index).json", at: today - TimeInterval(index), kind: .setEnabled(true))
            }
            for change in [removed] + toggles { try store.save(change, original: Data("{}".utf8)) }
            let kept = store.sweep()
            #expect(kept == Array(toggles.prefix(AgentConfigBackupStore.retainedChangesInTotal - 1)) + [removed])
            #expect(store.changes() == kept)
        }
    }

    /// Erst `commit` räumt auf: Scheitert die Änderung nach dem Sichern, bleiben alle älteren Sicherungen.
    @Test func savingAloneKeepsOlderBackups() throws {
        try ScratchDirectory.with { directory in
            let store = AgentConfigBackupStore(root: directory.appending(path: "AgentBackups"))
            let changes = (0..<AgentConfigBackupStore.retainedChangesPerFile + 1).map { change(at: TimeInterval($0)) }
            for change in changes { try store.save(change, original: Data("{}".utf8)) }
            #expect(store.changes() == changes.reversed())
        }
    }

    /// Verfallene Sicherungen verschwinden, insgesamt bleiben höchstens `retainedChangesInTotal` – die neuesten.
    @Test func expiresOldBackupsAndCapsTheTotal() throws {
        try ScratchDirectory.with { directory in
            let today: TimeInterval = 1_800_000_000
            let store = AgentConfigBackupStore(root: directory.appending(path: "AgentBackups"), now: { Date(timeIntervalSince1970: today) })
            let expired = change("/Users/test/a.json", at: today - AgentConfigBackupStore.retentionPeriod - 1)
            let fresh = change("/Users/test/b.json", at: today - AgentConfigBackupStore.retentionPeriod + 60)
            try store.save(expired, original: Data("{}".utf8))
            try store.save(fresh, original: Data("{}".utf8))
            store.sweep()
            #expect(store.changes() == [fresh])

            let many = (0..<AgentConfigBackupStore.retainedChangesInTotal + 4).map { index in
                change("/Users/test/\(index).json", at: today - TimeInterval(index))
            }
            for change in many { try store.save(change, original: Data("{}".utf8)) }
            store.commit(many[0])
            #expect(store.changes() == Array(many.prefix(AgentConfigBackupStore.retainedChangesInTotal)))
        }
    }

    /// `commit` behält die eben geschriebene Sicherung immer – auch wenn ihre Zeit (Uhr zurückgestellt) älter wäre als
    /// alle anderen oder als der Verfall.
    @Test func commitNeverRemovesTheCommittedBackup() throws {
        try ScratchDirectory.with { directory in
            let today: TimeInterval = 1_800_000_000
            let store = AgentConfigBackupStore(root: directory.appending(path: "AgentBackups"), now: { Date(timeIntervalSince1970: today) })
            let newer = (0..<AgentConfigBackupStore.retainedChangesInTotal).map { index in
                change("/Users/test/\(index).json", at: today - TimeInterval(index))
            }
            for change in newer { try store.save(change, original: Data("{}".utf8)) }
            let committed = change("/Users/test/x.json", at: today - AgentConfigBackupStore.retentionPeriod - 1)
            try store.save(committed, original: Data("{}".utf8))
            store.commit(committed)
            let remaining = store.changes()
            #expect(remaining.contains(committed))
            #expect(remaining.count == AgentConfigBackupStore.retainedChangesInTotal)
            #expect(!remaining.contains(newer[newer.count - 1]))
        }
    }

    /// Belege aus der Zukunft (vorgehende Uhr) zählen beim Aufräumen als die ältesten und verfallen, wenn sie weiter
    /// als die Aufbewahrungsfrist voraus liegen.
    @Test func treatsFutureBackupsAsOldest() throws {
        try ScratchDirectory.with { directory in
            let today: TimeInterval = 1_800_000_000
            let store = AgentConfigBackupStore(root: directory.appending(path: "AgentBackups"), now: { Date(timeIntervalSince1970: today) })
            let farFuture = change("/Users/test/f.json", at: today + AgentConfigBackupStore.retentionPeriod + 1)
            let nearFuture = change("/Users/test/n.json", at: today + 3600)
            let past = (0..<AgentConfigBackupStore.retainedChangesInTotal).map { index in
                change("/Users/test/\(index).json", at: today - TimeInterval(index))
            }
            for change in [farFuture, nearFuture] + past { try store.save(change, original: Data("{}".utf8)) }
            store.sweep()
            let remaining = Set(store.changes())
            #expect(!remaining.contains(farFuture))
            #expect(!remaining.contains(nearFuture))
            #expect(remaining == Set(past))
        }
    }

    /// Verschwindet der Ordner, während er gelesen wird (gerade wiederhergestellt oder aufgeräumt), ist der Beleg weg –
    /// keine verdorbene Sicherung.
    @Test func reportsAVanishedBackupAsNotFound() throws {
        try ScratchDirectory.with { directory in
            let store = AgentConfigBackupStore(root: directory.appending(path: "AgentBackups"))
            let saved = change()
            try store.save(saved, original: Data("{}".utf8))
            store.delete(id: saved.id)
            #expect(throws: AgentConfigEditError.changeNotFound) { try store.original(of: saved) }
        }
    }

    /// Reste eines Absturzes (`.partial`, Ordner ohne Beleg) verschwinden nach der Schonfrist; verdorbene Ordner mit
    /// Beleg bleiben.
    @Test func sweepsStalePartialAndReceiptlessFolders() throws {
        try ScratchDirectory.with { directory in
            let root = directory.appending(path: "AgentBackups")
            let fresh = AgentConfigBackupStore(root: root)
            let saved = change(at: Date().timeIntervalSince1970)
            try fresh.save(saved, original: Data("{}".utf8))
            let partial = root.appending(path: ".\(UUID().uuidString).partial")
            let receiptless = root.appending(path: UUID().uuidString)
            let damaged = root.appending(path: UUID().uuidString)
            for folder in [partial, receiptless, damaged] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try Data("{}".utf8).write(to: folder.appending(path: "original"))
            }
            try Data("{}".utf8).write(to: damaged.appending(path: "change.json"))
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: damaged.appending(path: "change.json").path)
            let before = try entries(of: root)

            fresh.sweep()
            #expect(try entries(of: root) == before)

            let later = AgentConfigBackupStore(root: root, now: { Date().addingTimeInterval(AgentConfigBackupStore.incompleteGracePeriod + 60) })
            later.sweep()
            #expect(try entries(of: root) == [damaged.lastPathComponent, saved.id.uuidString].sorted())
            #expect(later.changes() == [saved])
        }
    }
}
