import Testing
import Foundation
import Synchronization
import TestSupport
@testable import GrantryShared

@Suite struct PlistBackupStoreTests {
    private func fixture(_ body: (PlistBackupStore, URL) throws -> Void) throws {
        try ScratchDirectory.with { dir in
            let managed = dir.appending(path: "LaunchAgents")
            try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
            let store = PlistBackupStore(
                root: dir.appending(path: "Backups"),
                managedDirectories: [managed.path],
                now: { Date(timeIntervalSince1970: 1_790_000_000) }
            )
            try body(store, managed)
        }
    }

    @Test func backupCopiesIntoTimestampedFolderAndKeepsOriginal() throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            let backup = try store.backupForRemoval(plist.path).backupPath
            #expect(backup.hasSuffix("/LaunchAgents/com.example.agent.plist"))
            #expect(backup.contains("/Backups/20260921-"))
            #expect(FileManager.default.contents(atPath: backup) == (try Data(contentsOf: plist)))
            #expect(FileManager.default.fileExists(atPath: plist.path))
        }
    }

    @Test func restoreCopiesBackToOriginalLocation() throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            let original = try Data(contentsOf: plist)
            let backup = try store.backupForRemoval(plist.path).backupPath
            try FileManager.default.removeItem(at: plist)
            let restored = try store.restore(backup)
            #expect(restored == plist.resolvingSymlinksInPath().path)
            #expect(FileManager.default.contents(atPath: plist.path) == original)
        }
    }

    @Test func refusesUnmanagedSourceOutsideBackupAndExistingDestination() throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "a", in: managed)
            #expect(throws: BackupError.self) { try store.backupForRemoval("/etc/hosts") }
            #expect(throws: BackupError.self) { try store.restore("/etc/hosts") }
            let backup = try store.backupForRemoval(plist.path).backupPath
            #expect(throws: BackupError.destinationExists(plist.resolvingSymlinksInPath().path)) { try store.restore(backup) }
        }
    }

    @Test func backupFolderHasRestrictedPermissions() throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            let backup = try store.backupForRemoval(plist.path).backupPath
            let folder = URL(fileURLWithPath: backup).deletingLastPathComponent()
            let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
            #expect(permissions == 0o700)
        }
    }

    @Test func restoreRejectsPathTraversalOutsideRoot() throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            let backup = try store.backupForRemoval(plist.path).backupPath
            let folder = URL(fileURLWithPath: backup).deletingLastPathComponent()
            let traversal = folder.path + "/../../../../../../../../../../etc/hosts"
            #expect(throws: BackupError.self) { try store.restore(traversal) }
        }
    }

    @Test func restoreRejectsDirectoryAsBackup() throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            let backup = try store.backupForRemoval(plist.path).backupPath
            let folder = URL(fileURLWithPath: backup).deletingLastPathComponent().path
            #expect(throws: BackupError.self) { try store.restore(folder) }
        }
    }

    @Test func restoreRejectsNonPlistFile() throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            let backup = try store.backupForRemoval(plist.path).backupPath
            let notes = URL(fileURLWithPath: backup).deletingLastPathComponent().appending(path: "notes.txt")
            try Data("n".utf8).write(to: notes)
            #expect(throws: BackupError.self) { try store.restore(notes.path) }
        }
    }

    @Test func restoreRejectsMissingTimestampFolder() throws {
        try fixture { store, managed in
            let flatFolder = store.root.appending(path: "LaunchAgents")
            try FileManager.default.createDirectory(at: flatFolder, withIntermediateDirectories: true)
            let flatFile = flatFolder.appending(path: "com.example.agent.plist")
            try Data("x".utf8).write(to: flatFile)
            #expect(throws: BackupError.self) { try store.restore(flatFile.path) }
        }
    }

    @Test func restoreRejectsSymlinkInsideStorePointingOutside() throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            let backup = try store.backupForRemoval(plist.path).backupPath
            let backupFolder = URL(fileURLWithPath: backup).deletingLastPathComponent()
            let outsideTarget = managed.deletingLastPathComponent().appending(path: "outside.plist")
            try Data("evil".utf8).write(to: outsideTarget)
            let link = backupFolder.appending(path: "link.plist")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideTarget)
            #expect(throws: BackupError.self) { try store.restore(link.path) }
        }
    }

    @Test func restoreRejectsAppleFileName() throws {
        try fixture { store, managed in
            let folder = store.root.appending(path: "20260921-000000-000/LaunchAgents")
            let backup = try LaunchdPlistFixture.write(label: "com.apple.x", in: folder)
            #expect(throws: BackupError.outsideStore(backup.path)) { try store.restore(backup.path) }
            #expect(!FileManager.default.fileExists(atPath: managed.appending(path: "com.apple.x.plist").path))
        }
    }

    /// Im Benutzer-Speicher (`allowsAppleLabels`) lassen sich auch Plists mit `com.apple.`-Label sichern und
    /// wiederherstellen – etwa ein als Apple getarnter Adware-Agent.
    @Test func storeAllowingAppleLabelsBacksUpAndRestoresThem() throws {
        try ScratchDirectory.with { dir in
            let managed = dir.appending(path: "LaunchAgents")
            let store = PlistBackupStore(root: dir.appending(path: "Backups"), managedDirectories: [managed.path],
                                         allowsAppleLabels: true)
            let plist = try LaunchdPlistFixture.write(label: "com.apple.update.agent", in: managed)
            let backup = try store.backupForRemoval(plist.path).backupPath
            try FileManager.default.removeItem(at: plist)
            #expect(try store.restore(backup) == plist.resolvingSymlinksInPath().path)
            #expect(FileManager.default.fileExists(atPath: plist.path))
        }
    }

    @Test func onlyTheUserStoreAllowsAppleLabels() {
        #expect(PlistBackupStore.user(home: "/Users/x").allowsAppleLabels)
        #expect(!PlistBackupStore.system.allowsAppleLabels)
    }

    @Test func userStoreUsesTheGivenRootAndManagesTheUserAgents() {
        let root = URL(fileURLWithPath: "/tmp/Debug/Backups")
        let store = PlistBackupStore.user(root: root, home: "/Users/x")
        #expect(store.root == root)
        #expect(store.managedDirectories == ["/Users/x/Library/LaunchAgents"])
        #expect(PlistBackupStore.user(home: "/Users/x").root.path == "/Users/x/Library/Application Support/Grantry/Backups")
    }

    @Test func backupRefusesFileNameThatRestoreWouldReject() throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.vendor.x", named: "com.apple.x.plist", in: managed)
            #expect(throws: BackupError.unrestorableName(plist.path)) { try store.backupForRemoval(plist.path).backupPath }
            #expect(!FileManager.default.fileExists(atPath: store.root.path))
        }
    }

    private func setMode(_ mode: Int, of path: String) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    @Test func restoreRejectsGroupWritableTimestampFolder() throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            let backup = try store.backupForRemoval(plist.path).backupPath
            try FileManager.default.removeItem(at: plist)
            let timestampFolder = URL(fileURLWithPath: backup).deletingLastPathComponent().deletingLastPathComponent()
            try setMode(0o770, of: timestampFolder.path)
            #expect(throws: BackupError.untrustedStore(timestampFolder.resolvingSymlinksInPath().path)) { try store.restore(backup) }
            #expect(!FileManager.default.fileExists(atPath: plist.path))
        }
    }

    @Test func restoreRejectsGroupWritableBackupFile() throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            let backup = try store.backupForRemoval(plist.path).backupPath
            try FileManager.default.removeItem(at: plist)
            try setMode(0o664, of: backup)
            #expect(throws: BackupError.untrustedStore(URL(fileURLWithPath: backup).resolvingSymlinksInPath().path)) { try store.restore(backup) }
            #expect(!FileManager.default.fileExists(atPath: plist.path))
        }
    }

    /// Ein Backup direkt im Speicher-Layout, ohne `backupForRemoval(_:)` – für Fälle, die dieses gar nicht anlegen würde.
    private func plantBackup(in store: PlistBackupStore, payload: [String: Any], named name: String = "com.example.agent.plist") throws -> URL {
        let folder = store.root.appending(path: "20260921-000000-000/LaunchAgents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try LaunchdPlistFixture.write(payload: payload, named: name, in: folder)
    }

    @Test func restoreRejectsAppleLabelInsideInnocentFileName() throws {
        try fixture { store, managed in
            let backup = try plantBackup(in: store, payload: ["Label": "com.apple.x"])
            #expect(throws: BackupError.invalidContent(backup.path)) { try store.restore(backup.path) }
            #expect(!FileManager.default.fileExists(atPath: managed.appending(path: "com.example.agent.plist").path))
        }
    }

    @Test func restoreRejectsBackupWithoutLabel() throws {
        try fixture { store, managed in
            let backup = try plantBackup(in: store, payload: ["Program": "/bin/true"])
            #expect(throws: BackupError.invalidContent(backup.path)) { try store.restore(backup.path) }
            #expect(!FileManager.default.fileExists(atPath: managed.appending(path: "com.example.agent.plist").path))
        }
    }

    // MARK: - Sicherung nur, wenn `restore` sie annähme (#101)

    /// Kein Backup, dessen Inhalt `restore(_:)` ablehnen würde (`invalidContent`) – sonst wäre die Löschung unumkehrbar.
    @Test(arguments: [("Label", "com.apple.x"), ("Program", "/bin/true")])
    func backupRefusesContentThatRestoreWouldReject(key: String, value: String) throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(payload: [key: value], named: "com.example.agent.plist", in: managed)
            let error = #expect(throws: BackupError.self) { try store.backupForRemoval(plist.path) }
            guard case .invalidContent? = error else { Issue.record("unerwarteter Fehler: \(String(describing: error))"); return }
            #expect(FileManager.default.fileExists(atPath: plist.path))
            #expect(try backupFiles(in: store).isEmpty)
        }
    }

    /// Ein für die Gruppe beschreibbarer Backup-Root wird abgelehnt, bevor etwas angelegt wird.
    @Test func backupRefusesGroupWritableRoot() throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o770])
            #expect(throws: BackupError.untrustedStore(store.root.resolvingSymlinksInPath().path)) { try store.backupForRemoval(plist.path) }
            #expect(FileManager.default.fileExists(atPath: plist.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).isEmpty)
        }
    }

    /// Liegt bereits ein jüngeres Backup derselben Datei vor (Uhr zurückgesprungen), bekommt die neue Sicherung einen
    /// Zeitstempel dahinter: Sie ist der aktuelle Zustand und muss das allein wiederherstellbare Backup sein.
    @Test func backupAfterClockWentBackwardsBecomesTheNewestBackup() throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            let existingFolder = store.root.appending(path: "20990101-000000-999/LaunchAgents")
            try FileManager.default.createDirectory(at: existingFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let existing = try LaunchdPlistFixture.write(label: "com.example.agent", in: existingFolder)
            let pending = try store.backupForRemoval(plist.path)
            #expect(pending.backupPath.contains("/Backups/20990101-000001-000/"))
            try pending.remove()
            #expect(throws: BackupError.superseded(existing.path)) { try store.restore(existing.path) }
            #expect(try store.restore(pending.backupPath) == plist.resolvingSymlinksInPath().path)
        }
    }

    /// Scheitert die Nachprüfung, bleibt kein leeres Ordnerpaar zurück.
    @Test func refusedBackupLeavesNoEmptyFolders() throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(payload: ["Program": "/bin/true"], named: "com.example.agent.plist", in: managed)
            #expect(throws: BackupError.self) { try store.backupForRemoval(plist.path) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).isEmpty)
        }
    }

    /// Ein `root`, der kein Verzeichnis ist, gilt nicht als vertrauenswürdig.
    @Test func backupRefusesRootThatIsARegularFile() throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            try Data("x".utf8).write(to: store.root)
            #expect(throws: BackupError.untrustedStore(store.root.resolvingSymlinksInPath().path)) { try store.backupForRemoval(plist.path) }
            #expect(FileManager.default.fileExists(atPath: plist.path))
        }
    }

    /// Ein Symlink als Zwischenstufe der Backup-Kette zählt nicht als Backup – auch wenn er dem Benutzer gehört und
    /// auf ein echtes Backup zeigt: Er überholt das echte Backup nicht und wird nicht durchgelöscht.
    @Test func symlinkedTimestampFolderIsNoBackup() throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            let pending = try store.backupForRemoval(plist.path)
            try pending.remove()
            let timestampFolder = URL(fileURLWithPath: pending.backupPath).deletingLastPathComponent().deletingLastPathComponent()
            let newerLookingLink = store.root.appending(path: "20990101-000000-000")
            try FileManager.default.createSymbolicLink(at: newerLookingLink, withDestinationURL: timestampFolder)
            #expect(try store.restore(pending.backupPath) == plist.resolvingSymlinksInPath().path)
        }
    }

    /// Das verwaltete Verzeichnis darf bei der Erzeugung des Speichers noch fehlen (erster Agent kommt später).
    @Test func managedDirectoryMayBeCreatedAfterTheStore() throws {
        try ScratchDirectory.with { dir in
            let managed = dir.appending(path: "LaunchAgents")
            let store = PlistBackupStore(root: dir.appending(path: "Backups"), managedDirectories: [managed.path])
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            let pending = try store.backupForRemoval(plist.path)
            try pending.remove()
            #expect(!FileManager.default.fileExists(atPath: plist.path))
            #expect(try store.restore(pending.backupPath) == plist.resolvingSymlinksInPath().path)
        }
    }

    /// Wird das bei der Erzeugung noch fehlende verwaltete Verzeichnis später als Symlink angelegt, wird nicht gesichert.
    @Test func managedDirectoryCreatedLaterAsSymlinkIsRefused() throws {
        try ScratchDirectory.with { dir in
            let managed = dir.appending(path: "LaunchAgents")
            let store = PlistBackupStore(root: dir.appending(path: "Backups"), managedDirectories: [managed.path])
            let elsewhere = try LaunchdPlistFixture.write(label: "com.example.agent", in: dir.appending(path: "elsewhere"))
            try FileManager.default.createSymbolicLink(at: managed, withDestinationURL: elsewhere.deletingLastPathComponent())
            #expect(throws: BackupError.self) { try store.backupForRemoval(managed.appending(path: "com.example.agent.plist").path) }
            #expect(FileManager.default.fileExists(atPath: elsewhere.path))
        }
    }

    /// Alle regulären Dateien unterhalb von `store.root`.
    private func backupFiles(in store: PlistBackupStore) throws -> [String] {
        guard FileManager.default.fileExists(atPath: store.root.path) else { return [] }
        return try FileManager.default.subpathsOfDirectory(atPath: store.root.path)
            .map { store.root.appending(path: $0).path }
            .filter { (try? FileManager.default.attributesOfItem(atPath: $0)[.type] as? FileAttributeType) == .typeRegular }
    }

    // MARK: - Gebundenes Löschen (#98)

    @Test func removeDeletesTheBackedUpFileAndRestoreBringsItBack() throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            let original = try Data(contentsOf: plist)
            let pending = try store.backupForRemoval(plist.path)
            try pending.remove()
            #expect(!FileManager.default.fileExists(atPath: plist.path))
            #expect(try store.restore(pending.backupPath) == plist.resolvingSymlinksInPath().path)
            #expect(FileManager.default.contents(atPath: plist.path) == original)
        }
    }

    /// Wird das verwaltete Verzeichnis nach der Sicherung gegen einen Symlink getauscht, bleibt die Löschung an das
    /// ursprüngliche Verzeichnis gebunden: Die gleichnamige Fremddatei hinter dem Symlink bleibt unangetastet.
    @Test func removeIgnoresDirectorySwappedForSymlinkAfterBackup() throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            let pending = try store.backupForRemoval(plist.path)

            let movedAside = managed.deletingLastPathComponent().appending(path: "moved")
            try FileManager.default.moveItem(at: managed, to: movedAside)
            let foreign = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed.deletingLastPathComponent().appending(path: "victim"))
            try FileManager.default.createSymbolicLink(at: managed, withDestinationURL: foreign.deletingLastPathComponent())

            try pending.remove()
            #expect(FileManager.default.fileExists(atPath: foreign.path))
            #expect(!FileManager.default.fileExists(atPath: movedAside.appending(path: "com.example.agent.plist").path))
        }
    }

    /// Wurde die Datei nach der Sicherung ersetzt (andere Inode), wird nichts gelöscht.
    @Test func removeRefusesWhenFileWasReplaced() throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            let pending = try store.backupForRemoval(plist.path)
            try FileManager.default.removeItem(at: plist)
            try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            #expect(throws: BackupError.sourceChanged(plist.resolvingSymlinksInPath().path)) { try pending.remove() }
            #expect(FileManager.default.fileExists(atPath: plist.path))
        }
    }

    /// Wurde die Datei nach der Sicherung durch einen Symlink ersetzt, bleiben Symlink und Ziel erhalten.
    @Test func removeRefusesWhenFileBecameSymlink() throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            let canonical = plist.resolvingSymlinksInPath().path
            let pending = try store.backupForRemoval(plist.path)
            let target = try LaunchdPlistFixture.write(label: "com.example.target", in: managed.deletingLastPathComponent())
            try FileManager.default.removeItem(at: plist)
            try FileManager.default.createSymbolicLink(at: plist, withDestinationURL: target)
            #expect(throws: BackupError.sourceChanged(canonical)) { try pending.remove() }
            #expect(FileManager.default.fileExists(atPath: target.path))
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: plist.path)) == target.path)
        }
    }

    /// #156, Codex-Runde 3: Wird dieselbe Datei (gleiche Inode) nach der Sicherung in-place umgeschrieben, enthält die
    /// Sicherung nur die alte Fassung – die neuen Bytes werden nicht gelöscht, die Sicherung bleibt. Auch mit
    /// zurückgesetztem Änderungsdatum (ctime und Inhalt verraten die Änderung).
    @Test(arguments: [false, true])
    func removeRefusesWhenFileWasRewrittenInPlace(keepingModificationDate: Bool) throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", payload: ["Label": "com.example.agent", "Marker": 1], in: managed)
            let inode = try #require(FileManager.default.attributesOfItem(atPath: plist.path)[.systemFileNumber] as? Int)
            let pending = try store.backupForRemoval(plist.path)
            try LaunchdPlistFixture.overwriteInPlace(plist, payload: ["Label": "com.example.agent", "Marker": 2],
                                                     keepingModificationDate: keepingModificationDate)
            #expect(try FileManager.default.attributesOfItem(atPath: plist.path)[.systemFileNumber] as? Int == inode)
            let rewritten = try Data(contentsOf: plist)

            #expect(throws: BackupError.sourceChanged(plist.resolvingSymlinksInPath().path)) { try pending.remove() }
            #expect(FileManager.default.contents(atPath: plist.path) == rewritten)
            #expect(FileManager.default.fileExists(atPath: pending.backupPath))
        }
    }

    /// Ist die Datei nach der Sicherung verschwunden, meldet `remove()` das als Änderung statt still zu gelingen.
    @Test func removeRefusesWhenFileDisappeared() throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            let pending = try store.backupForRemoval(plist.path)
            try FileManager.default.removeItem(at: plist)
            #expect(throws: BackupError.sourceChanged(plist.resolvingSymlinksInPath().path)) { try pending.remove() }
        }
    }

    /// Ein zweites `remove()` löscht nichts mehr – auch nicht eine inzwischen gleichnamig angelegte Datei.
    @Test func secondRemoveDoesNotDeleteANewFileOfTheSameName() throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            let pending = try store.backupForRemoval(plist.path)
            try pending.remove()
            try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            #expect(throws: BackupError.sourceChanged(plist.resolvingSymlinksInPath().path)) { try pending.remove() }
            #expect(FileManager.default.fileExists(atPath: plist.path))
        }
    }

    /// Fehlerpfad beim Öffnen (FIFO statt Datei): kein Backup, kein offener Deskriptor auf das Scratch-Verzeichnis
    /// bleibt zurück (andere Tests laufen parallel, daher wird nach Pfad statt nach Deskriptornummer geprüft).
    @Test func fifoInPlaceOfPlistIsRefusedWithoutLeakingADescriptor() throws {
        try fixture { store, managed in
            let fifo = managed.appending(path: "com.example.agent.plist")
            #expect(mkfifo(fifo.path, 0o600) == 0)
            #expect(throws: BackupError.sourceChanged(fifo.resolvingSymlinksInPath().path)) { try store.backupForRemoval(fifo.path) }
            let scratchName = managed.deletingLastPathComponent().lastPathComponent
            #expect(!openDescriptorPaths().contains { $0.contains(scratchName) })
            let remaining = try backupFiles(in: store)
            #expect(remaining.isEmpty)
        }
    }

    /// Pfade aller offenen Dateideskriptoren dieses Prozesses (`F_GETPATH`).
    private func openDescriptorPaths() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []).compactMap { name in
            guard let descriptor = Int32(name) else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
            return String(cString: buffer)
        }
    }

    /// Gesichert werden die Bytes des geöffneten Dateiobjekts – auch wenn der Pfad inzwischen woanders hinzeigt.
    @Test func backupHoldsTheBytesOfTheOpenedFileObject() throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", payload: ["Label": "com.example.agent", "Marker": 1], in: managed)
            let original = try Data(contentsOf: plist)
            let pending = try store.backupForRemoval(plist.path)
            #expect(FileManager.default.contents(atPath: pending.backupPath) == original)
            #expect(pending.backupPath.hasPrefix(store.root.path))
        }
    }

    /// Ein verwaltetes Verzeichnis, das zur Sicherung bereits ein Symlink ist, wird nicht gesichert.
    @Test func backupRefusesManagedDirectoryThatBecameASymlink() throws {
        try fixture { store, managed in
            let elsewhere = managed.deletingLastPathComponent().appending(path: "elsewhere")
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: elsewhere)
            try FileManager.default.removeItem(at: managed)
            try FileManager.default.createSymbolicLink(at: managed, withDestinationURL: elsewhere)
            #expect(throws: BackupError.self) { try store.backupForRemoval(managed.appending(path: "com.example.agent.plist").path) }
            #expect(FileManager.default.fileExists(atPath: plist.path))
            #expect(try backupFiles(in: store).isEmpty)
        }
    }

    @Test func changeMessagesAreGermanAndAskForARescan() {
        #expect(BackupError.sourceChanged("/x").errorDescription
            == "Datei seit der Sicherung ersetzt, verändert oder entfernt, nichts gelöscht (die Sicherung bleibt) – bitte neu scannen: /x")
        #expect(BackupError.changedSinceScan("/x").errorDescription
            == "Datei hat sich seit dem letzten Scan geändert, nichts gesichert oder gelöscht – bitte neu scannen: /x")
    }

    // MARK: Bindung an den Fingerabdruck aus dem Scan (#156, Codex-Runde 3)

    /// Gesichert wird nur eine Datei mit genau dem Fingerabdruck aus dem Scan; die Prüfung gilt dem geöffneten
    /// Dateiobjekt. Ersetzt (andere Inode) oder umgeschrieben: keine Sicherung, nichts gelöscht.
    @Test(arguments: [false, true])
    func backupRefusesAFileThatNoLongerCarriesTheScanFingerprint(replaced: Bool) throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            let scanned = FileFingerprint(status: try Self.linkStatus(plist))
            if replaced {
                let replacement = try LaunchdPlistFixture.write(payload: ["Label": "com.example.agent", "New": true], named: "new", in: managed)
                _ = try FileManager.default.replaceItemAt(plist, withItemAt: replacement)
            } else {
                try LaunchdPlistFixture.overwriteInPlace(plist, payload: ["Label": "com.example.agent", "New": true])
            }
            #expect(throws: BackupError.changedSinceScan(plist.resolvingSymlinksInPath().path)) {
                try store.backupForRemoval(plist.path, expecting: scanned)
            }
            #expect(FileManager.default.fileExists(atPath: plist.path))
            #expect(try backupFiles(in: store).isEmpty)
        }
    }

    /// Mit passendem Fingerabdruck wird gesichert und gelöscht; die Sicherung enthält genau die Bytes aus dem Scan.
    @Test func backupWithTheScanFingerprintSucceeds() throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            let original = try Data(contentsOf: plist)
            let pending = try store.backupForRemoval(plist.path, expecting: FileFingerprint(status: try Self.linkStatus(plist)))
            try pending.remove()
            #expect(!FileManager.default.fileExists(atPath: plist.path))
            #expect(FileManager.default.contents(atPath: pending.backupPath) == original)
        }
    }

    /// `lstat` von `url`.
    private static func linkStatus(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
        return info
    }

    @Test func restoredPlistHasMode0644() throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            try setMode(0o600, of: plist.path)
            let backup = try store.backupForRemoval(plist.path).backupPath
            try FileManager.default.removeItem(at: plist)
            let restored = try store.restore(backup)
            let attributes = try FileManager.default.attributesOfItem(atPath: restored)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o644)
        }
    }

    @Test func backupNormalisesGroupWritableSourceToRestorable0644() throws {
        try fixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            try setMode(0o664, of: plist.path)
            let backup = try store.backupForRemoval(plist.path).backupPath
            let attributes = try FileManager.default.attributesOfItem(atPath: backup)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o644)
            try FileManager.default.removeItem(at: plist)
            #expect(try store.restore(backup) == plist.resolvingSymlinksInPath().path)
        }
    }

    // MARK: - Aufbewahrung und neuestes Backup

    /// Store, dessen Uhr bei jedem Backup eine Sekunde weiterläuft.
    private func steppingFixture(_ body: (PlistBackupStore, URL) throws -> Void) throws {
        try ScratchDirectory.with { dir in
            let managed = dir.appending(path: "LaunchAgents")
            try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
            let tick = Mutex(0)
            let store = PlistBackupStore(
                root: dir.appending(path: "Backups"),
                managedDirectories: [managed.path],
                now: {
                    let step = tick.withLock { tick in
                        defer { tick += 1 }
                        return tick
                    }
                    return Date(timeIntervalSince1970: 1_790_000_000 + TimeInterval(step))
                }
            )
            try body(store, managed)
        }
    }

    private func timestampFolders(_ store: PlistBackupStore) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: store.root.path).sorted()
    }

    @Test func keepsOnlyTheNewestFiveBackupsPerFileName() throws {
        try steppingFixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            let backups = try (0..<7).map { _ in try store.backupForRemoval(plist.path).backupPath }
            #expect(backups.prefix(2).allSatisfy { !FileManager.default.fileExists(atPath: $0) })
            #expect(backups.suffix(5).allSatisfy { FileManager.default.fileExists(atPath: $0) })
            // Leere Zeitstempel-Ordner der gelöschten Backups verschwinden mit.
            #expect(try timestampFolders(store).count == 5)
        }
    }

    @Test func retentionCountsEachFileNameSeparately() throws {
        try steppingFixture { store, managed in
            let first = try LaunchdPlistFixture.write(label: "com.example.first", in: managed)
            let second = try LaunchdPlistFixture.write(label: "com.example.second", in: managed)
            let secondBackup = try store.backupForRemoval(second.path).backupPath
            let firstBackups = try (0..<6).map { _ in try store.backupForRemoval(first.path).backupPath }
            #expect(FileManager.default.fileExists(atPath: secondBackup))
            #expect(!FileManager.default.fileExists(atPath: firstBackups[0]))
            #expect(firstBackups.dropFirst().allSatisfy { FileManager.default.fileExists(atPath: $0) })
        }
    }

    @Test func retentionKeepsFoldersThatStillHoldOtherBackups() throws {
        try steppingFixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            let oldest = try store.backupForRemoval(plist.path).backupPath
            let neighbour = URL(fileURLWithPath: oldest).deletingLastPathComponent().appending(path: "com.example.other.plist")
            try FileManager.default.copyItem(atPath: oldest, toPath: neighbour.path)
            for _ in 0..<5 { _ = try store.backupForRemoval(plist.path).backupPath }
            #expect(!FileManager.default.fileExists(atPath: oldest))
            #expect(FileManager.default.fileExists(atPath: neighbour.path))
        }
    }

    @Test func retentionLeavesUntrustedBackupsAlone() throws {
        try steppingFixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            let oldest = try store.backupForRemoval(plist.path).backupPath
            try setMode(0o664, of: oldest)
            for _ in 0..<5 { _ = try store.backupForRemoval(plist.path).backupPath }
            #expect(FileManager.default.fileExists(atPath: oldest))
        }
    }

    @Test func restoreRefusesSupersededBackup() throws {
        try steppingFixture { store, managed in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: managed)
            let older = try store.backupForRemoval(plist.path).backupPath
            let newer = try store.backupForRemoval(plist.path).backupPath
            try FileManager.default.removeItem(at: plist)
            #expect(throws: BackupError.superseded(older)) { try store.restore(older) }
            #expect(!FileManager.default.fileExists(atPath: plist.path))
            #expect(try store.restore(newer) == plist.resolvingSymlinksInPath().path)
        }
    }

    @Test func supersededMessageIsGerman() {
        #expect(BackupError.superseded("/x").errorDescription == "Nicht das neueste Backup dieser Datei; wiederherstellbar ist nur das neueste: /x")
    }
}
