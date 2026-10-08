import Testing
import Foundation
import Synchronization
import TestSupport
@testable import ManagerKit

@Suite struct WatchScopeTests {
    @Test func existingPathIsWatchedDirectly() throws {
        try ScratchDirectory.with(prefix: "scope") { directory in
            let root = try #require(WatchScope.canonicalPath(of: directory.path))
            let scope = WatchScope(paths: [directory.path])
            #expect(scope.roots == [root])
            #expect(scope.contains(root))
            #expect(scope.contains("\(root)/a/b.plist"))
            #expect(!scope.contains("\(root)-other/file"))
            // Änderungen im Elternordner (etwa das Anlegen von Geschwistern) zählen nicht.
            #expect(!scope.contains(directory.deletingLastPathComponent().path))
        }
    }

    /// FSEvents meldet ohne Datei-Ereignisse das Verzeichnis, in dem sich etwas geändert hat: Solange der Pfad fehlt,
    /// zählen Vorfahren innerhalb des Wurzelverzeichnisses – dort könnte er gerade angelegt worden sein.
    @Test func missingPathIsWatchedThroughNearestExistingParent() throws {
        try ScratchDirectory.with(prefix: "scope") { directory in
            let root = try #require(WatchScope.canonicalPath(of: directory.path))
            let missing = directory.appending(path: "Library/LaunchAgents").path
            let scope = WatchScope(paths: [missing])
            #expect(scope.roots == [root])
            #expect(scope.entries == [WatchScope.Entry(source: missing, root: root, target: "\(root)/Library/LaunchAgents")])
            #expect(scope.contains(root))
            #expect(scope.contains("\(root)/Library"))
            #expect(scope.contains("\(root)/Library/LaunchAgents"))
            #expect(scope.contains("\(root)/Library/LaunchAgents/x.plist"))
            #expect(!scope.contains("\(root)/unrelated"))
            #expect(!scope.contains("\(root)/Library/LaunchAgentsX"))
            #expect(!scope.contains("\(root)/Library/Preferences"))
            #expect(!scope.contains(directory.deletingLastPathComponent().path))
        }
    }

    /// `/Applications` flach: neue Bundles und In-Place-Updates (`X.app/Contents`, `Ordner/X.app/Contents`) zählen,
    /// Schreibzugriffe tief im Bundle nicht.
    @Test func shallowPathCountsOnlyEventsNearTheTop() throws {
        try ScratchDirectory.with(prefix: "scope") { directory in
            let root = try #require(WatchScope.canonicalPath(of: directory.path))
            let scope = WatchScope(paths: [], shallowPaths: [directory.path])
            #expect(scope.roots == [root])
            #expect(scope.appFolderTargets == [root])
            #expect(scope.appFolders(reportedIn: root) == [root])
            #expect(scope.appFolders(reportedIn: "\(root)/New.app/Contents") == [root])
            #expect(scope.appFolders(reportedIn: "\(root)/Vendor/Tool.app/Contents/") == [root])
            #expect(scope.appFolders(reportedIn: "\(root)/New.app/Contents/Resources/de.lproj").isEmpty)
            #expect(scope.appFolders(reportedIn: "\(root)-other/X.app").isEmpty)
            // Ob sich etwas an den Bundles geändert hat, entscheidet der Fingerabdruck, nicht `contains`.
            #expect(!scope.contains(root))
            #expect(!scope.contains("\(root)/New.app/Contents"))
        }
    }

    /// Ein fehlender flacher Ordner (`~/Applications` gibt es nicht überall) wird nicht über seinen Elternordner
    /// beobachtet – sonst löste jede Änderung direkt im Benutzerordner (`.zsh_history`) einen Scan aus. Neue Apps dort
    /// erfasst das Intervall.
    @Test func missingShallowPathIsNotWatched() throws {
        try ScratchDirectory.with(prefix: "scope") { directory in
            let root = try #require(WatchScope.canonicalPath(of: directory.path))
            let scope = WatchScope(paths: [], shallowPaths: [directory.appending(path: "Applications").path])
            #expect(scope.roots.isEmpty)
            #expect(!scope.contains(root))
        }
    }

    @Test func ancestorsStopCountingOnceThePathExists() throws {
        try ScratchDirectory.with(prefix: "scope") { directory in
            let root = try #require(WatchScope.canonicalPath(of: directory.path))
            let agents = directory.appending(path: "Library/LaunchAgents")
            let scope = WatchScope(paths: [agents.path])
            #expect(scope.contains("\(root)/Library"))

            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            #expect(!scope.contains(root))
            #expect(!scope.contains("\(root)/Library"))
            #expect(scope.contains("\(root)/Library/LaunchAgents"))
            #expect(scope.contains("\(root)/Library/LaunchAgents/"))
        }
    }

    @Test func existenceCheckIsInjectable() throws {
        try ScratchDirectory.with(prefix: "scope") { directory in
            let root = try #require(WatchScope.canonicalPath(of: directory.path))
            let scope = WatchScope(paths: [directory.appending(path: "missing").path])
            #expect(scope.contains(root, fileExists: { _ in false }))
            #expect(!scope.contains(root, fileExists: { _ in true }))
        }
    }

    @Test func rootsAreDeduplicated() throws {
        try ScratchDirectory.with(prefix: "scope") { directory in
            let scope = WatchScope(paths: [
                directory.appending(path: "a").path, directory.appending(path: "b").path, directory.path,
            ])
            #expect(scope.roots.count == 1)
            #expect(scope.entries.count == 3)
        }
    }

    @Test func trailingSlashInEventPathIsIgnored() throws {
        try ScratchDirectory.with(prefix: "scope") { directory in
            let root = try #require(WatchScope.canonicalPath(of: directory.path))
            let scope = WatchScope(paths: [directory.appending(path: "missing").path])
            #expect(scope.contains("\(root)/missing/"))
        }
    }

    /// Die Wurzel würde die ganze Platte beobachten – auch wenn sie nur der nächste existierende Vorfahre ist.
    @Test func rootDirectoryIsNeverWatched() {
        #expect(WatchScope(paths: ["/"]).entries.isEmpty)
        #expect(WatchScope(paths: ["/gibt-es-nicht-\(UUID().uuidString)/LaunchAgents"]).entries.isEmpty)
        #expect(WatchScope(paths: ["/", "/Library"]).roots == ["/Library"])
    }

    /// Dateien beobachtet FSEvents über ihren Ordner; gemeldet wird der Ordner, nicht die Datei.
    @Test func existingFileIsWatchedThroughItsDirectory() throws {
        try ScratchDirectory.with(prefix: "scope") { directory in
            let root = try #require(WatchScope.canonicalPath(of: directory.path))
            let file = directory.appending(path: "com.apple.SoftwareUpdate.plist")
            try Data("x".utf8).write(to: file)
            let scope = WatchScope(paths: [], files: [file.path])
            #expect(scope.roots == [root])
            #expect(scope.entries == [
                WatchScope.Entry(
                    source: file.path, root: root, target: "\(root)/com.apple.SoftwareUpdate.plist", isFile: true
                ),
            ])
            #expect(!scope.contains(root))  // Ordner allein genügt nicht – erst der Fingerabdruck entscheidet
            #expect(scope.files(reportedIn: root) == ["\(root)/com.apple.SoftwareUpdate.plist"])
            #expect(scope.files(reportedIn: "\(root)/") == ["\(root)/com.apple.SoftwareUpdate.plist"])
            #expect(scope.files(reportedIn: "\(root)/other").isEmpty)
            #expect(scope.fileTargets == ["\(root)/com.apple.SoftwareUpdate.plist"])
        }
    }

    /// Eine beim Start fehlende Datei bleibt eine Datei: beobachtet über ihren Ordner, gefiltert per Fingerabdruck –
    /// sonst zählte jede Änderung im Ordner, und nach ihrem Erscheinen würde sie nie mehr erkannt.
    @Test func missingFileIsWatchedThroughItsDirectory() throws {
        try ScratchDirectory.with(prefix: "scope") { directory in
            let root = try #require(WatchScope.canonicalPath(of: directory.path))
            let file = directory.appending(path: "com.apple.networkextension.plist").path
            let scope = WatchScope(paths: [], files: [file])
            #expect(scope.entries == [
                WatchScope.Entry(source: file, root: root, target: "\(root)/com.apple.networkextension.plist", isFile: true),
            ])
            #expect(!scope.contains(root))
            #expect(scope.files(reportedIn: root) == ["\(root)/com.apple.networkextension.plist"])
        }
    }

    /// Fehlt auch der Ordner der Datei, wird sie über den nächsten existierenden Vorfahren beobachtet; Ereignisse im
    /// Ordner und auf dem Weg dorthin liefern sie.
    @Test func fileInMissingDirectoryIsWatchedThroughNearestExistingAncestor() throws {
        try ScratchDirectory.with(prefix: "scope") { directory in
            let root = try #require(WatchScope.canonicalPath(of: directory.path))
            let target = "\(root)/Library/Preferences/a.plist"
            let file = directory.appending(path: "Library/Preferences/a.plist").path
            let scope = WatchScope(paths: [], files: [file])
            #expect(scope.entries == [WatchScope.Entry(source: file, root: root, target: target, isFile: true)])
            #expect(scope.files(reportedIn: root) == [target])
            #expect(scope.files(reportedIn: "\(root)/Library") == [target])
            #expect(scope.files(reportedIn: "\(root)/Library/Preferences") == [target])
            #expect(scope.files(reportedIn: "\(root)/Library/Other").isEmpty)
        }
    }

    /// Meldet FSEvents einen Vorfahren des Ordners (etwa bei `MustScanSubDirs` oder verworfenen Ereignissen), muss der
    /// Fingerabdruck trotzdem geprüft werden.
    @Test func ancestorEventsReportFilesBelowThem() throws {
        try ScratchDirectory.with(prefix: "scope") { directory in
            let root = try #require(WatchScope.canonicalPath(of: directory.path))
            let preferences = directory.appending(path: "Preferences")
            try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
            let target = "\(root)/Preferences/a.plist"
            let scope = WatchScope(paths: [], files: [preferences.appending(path: "a.plist").path])
            #expect(scope.roots == ["\(root)/Preferences"])
            #expect(scope.files(reportedIn: root) == [target])
            #expect(scope.files(reportedIn: "\(root)/Preferences") == [target])
            #expect(scope.files(reportedIn: "\(root)/Preferences/Sub").isEmpty)
        }
    }

    /// Verzeichnisse und Dateien teilen sich ein Wurzelverzeichnis.
    @Test func directoriesAndFilesShareRoots() throws {
        try ScratchDirectory.with(prefix: "scope") { directory in
            let scope = WatchScope(paths: [directory.path], files: [directory.appending(path: "a.plist").path])
            #expect(scope.roots.count == 1)
            #expect(scope.entries.count == 2)
        }
    }

    /// Eine anfangs fehlende Datei: Änderungen an Nachbardateien lösen nichts aus, ihr Erscheinen und spätere
    /// Änderungen schon.
    @Test func boxSignalsAppearanceAndLaterChangesOfInitiallyMissingFile() throws {
        try ScratchDirectory.with(prefix: "box") { directory in
            let root = try #require(WatchScope.canonicalPath(of: directory.path))
            let file = directory.appending(path: "com.apple.networkextension.plist")
            let neighbor = directory.appending(path: "com.apple.other.plist")
            let target = root + "/" + file.lastPathComponent
            let (_, continuation) = AsyncStream<String>.makeStream()
            defer { continuation.finish() }
            let box = ContinuationBox(continuation, scope: WatchScope(paths: [], files: [file.path]))

            try Data("n".utf8).write(to: neighbor)
            #expect(box.receive([root]) == nil)  // Nachbardatei erscheint
            try Data("1".utf8).write(to: file)
            #expect(box.receive([root]) == target)  // Zieldatei erscheint
            #expect(box.receive([root]) == nil)  // dieselbe Meldung noch einmal
            try FileManager.default.setAttributes(
                [.modificationDate: Date.now.addingTimeInterval(60)], ofItemAtPath: neighbor.path
            )
            #expect(box.receive([root]) == nil)  // Nachbardatei geändert
            try FileManager.default.setAttributes(
                [.modificationDate: Date.now.addingTimeInterval(120)], ofItemAtPath: file.path
            )
            #expect(box.receive([root]) == target)  // Zieldatei geändert
        }
    }

    /// Ein Signal nennt den auslösenden Pfad: das gemeldete Verzeichnis im beobachteten Bereich.
    @Test func boxReportsTheTriggeringDirectory() throws {
        try ScratchDirectory.with(prefix: "box") { directory in
            let root = try #require(WatchScope.canonicalPath(of: directory.path))
            let (_, continuation) = AsyncStream<String>.makeStream()
            defer { continuation.finish() }
            let box = ContinuationBox(continuation, scope: WatchScope(paths: [directory.path]))
            #expect(box.receive(["/elsewhere", root + "/sub/"]) == root + "/sub/")
            #expect(box.receive(["/elsewhere"]) == nil)
        }
    }

    /// App-Ordner (`/Applications`): Nur Änderungen an `.app`-Bundles lösen aus – Hinzufügen, Entfernen, Umbenennen,
    /// In-Place-Update (Siegel bzw. `Info.plist`) –, nicht Dateien, die ein Hersteller in seinen Unterordner schreibt.
    @Test func boxSignalsOnlyAppBundleChangesInAppFolders() throws {
        try ScratchDirectory.with(prefix: "box") { directory in
            let root = try #require(WatchScope.canonicalPath(of: directory.path))
            let vendor = directory.appending(path: "Corsair iCUE5 Software")
            let tool = vendor.appending(path: "iCUE.app")
            try Self.makeBundle(at: tool)
            let (_, continuation) = AsyncStream<String>.makeStream()
            defer { continuation.finish() }
            let box = ContinuationBox(continuation, scope: WatchScope(paths: [], shallowPaths: [directory.path]))
            let vendorPath = root + "/" + vendor.lastPathComponent

            try Data("log".utf8).write(to: vendor.appending(path: "iCUE.log"))
            #expect(box.receive([vendorPath + "/"]) == nil)  // Herstellerdatei
            try Data("x".utf8).write(to: directory.appending(path: ".DS_Store"))
            #expect(box.receive([root]) == nil)  // Datei direkt im App-Ordner

            try Self.makeBundle(at: directory.appending(path: "New.app"))
            #expect(box.receive([root]) == root)  // neue App
            #expect(box.receive([root]) == nil)  // dieselbe Meldung noch einmal

            try FileManager.default.setAttributes(
                [.modificationDate: Date.now.addingTimeInterval(60)],
                ofItemAtPath: tool.appending(path: "Contents/Info.plist").path
            )
            let contents = vendorPath + "/iCUE.app/Contents"
            #expect(box.receive(["/elsewhere", contents]) == contents)  // In-Place-Update

            try FileManager.default.moveItem(at: tool, to: vendor.appending(path: "iCUE 5.app"))
            #expect(box.receive([vendorPath]) == vendorPath)  // umbenannt
            try FileManager.default.removeItem(at: directory.appending(path: "New.app"))
            #expect(box.receive([root]) == root)  // entfernt
        }
    }

    /// Minimales Bundle mit `Contents/Info.plist`.
    private static func makeBundle(at url: URL) throws {
        let contents = url.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: contents.appending(path: "Info.plist"))
    }

    @Test func fileStampsReportOnlyRealChanges() throws {
        try ScratchDirectory.with(prefix: "stamps") { directory in
            let file = directory.appending(path: "a.plist")
            try Data("1".utf8).write(to: file)
            let stamps = FileStamps(paths: [file.path])
            #expect(stamps.update([file.path]).isEmpty)
            try FileManager.default.setAttributes(
                [.modificationDate: Date.now.addingTimeInterval(60)], ofItemAtPath: file.path
            )
            #expect(stamps.update([file.path]) == [file.path])
            #expect(stamps.update([file.path]).isEmpty)
            try FileManager.default.removeItem(at: file)
            #expect(stamps.update([file.path]) == [file.path])  // Verschwinden zählt
            #expect(stamps.update([file.path]).isEmpty)
            try Data("2".utf8).write(to: file)
            #expect(stamps.update([file.path]) == [file.path])  // Erscheinen ebenso
        }
    }

    /// Inhalts-gestempelte Datei (Agenten-Konfiguration): Nur ein geänderter Stempel löst aus, nicht der Fingerabdruck.
    @Test func contentStampedFileReportsOnlyStampChanges() throws {
        try ScratchDirectory.with(prefix: "box") { directory in
            let root = try #require(WatchScope.canonicalPath(of: directory.path))
            let file = directory.appending(path: "a.json")
            try Data("1".utf8).write(to: file)
            let value = Mutex(1)
            let (_, continuation) = AsyncStream<String>.makeStream()
            defer { continuation.finish() }
            let box = ContinuationBox(
                continuation, scope: WatchScope(paths: [], files: [file.path]),
                contentStamps: [file.path: { value.withLock { $0 } }]
            )
            try FileManager.default.setAttributes(
                [.modificationDate: Date.now.addingTimeInterval(60)], ofItemAtPath: file.path
            )
            #expect(box.receive([root]) == nil)  // Datei geändert, Stempel gleich
            value.withLock { $0 = 2 }
            #expect(box.receive([root]) == root + "/a.json")
            #expect(box.receive([root]) == nil)
        }
    }

    /// Liegt eine Wurzel unter einer anderen (Datei direkt im Home neben einer Datei in `~/.cursor`), beobachtet
    /// FSEvents nur die äußere – sie meldet die Ereignisse darunter ohnehin.
    @Test func nestedRootsAreDropped() throws {
        try ScratchDirectory.with(prefix: "scope") { directory in
            let root = try #require(WatchScope.canonicalPath(of: directory.path))
            let nested = directory.appending(path: "nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let sibling = directory.appending(path: "nested-sibling")
            try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
            let scope = WatchScope(
                paths: [sibling.path],
                files: [nested.appending(path: "a.json").path, directory.appending(path: "b.json").path]
            )
            #expect(scope.roots == [root])
            #expect(scope.entries.count == 3)
            #expect(WatchScope(paths: [sibling.path, nested.path]).roots == [root + "/nested-sibling", root + "/nested"])
        }
    }

    /// Ein Eintrag kennt den angegebenen Pfad, auch wenn sein Ziel kanonisch ist.
    @Test func entriesKeepTheGivenPath() throws {
        try ScratchDirectory.with(prefix: "scope") { directory in
            let file = directory.appending(path: "a.json").path
            #expect(WatchScope(paths: [], files: [file]).entries.map(\.source) == [file])
        }
    }
}
