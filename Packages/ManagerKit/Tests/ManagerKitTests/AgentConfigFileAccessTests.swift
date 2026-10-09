import Darwin
import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct AgentConfigFileAccessTests {
    /// Fixture-Home ohne Symlink im Pfad (`/var` → `/private/var`).
    private func withHome(_ body: (String) throws -> Void) throws {
        try ScratchDirectory.with(prefix: "agent-edit") { directory in
            try body(try #require(AgentConfigReader.canonicalPath(directory.path)))
        }
    }

    private func write(_ text: String, to path: String, mode: Int = 0o600) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(filePath: path))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    private func text(at path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    private func entries(of directory: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
    }

    private func linkStatus(of path: String) throws -> stat {
        var info = stat()
        try #require(lstat(path, &info) == 0)
        return info
    }

    private let swap = UInt32(RENAME_SWAP)

    /// Die Gruppen des Benutzers (`getgroups`), ohne Doppelte.
    private static func userGroups() -> Set<gid_t> {
        var groups = [gid_t](repeating: 0, count: Int(NGROUPS_MAX))
        let count = getgroups(Int32(groups.count), &groups)
        return Set(groups.prefix(Int(max(0, count))))
    }

    /// Mit mindestens zwei Gruppen gibt es zu jeder geerbten eine andere.
    private static func userBelongsToSeveralGroups() -> Bool {
        userGroups().count >= 2
    }

    /// Zustand des Nebenläufers im Ordnertausch-Test.
    private final class SwapProbe: Sendable {
        let running = Atomic(true)
        let swaps = Atomic(0)
    }

    @Test func readsAndReplacesKeepingPermissions() throws {
        try withHome { home in
            let path = home + "/.cursor/mcp.json"
            try write("{}", to: path, mode: 0o640)
            let snapshot = try AgentConfigFileAccess.read(path, home: home)
            #expect(snapshot.contents == Data("{}".utf8))
            #expect(snapshot.digest == AgentConfigFileAccess.digest(of: Data("{}".utf8)))
            try AgentConfigFileAccess.replace(snapshot, with: Data("{\"a\": 1}".utf8))
            #expect(try text(at: path) == "{\"a\": 1}")
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            #expect((attributes[.posixPermissions] as? Int) == 0o640)
            #expect(try entries(of: home + "/.cursor") == ["mcp.json"])
        }
    }

    @Test func snapshotBindsDirectoryAndFileObject() throws {
        try withHome { home in
            let path = home + "/.cursor/mcp.json"
            try write("{}", to: path)
            let snapshot = try AgentConfigFileAccess.read(path, home: home)
            #expect(snapshot.identity == FileIdentity(try linkStatus(of: path)))
            #expect(snapshot.directoryIdentity == FileIdentity(try linkStatus(of: home + "/.cursor")))
            #expect(snapshot.directoryIdentity.type == .directory)
        }
    }

    @Test func refusesWhenTheFileChangedBeforeWriting() throws {
        try withHome { home in
            let path = home + "/.cursor/mcp.json"
            try write("{}", to: path)
            let snapshot = try AgentConfigFileAccess.read(path, home: home)
            try write("{ }", to: path)
            #expect(throws: AgentConfigEditError.fileChanged) { try AgentConfigFileAccess.replace(snapshot, with: Data("[]".utf8)) }
            #expect(try text(at: path) == "{ }")
            #expect(try entries(of: home + "/.cursor") == ["mcp.json"])
        }
    }

    @Test func refusesWhenTheFileWasSwappedForAnotherObjectWithTheSameContent() throws {
        try withHome { home in
            let path = home + "/.cursor/mcp.json"
            try write("{}", to: path)
            let snapshot = try AgentConfigFileAccess.read(path, home: home)
            try write("{}", to: home + "/.cursor/other.json")
            try #require(renamex_np(home + "/.cursor/other.json", path, swap) == 0)
            try FileManager.default.removeItem(atPath: home + "/.cursor/other.json")
            #expect(throws: AgentConfigEditError.fileChanged) { try AgentConfigFileAccess.replace(snapshot, with: Data("[]".utf8)) }
            #expect(try text(at: path) == "{}")
            #expect(try entries(of: home + "/.cursor") == ["mcp.json"])
        }
    }

    /// Verschwindet das alte Objekt nach dem Tausch, ist kein Rücktausch möglich: Die neue Fassung bleibt, der Fehler
    /// sagt das ehrlich – ohne den Dateinamen der Sicherung vorzutäuschen.
    @Test func reportsTheNewContentsWhenTheOldObjectVanishedBeforeTheSwapBack() throws {
        try withHome { home in
            let directory = home + "/.cursor"
            let path = directory + "/mcp.json"
            try write("{}", to: path)
            let snapshot = try AgentConfigFileAccess.read(path, home: home)
            #expect(throws: AgentConfigEditError.replacedUnverified(
                "die Datei wurde zwischenzeitlich ersetzt; die neue Fassung ist geschrieben, die vorige nicht mehr auffindbar")
            ) {
                try AgentConfigFileAccess.replace(snapshot, with: Data("[]".utf8)) {
                    for name in (try? entries(of: directory)) ?? [] where name.hasSuffix(".tmp") { unlink(directory + "/" + name) }
                }
            }
            #expect(try text(at: path) == "[]")
            #expect(try entries(of: directory) == ["mcp.json"])
            #expect(!AgentConfigEditError.replacedUnverified("x").leavesFileUnchanged)
            #expect(AgentConfigEditError.fileChanged.leavesFileUnchanged && AgentConfigEditError.writeFailed("x").leavesFileUnchanged)
        }
    }

    /// Wird die vorige Fassung nach dem Tausch geändert und fehlt dann der Name der Datei, scheitert der Rücktausch an
    /// `ENOENT` – die vorige Fassung liegt aber noch unter dem temporären Namen, und der Fehler sagt das statt „nicht mehr
    /// auffindbar“.
    @Test func reportsTheTemporaryNameWhenTheFileVanishedBeforeTheSwapBack() throws {
        try withHome { home in
            let directory = home + "/.cursor"
            let path = directory + "/mcp.json"
            try write("{}", to: path)
            let snapshot = try AgentConfigFileAccess.read(path, home: home)
            var failure: AgentConfigEditError?
            do {
                try AgentConfigFileAccess.replace(snapshot, with: Data("[]".utf8)) {
                    guard let temporary = (try? entries(of: directory))?.first(where: { $0.hasSuffix(".tmp") }) else { return }
                    try? write("{\"tool\": 1}", to: directory + "/" + temporary)
                    unlink(path)
                }
            } catch let error as AgentConfigEditError {
                failure = error
            }
            guard case .replacedUnverified(let reason)? = failure else {
                Issue.record("Erwartet replacedUnverified, erhalten \(String(describing: failure))")
                return
            }
            let temporary = try #require(try entries(of: directory).first { $0.hasSuffix(".tmp") })
            #expect(reason == "die Datei wurde zwischenzeitlich entfernt; die vorige Fassung liegt unter \(temporary)")
            #expect(try text(at: directory + "/" + temporary) == "{\"tool\": 1}")
        }
    }

    /// Wird die Datei zwischen Tausch und Nachprüfung ersetzt und der Rücktausch abgelehnt, bleibt die neue Fassung
    /// unter dem Namen und die fremde unter dem temporären – der Fehler nennt beides.
    @Test func reportsTheTemporaryNameWhenTheSwapBackIsRefused() throws {
        try withHome { home in
            let directory = home + "/.cursor"
            let path = directory + "/mcp.json"
            try write("{}", to: path)
            let snapshot = try AgentConfigFileAccess.read(path, home: home)
            defer { chmod(directory, 0o700) }
            var failure: AgentConfigEditError?
            do {
                try AgentConfigFileAccess.replace(snapshot, with: Data("[]".utf8)) {
                    guard let temporary = (try? entries(of: directory))?.first(where: { $0.hasSuffix(".tmp") }) else { return }
                    try? write("{\"other\": 1}", to: directory + "/other.json")
                    _ = rename(directory + "/other.json", directory + "/" + temporary)
                    _ = chmod(directory, 0o500)
                }
            } catch let error as AgentConfigEditError {
                failure = error
            } catch {
                Issue.record("Unerwarteter Fehler \(error)")
            }
            chmod(directory, 0o700)
            guard case .replacedUnverified(let reason)? = failure else {
                Issue.record("Erwartet replacedUnverified, erhalten \(String(describing: failure))")
                return
            }
            #expect(reason.hasPrefix("die Datei wurde zwischenzeitlich ersetzt und der Rücktausch scheiterte (Permission denied); die vorige Fassung liegt unter .mcp.json.grantry-"))
            #expect(reason.hasSuffix(".tmp"))
            #expect(try text(at: path) == "[]")
            let remaining = try entries(of: directory)
            #expect(remaining.count == 2 && remaining.contains("mcp.json"))
            let temporary = try #require(remaining.first { $0.hasSuffix(".tmp") })
            #expect(try text(at: directory + "/" + temporary) == "{\"other\": 1}")
        }
    }

    @Test func refusesWhenTheDirectoryWasReplaced() throws {
        try withHome { home in
            let path = home + "/.cursor/mcp.json"
            try write("{}", to: path)
            let snapshot = try AgentConfigFileAccess.read(path, home: home)
            try FileManager.default.moveItem(atPath: home + "/.cursor", toPath: home + "/.cursor-old")
            try write("{}", to: path)
            #expect(throws: AgentConfigEditError.fileChanged) { try AgentConfigFileAccess.replace(snapshot, with: Data("[]".utf8)) }
            #expect(try text(at: path) == "{}")
            #expect(try text(at: home + "/.cursor-old/mcp.json") == "{}")
            #expect(try entries(of: home + "/.cursor") == ["mcp.json"])
            #expect(try entries(of: home + "/.cursor-old") == ["mcp.json"])
        }
    }

    /// Regression (Review zu #129): Ein Nebenläufer tauscht den Ordner der Datei per `RENAME_SWAP` fortlaufend gegen einen
    /// Symlink auf einen fremden Ordner. Gelesen und ersetzt wird nur im gebundenen Ordner: Die fremde Datei bleibt
    /// unberührt, nirgends bleiben temporäre Dateien zurück, und jede erfolgreiche Ersetzung steht in der echten Datei.
    @Test func replacesOnlyInTheBoundDirectoryWhileTheFolderIsSwappedForASymlink() throws {
        try withHome { home in
            let project = home + "/proj/.cursor"
            let victim = home + "/victim"
            let decoy = home + "/decoy"
            try write("{}", to: project + "/mcp.json")
            try write("{\"victim\": true}", to: victim + "/mcp.json")
            try FileManager.default.createSymbolicLink(atPath: decoy, withDestinationPath: victim)

            let probe = SwapProbe()
            let swapper = Thread { [swap] in
                while probe.running.load(ordering: .relaxed) {
                    if renamex_np(project, decoy, swap) == 0 { probe.swaps.wrappingAdd(1, ordering: .relaxed) }
                }
            }
            swapper.start()
            defer { probe.running.store(false, ordering: .relaxed) }
            var replaced = 0
            var lastWritten: String?
            for iteration in 0..<500 {
                guard let snapshot = try? AgentConfigFileAccess.read(project + "/mcp.json", home: home) else { continue }
                let contents = "{\"iteration\": \(iteration)}"
                guard (try? AgentConfigFileAccess.replace(snapshot, with: Data(contents.utf8))) != nil else { continue }
                replaced += 1
                lastWritten = contents
            }
            probe.running.store(false, ordering: .relaxed)
            while !swapper.isFinished { usleep(1000) }
            // Den echten Ordner wieder unter seinen Pfad bringen, falls der letzte Tausch ihn weggedreht hat.
            if try (linkStatus(of: project).st_mode & S_IFMT) == S_IFLNK { try #require(renamex_np(project, decoy, swap) == 0) }

            #expect(probe.swaps.load(ordering: .relaxed) > 0)
            #expect(try text(at: victim + "/mcp.json") == "{\"victim\": true}")
            #expect(try entries(of: victim) == ["mcp.json"])
            #expect(try entries(of: project) == ["mcp.json"])
            if let lastWritten {
                #expect(try text(at: project + "/mcp.json") == lastWritten)
            } else {
                #expect(try text(at: project + "/mcp.json") == "{}")
            }
            #expect(replaced > 0)
        }
    }

    /// Nebenläufer ersetzt die Datei fortlaufend per `rename` (neues Objekt unter demselben Namen). Landet das zwischen
    /// Prüfung und Tausch, liegt nach dem Tausch das fremde Objekt unter dem temporären Namen: Rücktausch und
    /// `fileChanged`. Landet es noch einmal zwischen der Prüfung des Namens und dem Rücktausch, liegt die fremde Fassung
    /// danach unter dem temporären Namen – sie bleibt erhalten (`replacedUnverified` nennt sie) statt wie eine eigene
    /// gelöscht zu werden (#155). Der Versuch endet, sobald der Rücktausch-Pfad einmal durchlaufen ist – spätestens nach
    /// zehn Sekunden, damit eine ausgelastete Maschine den Test nicht zufällig scheitern lässt; danach keine Reste außer
    /// der genannten fremden Fassung, und der Inhalt ist entweder die letzte eigene oder eine fremde Fassung – nie eine
    /// Mischung.
    @Test func swapsBackWhenTheFileIsRenamedOverBetweenCheckAndSwap() throws {
        try withHome { home in
            let directory = home + "/.cursor"
            let path = directory + "/mcp.json"
            try write("{}", to: path)
            let probe = SwapProbe()
            let renamer = Thread {
                var counter = 0
                while probe.running.load(ordering: .relaxed) {
                    counter += 1
                    let fresh = directory + "/fresh-\(counter).json"
                    guard (try? Data("{\"foreign\": \(counter)}".utf8).write(to: URL(filePath: fresh))) != nil else { continue }
                    if rename(fresh, path) == 0 { probe.swaps.wrappingAdd(1, ordering: .relaxed) }
                    // Ohne Pause benennt der Nebenläufer auf schnellen Maschinen (M4) fast immer schon zwischen Lesen
                    // und Prüfung um: Jeder Versuch endet dann in `fileChanged`, der Tausch wird nie erreicht. Eine
                    // zufällige Pause bis 2 ms lässt das kurze Fenster bis zur Prüfung meist frei und trifft das lange
                    // bis zum Tausch (Schreiben mit `F_FULLFSYNC`) oft – unabhängig vom Tempo der Maschine.
                    usleep(UInt32.random(in: 0...2_000))
                }
            }
            renamer.start()
            defer { probe.running.store(false, ordering: .relaxed) }
            var swapped = 0
            var replaced = 0
            var lastWritten: String?
            var conflict: String?
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline, swapped == replaced, conflict == nil {
                guard let snapshot = try? AgentConfigFileAccess.read(path, home: home) else { continue }
                let contents = "{\"own\": \(replaced)}"
                do {
                    try AgentConfigFileAccess.replace(snapshot, with: Data(contents.utf8)) { swapped += 1 }
                    replaced += 1
                    lastWritten = contents
                } catch AgentConfigEditError.fileChanged {
                    continue
                } catch AgentConfigEditError.replacedUnverified(let reason) {
                    conflict = reason
                }
            }
            probe.running.store(false, ordering: .relaxed)
            while !renamer.isFinished { usleep(1000) }

            #expect(probe.swaps.load(ordering: .relaxed) > 0)
            #expect(swapped > replaced, "Rücktausch-Pfad nicht durchlaufen (\(swapped) Tausche, \(replaced) Erfolge)")
            let remaining = try entries(of: directory)
            if let conflict {
                let temporary = try #require(remaining.first { $0.hasSuffix(".tmp") })
                #expect(conflict == "die Datei wurde zwischenzeitlich durch ein anderes Programm ersetzt oder verändert; die vorige Fassung steht wieder unter ihrem Namen, die fremde liegt unter \(temporary)")
                #expect(try text(at: directory + "/" + temporary).hasPrefix("{\"foreign\": "))
                #expect(remaining == [temporary, "mcp.json"])
            } else {
                #expect(remaining == ["mcp.json"])
            }
            let final = try text(at: path)
            #expect(final == lastWritten || final.hasPrefix("{\"foreign\": "))
        }
    }

    /// Schreibt ein Tool nach dem Tausch noch in das alte Objekt, fällt das an der Größe auf, ohne es zu lesen:
    /// Rücktausch, `fileChanged`, keine Reste.
    @Test func swapsBackWhenTheOldObjectGrewAfterTheSwap() throws {
        try withHome { home in
            let directory = home + "/.cursor"
            let path = directory + "/mcp.json"
            try write("{}", to: path)
            let snapshot = try AgentConfigFileAccess.read(path, home: home)
            #expect(throws: AgentConfigEditError.fileChanged) {
                try AgentConfigFileAccess.replace(snapshot, with: Data("[]".utf8)) {
                    guard let temporary = (try? entries(of: directory))?.first(where: { $0.hasSuffix(".tmp") }),
                          let appender = try? FileHandle(forWritingTo: URL(filePath: directory + "/" + temporary)) else { return }
                    _ = try? appender.seekToEnd()
                    try? appender.write(contentsOf: Data(" ".utf8))
                    try? appender.close()
                }
            }
            #expect(try text(at: path) == "{} ")
            #expect(try entries(of: directory) == ["mcp.json"])
        }
    }

    /// Regression (Codex-Review 2026.10.6, #155): Schreibt ein Tool nach dem Tausch über einen offenen Deskriptor in die
    /// vorige Fassung und legt dann eine noch neuere per `rename` unter den Namen, darf der Rücktausch diese nicht
    /// unter den temporären Namen drehen und löschen. Sie bleibt unter dem Namen, die vorige unter dem temporären –
    /// der Fehler nennt beides, und die Sicherung bleibt (`replacedUnverified`).
    @Test func keepsANewerForeignVersionInsteadOfSwappingItAway() throws {
        try withHome { home in
            let directory = home + "/.cursor"
            let path = directory + "/mcp.json"
            try write("{}", to: path)
            let snapshot = try AgentConfigFileAccess.read(path, home: home)
            var failure: AgentConfigEditError?
            do {
                try AgentConfigFileAccess.replace(snapshot, with: Data("[]".utf8)) {
                    guard let temporary = (try? entries(of: directory))?.first(where: { $0.hasSuffix(".tmp") }),
                          let appender = try? FileHandle(forWritingTo: URL(filePath: directory + "/" + temporary)) else { return }
                    _ = try? appender.seekToEnd()
                    try? appender.write(contentsOf: Data(" ".utf8))
                    try? appender.close()
                    try? write("{\"tool\": 2}", to: directory + "/fresh.json")
                    _ = rename(directory + "/fresh.json", path)
                }
            } catch let error as AgentConfigEditError {
                failure = error
            }
            guard case .replacedUnverified(let reason)? = failure else {
                Issue.record("Erwartet replacedUnverified, erhalten \(String(describing: failure))")
                return
            }
            let remaining = try entries(of: directory)
            let temporary = try #require(remaining.first { $0.hasSuffix(".tmp") })
            #expect(reason == "die Datei wurde zwischenzeitlich durch ein anderes Programm ersetzt oder verändert und bleibt so; die vorige Fassung liegt unter \(temporary)")
            #expect(try text(at: path) == "{\"tool\": 2}")
            #expect(try text(at: directory + "/" + temporary) == "{} ")
            #expect(remaining == [temporary, "mcp.json"])
        }
    }

    /// Regression (Codex-Review zu #155, Folge): Schreibt ein Tool nach dem Tausch über einen alten Deskriptor in die
    /// vorige Fassung und danach über den Namen in die neue – in-place, dasselbe Objekt –, beweist der Inode allein
    /// nichts mehr: Der Rücktausch unterbleibt, beide Fassungen bleiben, `replacedUnverified` nennt beide Orte.
    @Test func keepsAVersionEditedInPlaceInsteadOfSwappingItAway() throws {
        try withHome { home in
            let directory = home + "/.cursor"
            let path = directory + "/mcp.json"
            try write("{}", to: path)
            let snapshot = try AgentConfigFileAccess.read(path, home: home)
            var failure: AgentConfigEditError?
            var ownIdentity: FileIdentity?
            do {
                try AgentConfigFileAccess.replace(snapshot, with: Data("[]".utf8)) {
                    guard let temporary = (try? entries(of: directory))?.first(where: { $0.hasSuffix(".tmp") }),
                          let appender = try? FileHandle(forWritingTo: URL(filePath: directory + "/" + temporary)) else { return }
                    _ = try? appender.seekToEnd()
                    try? appender.write(contentsOf: Data(" ".utf8))
                    try? appender.close()
                    ownIdentity = (try? linkStatus(of: path)).map(FileIdentity.init)
                    guard let editor = try? FileHandle(forWritingTo: URL(filePath: path)) else { return }
                    try? editor.truncate(atOffset: 0)
                    try? editor.write(contentsOf: Data("{\"tool\": 2}".utf8))
                    try? editor.close()
                }
            } catch let error as AgentConfigEditError {
                failure = error
            }
            guard case .replacedUnverified(let reason)? = failure else {
                Issue.record("Erwartet replacedUnverified, erhalten \(String(describing: failure))")
                return
            }
            let remaining = try entries(of: directory)
            let temporary = try #require(remaining.first { $0.hasSuffix(".tmp") })
            #expect(reason == "die Datei wurde zwischenzeitlich durch ein anderes Programm ersetzt oder verändert und bleibt so; die vorige Fassung liegt unter \(temporary)")
            #expect(FileIdentity(try linkStatus(of: path)) == ownIdentity)
            #expect(try text(at: path) == "{\"tool\": 2}")
            #expect(try text(at: directory + "/" + temporary) == "{} ")
            #expect(remaining == [temporary, "mcp.json"])
        }
    }

    /// Ein nach dem Lesen hinzugekommener zweiter Name ist eine Änderung der Datei, kein Dauerzustand.
    @Test func treatsAHardLinkAddedAfterReadingAsAChange() throws {
        try withHome { home in
            let path = home + "/.cursor/mcp.json"
            try write("{}", to: path)
            let snapshot = try AgentConfigFileAccess.read(path, home: home)
            try FileManager.default.linkItem(atPath: path, toPath: home + "/.cursor/zweitname.json")
            #expect(throws: AgentConfigEditError.fileChanged) { try AgentConfigFileAccess.replace(snapshot, with: Data("[]".utf8)) }
            #expect(try text(at: path) == "{}")
            #expect(try entries(of: home + "/.cursor") == ["mcp.json", "zweitname.json"])
        }
    }

    @Test func keepsACLExtendedAttributesAndHiddenFlag() throws {
        try withHome { home in
            let path = home + "/.cursor/mcp.json"
            try write("{}", to: path)
            let chmod = Process()
            chmod.executableURL = URL(filePath: "/bin/chmod")
            chmod.arguments = ["+a", "everyone deny write", path]
            try chmod.run()
            chmod.waitUntilExit()
            try #require(chmod.terminationStatus == 0)
            try #require(setxattr(path, "de.cstrube.grantry.test", "x", 1, 0, 0) == 0)
            try #require(chflags(path, UInt32(UF_HIDDEN)) == 0)

            let snapshot = try AgentConfigFileAccess.read(path, home: home)
            try AgentConfigFileAccess.replace(snapshot, with: Data("[]".utf8))

            #expect(try text(at: path) == "[]")
            #expect(try linkStatus(of: path).st_flags & UInt32(UF_HIDDEN) != 0)
            var value = [UInt8](repeating: 0, count: 4)
            #expect(getxattr(path, "de.cstrube.grantry.test", &value, value.count, 0, 0) == 1)
            #expect(value[0] == UInt8(ascii: "x"))
            let acl = try #require(acl_get_link_np(path, ACL_TYPE_EXTENDED))
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            let description = String(cString: try #require(acl_to_text(acl, nil)))
            #expect(description.contains("deny:write"))
            #expect(try entries(of: home + "/.cursor") == ["mcp.json"])
        }
    }

    @Test func refusesProtectedFilesWithoutLeavingTemporaryFiles() throws {
        try withHome { home in
            let path = home + "/.cursor/mcp.json"
            try write("{}", to: path)
            let snapshot = try AgentConfigFileAccess.read(path, home: home)
            try #require(chflags(path, UInt32(UF_IMMUTABLE)) == 0)
            defer { chflags(path, 0) }
            #expect(throws: AgentConfigEditError.notEditable("Die Datei ist geschützt")) {
                try AgentConfigFileAccess.read(path, home: home)
            }
            #expect(throws: AgentConfigEditError.notEditable("Die Datei ist geschützt")) {
                try AgentConfigFileAccess.replace(snapshot, with: Data("[]".utf8))
            }
            #expect(try text(at: path) == "{}")
            #expect(try entries(of: home + "/.cursor") == ["mcp.json"])
        }
    }

    /// Braucht eine zweite Gruppe des Benutzers; ohne sie wird der Test übersprungen.
    @Test(.enabled(if: Self.userBelongsToSeveralGroups(), "Benutzer ist nur in einer Gruppe"))
    func keepsTheGroup() throws {
        try withHome { home in
            let path = home + "/.cursor/mcp.json"
            try write("{}", to: path)
            let inherited = try linkStatus(of: path).st_gid
            let other = try #require(Self.userGroups().first { $0 != inherited })
            try #require(chown(path, uid_t.max, other) == 0)

            let snapshot = try AgentConfigFileAccess.read(path, home: home)
            try AgentConfigFileAccess.replace(snapshot, with: Data("[]".utf8))
            #expect(try linkStatus(of: path).st_gid == other)
            #expect(try text(at: path) == "[]")
        }
    }

    @Test func refusesFIFOsAndDirectories() throws {
        try withHome { home in
            try FileManager.default.createDirectory(atPath: home + "/.cursor", withIntermediateDirectories: true)
            try #require(mkfifo(home + "/.cursor/mcp.json", 0o600) == 0)
            #expect(throws: AgentConfigEditError.notEditable("Keine reguläre Datei")) {
                try AgentConfigFileAccess.read(home + "/.cursor/mcp.json", home: home)
            }
            #expect(throws: AgentConfigEditError.notEditable("Keine reguläre Datei")) {
                try AgentConfigFileAccess.read(home + "/.cursor", home: home)
            }
        }
    }

    @Test func reportsGrowthOrShrinkageBetweenStatAndRead() throws {
        try withHome { home in
            let path = home + "/.cursor/mcp.json"
            try write("{}", to: path)
            let descriptor = open(path, O_RDONLY)
            try #require(descriptor >= 0)
            defer { close(descriptor) }
            let announced = Int(try linkStatus(of: path).st_size)
            let appender = try FileHandle(forWritingTo: URL(filePath: path))
            try appender.seekToEnd()
            try appender.write(contentsOf: Data(" ".utf8))
            try appender.close()
            #expect(throws: AgentConfigEditError.fileChanged) {
                try AgentConfigFileAccess.contents(of: descriptor, expectedSize: announced)
            }
            try #require(lseek(descriptor, 0, SEEK_SET) == 0)
            try #require(truncate(path, 1) == 0)
            #expect(throws: AgentConfigEditError.fileChanged) {
                try AgentConfigFileAccess.contents(of: descriptor, expectedSize: announced)
            }
            try #require(lseek(descriptor, 0, SEEK_SET) == 0)
            #expect(try AgentConfigFileAccess.contents(of: descriptor, expectedSize: 1) == Data("{".utf8))
        }
    }

    @Test func refusesNetworkVolumesPlaceholdersAndProtectedFlags() {
        #expect(AgentConfigFileAccess.volumeRefusal(flags: UInt32(MNT_LOCAL)) == nil)
        #expect(AgentConfigFileAccess.volumeRefusal(flags: 0) == "Die Datei liegt auf einem Netzlaufwerk")
        #expect(AgentConfigFileAccess.volumeRefusal(flags: UInt32(MNT_LOCAL | MNT_RDONLY)) == "Das Volume ist schreibgeschützt")

        #expect(AgentConfigFileAccess.flagRefusal(flags: 0) == nil)
        #expect(AgentConfigFileAccess.flagRefusal(flags: UInt32(UF_HIDDEN | UF_NODUMP)) == nil)
        #expect(AgentConfigFileAccess.flagRefusal(flags: UInt32(SF_DATALESS)) == "Die Datei ist ein iCloud-Platzhalter und noch nicht geladen")
        for flag in [UF_IMMUTABLE, SF_IMMUTABLE, UF_APPEND, SF_APPEND] {
            #expect(AgentConfigFileAccess.flagRefusal(flags: UInt32(flag)) == "Die Datei ist geschützt")
        }

        let mixed = UInt32(UF_HIDDEN | UF_NODUMP | UF_COMPRESSED | UF_TRACKED | SF_ARCHIVED)
        #expect(AgentConfigFileAccess.preservedFlags(mixed) == UInt32(UF_HIDDEN | UF_NODUMP))
    }

    @Test func refusesSymlinksAnywhereInThePath() throws {
        try withHome { home in
            try write("{}", to: home + "/real/mcp.json")
            try FileManager.default.createSymbolicLink(atPath: home + "/.cursor", withDestinationPath: home + "/real")
            try FileManager.default.createDirectory(atPath: home + "/.codeium", withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: home + "/.codeium/mcp.json", withDestinationPath: home + "/real/mcp.json")
            for path in [home + "/.cursor/mcp.json", home + "/.codeium/mcp.json"] {
                #expect(throws: AgentConfigEditError.notEditable("Der Pfad enthält einen symbolischen Link")) {
                    try AgentConfigFileAccess.read(path, home: home)
                }
            }
        }
    }

    @Test func refusesFilesOutsideHomeHardLinksAndLargeFiles() throws {
        try withHome { home in
            try write("{}", to: home + "/a.json")
            #expect(throws: AgentConfigEditError.notEditable("Die Datei liegt außerhalb deines Benutzerordners")) {
                try AgentConfigFileAccess.read(home + "/a.json", home: home + "/sub")
            }
            #expect(throws: AgentConfigEditError.notEditable("Die Datei liegt außerhalb deines Benutzerordners")) {
                try AgentConfigFileAccess.read(home + "/sub/../a.json", home: home)
            }
            try FileManager.default.linkItem(atPath: home + "/a.json", toPath: home + "/b.json")
            #expect(throws: AgentConfigEditError.notEditable("Die Datei hat mehrere Namen (Hardlink)")) {
                try AgentConfigFileAccess.read(home + "/a.json", home: home)
            }
            try write(String(repeating: " ", count: 20), to: home + "/c.json")
            #expect(throws: AgentConfigEditError.unreadable("größer als 10 Bytes")) {
                try AgentConfigFileAccess.read(home + "/c.json", home: home, maximumSize: 10)
            }
            #expect(throws: AgentConfigEditError.missing) { try AgentConfigFileAccess.read(home + "/fehlt.json", home: home) }
            #expect(throws: AgentConfigEditError.missing) { try AgentConfigFileAccess.read(home + "/fehlt/mcp.json", home: home) }
        }
    }
}
