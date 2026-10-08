import Testing
import Foundation
import Synchronization
import TestSupport
import GrantryShared
@testable import HelperCore

@Suite struct HelperServiceTests {
    /// Ruft eine Reply-basierte Methode auf und wartet auf die Antwort.
    private func await1<T: Sendable>(_ call: (@escaping @Sendable (T) -> Void) -> Void) async -> T {
        await withCheckedContinuation { continuation in call { continuation.resume(returning: $0) } }
    }

    /// Verzeichnisse eines Scratch-Systems: `LaunchDaemons`, `LaunchAgents`, Apples `System/Library/LaunchDaemons`
    /// und der Backup-Speicher.
    private struct Layout {
        let daemons: URL
        let agents: URL
        let appleDaemons: URL
        let backups: URL

        init(_ root: URL) {
            daemons = root.appending(path: "LaunchDaemons")
            agents = root.appending(path: "LaunchAgents")
            appleDaemons = root.appending(path: "System/Library/LaunchDaemons")
            backups = root.appending(path: "Backups")
        }
    }

    private func service(_ runner: any CommandRunning, layout: Layout? = nil) -> HelperService {
        let layout = layout ?? Layout(URL(fileURLWithPath: "/nonexistent"))
        return HelperService(
            runner: runner,
            backups: PlistBackupStore(root: layout.backups, managedDirectories: [layout.agents.path, layout.daemons.path]),
            launchDaemonsDirectory: layout.daemons.path,
            additionalDaemonDirectories: [layout.appleDaemons.path]
        )
    }

    private func withLayout(_ body: (Layout) async throws -> Void) async throws {
        try await ScratchDirectory.with { dir in
            let layout = Layout(dir)
            for directory in [layout.daemons, layout.agents, layout.appleDaemons] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try await body(layout)
        }
    }

    /// Befehlszeile der Ladezustandsprüfung für `label` in der Domain `system`.
    private static func probe(_ label: String) -> String { "/bin/launchctl print system/\(label)" }

    /// `launchctl print system/<label>`, wenn kein Dienst mit dem Label geladen ist.
    private static let notLoaded = CommandResult(exitCode: 113, stdout: "", stderr: "Could not find service")

    /// `launchctl print system/<label>` eines aus `plist` geladenen Dienstes.
    private static func loaded(from plist: String) -> CommandResult {
        CommandResult(exitCode: 0, stdout: "system/x = {\n\tactive count = 1\n\tpath = \(plist)\n\ttype = LaunchDaemon\n}\n")
    }

    private static let ok = CommandResult(exitCode: 0, stdout: "")

    /// launchd kennt `com.example.daemon` nicht (Standard-Daemon der Entfernen-Tests).
    private static var daemonNotLoaded: MockCommandRunner { MockCommandRunner([probe("com.example.daemon"): notLoaded]) }

    /// Ruft `unloadAndRemovePlist` auf; Antwort: Backup-Pfad, ob entladen wurde, Fehlermeldung.
    private func remove(
        _ path: String, expecting fingerprint: Data? = nil, on service: HelperService
    ) async -> (backup: String?, unloaded: Bool, error: String?) {
        await await1 { reply in
            service.unloadAndRemovePlist(path: path, expectedFingerprint: fingerprint) { reply(($0, $1, $2)) }
        }
    }

    @Test func protocolVersionMatchesSharedConstant() async {
        let version = await await1 { reply in service(MockCommandRunner()).protocolVersion(reply: reply) }
        #expect(version == HelperXPC.protocolVersion)
    }

    @Test func dumpBTMReturnsStdout() async {
        let runner = MockCommandRunner(["/usr/bin/sfltool dumpbtm": CommandResult(exitCode: 0, stdout: "Records for UID 501")])
        let (output, error) = await await1 { reply in service(runner).dumpBTM { reply(($0, $1)) } }
        #expect(output == "Records for UID 501")
        #expect(error == nil)
    }

    @Test func dumpBTMReportsFailure() async {
        let runner = MockCommandRunner(["/usr/bin/sfltool dumpbtm": CommandResult(exitCode: 1, stdout: "", stderr: "boom")])
        let (output, error) = await await1 { reply in service(runner).dumpBTM { reply(($0, $1)) } }
        #expect(output == nil)
        #expect(error?.contains("boom") == true)
    }

    @Test func listListeningSocketsReturnsEncodedScan() async throws {
        let expected = ListeningSocketScan(sockets: [ListeningSocket(
            pid: 7, uid: 0, executablePath: "/usr/local/bin/mcp", transport: .tcp, localAddress: "0.0.0.0", localPort: 8080
        )], deniedProcessCount: 2)
        let service = HelperService(runner: MockCommandRunner(), socketEnumerator: FixedSockets(result: .success(expected)))
        let (data, error) = await await1 { reply in service.listListeningSockets { reply(($0, $1)) } }
        #expect(error == nil)
        #expect(try JSONDecoder().decode(ListeningSocketScan.self, from: try #require(data)) == expected)
    }

    @Test func listListeningSocketsReportsFailure() async {
        let failure = ListeningSocketError(code: EPERM)
        let service = HelperService(runner: MockCommandRunner(), socketEnumerator: FixedSockets(result: .failure(failure)))
        let (data, error) = await await1 { reply in service.listListeningSockets { reply(($0, $1)) } }
        #expect(data == nil)
        #expect(error == failure.errorDescription)
    }

    @Test func setEnabledRunsLaunchctlWithLabelReadFromPlist() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.docker.helper", named: "docker.plist", in: layout.daemons)
            let runner = MockCommandRunner([
                Self.probe("com.docker.helper"): Self.notLoaded,
                "/bin/launchctl disable system/com.docker.helper": Self.ok,
                "/bin/launchctl enable system/com.docker.helper": Self.ok,
            ])
            let sut = service(runner, layout: layout)

            let disableError = await await1 { reply in sut.setEnabled(plistPath: plist.path, enabled: false, reply: reply) }
            let enableError = await await1 { reply in sut.setEnabled(plistPath: plist.path, enabled: true, reply: reply) }
            #expect(disableError == nil)
            #expect(enableError == nil)
            #expect(runner.calls == [
                Self.probe("com.docker.helper"), "/bin/launchctl disable system/com.docker.helper",
                Self.probe("com.docker.helper"), "/bin/launchctl enable system/com.docker.helper",
            ])
        }
    }

    /// Entladen läuft pfadgebunden (`bootout system <plist>`), nachdem launchd bestätigt hat, dass der Dienst aus
    /// genau dieser Plist geladen ist; Laden ohnehin (`bootstrap system <plist>`).
    @Test func bootoutAndBootstrapActInSystemDomainBoundToThePlistPath() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: layout.daemons)
            let canonical = plist.resolvingSymlinksInPath().path
            let runner = MockCommandRunner([
                Self.probe("com.example.daemon"): Self.loaded(from: canonical),
                "/bin/launchctl bootout system \(canonical)": Self.ok,
                "/bin/launchctl bootstrap system \(canonical)": Self.ok,
            ])
            let sut = service(runner, layout: layout)

            let bootoutError = await await1 { reply in sut.bootout(plistPath: plist.path, reply: reply) }
            runner.stub(Self.probe("com.example.daemon"), Self.notLoaded)
            let bootstrapError = await await1 { reply in sut.bootstrap(plistPath: plist.path, reply: reply) }
            #expect(bootoutError == nil)
            #expect(bootstrapError == nil)
            #expect(runner.calls == [
                Self.probe("com.example.daemon"), "/bin/launchctl bootout system \(canonical)",
                Self.probe("com.example.daemon"), "/bin/launchctl bootstrap system \(canonical)",
            ])
        }
    }

    /// Der von launchd gemeldete Pfad darf anders geschrieben sein: `.`-Komponenten und – weil
    /// `temporaryDirectory` unter `/var` liegt, der kanonische Pfad aber unter `/private/var` – ein nicht aufgelöster
    /// Symlink im Verzeichnispfad.
    @Test func loadedPathIsComparedCanonically() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: layout.daemons)
            let canonical = plist.resolvingSymlinksInPath().path
            let runner = MockCommandRunner([
                Self.probe("com.example.daemon"): Self.loaded(from: layout.daemons.appending(path: "./com.example.daemon.plist").path),
                "/bin/launchctl bootout system \(canonical)": Self.ok,
            ])
            let error = await await1 { reply in service(runner, layout: layout).bootout(plistPath: plist.path, reply: reply) }
            #expect(error == nil)
            #expect(runner.calls.last == "/bin/launchctl bootout system \(canonical)")
        }
    }

    @Test func reportsLaunchctlFailureWithStderr() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: layout.daemons)
            let canonical = plist.resolvingSymlinksInPath().path
            let runner = MockCommandRunner([
                Self.probe("com.example.daemon"): Self.loaded(from: canonical),
                "/bin/launchctl bootout system \(canonical)": CommandResult(exitCode: 3, stdout: "", stderr: "No such process"),
            ])
            let error = await await1 { reply in service(runner, layout: layout).bootout(plistPath: plist.path, reply: reply) }
            #expect(error?.contains("Exit 3") == true)
            #expect(error?.contains("No such process") == true)
        }
    }

    // MARK: - Label-Kollision (#99)

    /// Unter dem Label ist ein Dienst aus einer **anderen** Plist geladen (etwa der echte Dienst neben einer Kopie
    /// seines Labels): Keine der Operationen darf laufen – labelgebunden träfe sie den fremden Dienst.
    @Test func rejectsEveryOperationWhenLabelIsLoadedFromAnotherPlist() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "org.cups.cupsd", named: "copy.plist", in: layout.daemons)
            let runner = MockCommandRunner([
                Self.probe("org.cups.cupsd"): Self.loaded(from: layout.appleDaemons.appending(path: "org.cups.cupsd.plist").path),
            ])
            let sut = service(runner, layout: layout)
            let errors = [
                await await1 { reply in sut.setEnabled(plistPath: plist.path, enabled: false, reply: reply) },
                await await1 { reply in sut.setEnabled(plistPath: plist.path, enabled: true, reply: reply) },
                await await1 { reply in sut.bootout(plistPath: plist.path, reply: reply) },
                await await1 { reply in sut.bootstrap(plistPath: plist.path, reply: reply) },
            ]
            for error in errors {
                #expect(error?.contains("anderen Datei") == true)
                #expect(error?.contains("org.cups.cupsd") == true)
            }
            #expect(runner.calls == Array(repeating: Self.probe("org.cups.cupsd"), count: 4))
        }
    }

    /// Ein geladener Dienst ohne erkennbaren Plist-Pfad gilt ebenfalls als fremd.
    @Test func loadedServiceWithoutPathCountsAsConflict() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: layout.daemons)
            let runner = MockCommandRunner([
                Self.probe("com.example.daemon"): CommandResult(exitCode: 0, stdout: "system/com.example.daemon = {\n\ttype = LaunchDaemon\n}\n"),
            ])
            let error = await await1 { reply in service(runner, layout: layout).setEnabled(plistPath: plist.path, enabled: false, reply: reply) }
            #expect(error?.contains("anderen Datei") == true)
            #expect(runner.calls == [Self.probe("com.example.daemon")])
        }
    }

    /// Der Override (`enable`/`disable`) ist in launchd zwingend labelgebunden. Trägt eine zweite Plist der Domain
    /// `system` dasselbe Label – auch wenn gerade keine geladen ist –, würde sie mit umgeschaltet: ablehnen.
    @Test func setEnabledRejectsWhenAnotherPlistInSystemDomainSharesTheLabel() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", named: "mine.plist", in: layout.daemons)
            let twins = [
                try LaunchdPlistFixture.write(label: "com.example.daemon", named: "twin.plist", in: layout.daemons),
                try LaunchdPlistFixture.write(label: "com.example.daemon", named: "apple.plist", in: layout.appleDaemons),
            ]
            for twin in twins {
                let runner = MockCommandRunner([Self.probe("com.example.daemon"): Self.notLoaded])
                for enabled in [false, true] {
                    let error = await await1 { reply in service(runner, layout: layout).setEnabled(plistPath: plist.path, enabled: enabled, reply: reply) }
                    #expect(error?.contains(twin.lastPathComponent) == true)
                    #expect(error?.contains("com.example.daemon") == true)
                }
                #expect(runner.calls == [Self.probe("com.example.daemon"), Self.probe("com.example.daemon")])
                try FileManager.default.removeItem(at: twin)
            }
        }
    }

    /// Eine weitere Plist der Domain `system`, deren Label sich nicht prüfen lässt (übergroß, kaputt), könnte dasselbe
    /// Label tragen: Der Helper lehnt den Override ab (fail-closed), bevor launchctl etwas ändert.
    @Test func setEnabledRejectsWhenAnotherPlistIsUnverifiable() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: layout.daemons)
            let twins = [
                (layout.daemons.appending(path: "big.plist"), Data(count: PrivilegedOperationPolicy.maximumPlistSize + 1)),
                (layout.appleDaemons.appending(path: "broken.plist"), Data("garbage".utf8)),
            ]
            for (twin, contents) in twins {
                try contents.write(to: twin)
                let runner = MockCommandRunner([Self.probe("com.example.daemon"): Self.notLoaded])
                let error = await await1 { reply in service(runner, layout: layout).setEnabled(plistPath: plist.path, enabled: false, reply: reply) }
                #expect(error?.contains(twin.lastPathComponent) == true)
                #expect(runner.calls == [Self.probe("com.example.daemon")])
                try FileManager.default.removeItem(at: twin)
            }
        }
    }

    /// Andere Labels, Nicht-Plists und Einträge, die keine reguläre Datei sind, stören nicht.
    @Test func setEnabledIgnoresUnrelatedFilesInDaemonDirectories() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: layout.daemons)
            try LaunchdPlistFixture.write(label: "com.example.other", in: layout.daemons)
            try LaunchdPlistFixture.write(label: "com.example.daemon", named: "notes.txt", in: layout.daemons)
            try FileManager.default.createDirectory(
                at: layout.appleDaemons.appending(path: "folder.plist"), withIntermediateDirectories: true
            )
            let runner = MockCommandRunner([
                Self.probe("com.example.daemon"): Self.notLoaded,
                "/bin/launchctl disable system/com.example.daemon": Self.ok,
            ])
            let error = await await1 { reply in service(runner, layout: layout).setEnabled(plistPath: plist.path, enabled: false, reply: reply) }
            #expect(error == nil)
            #expect(runner.calls == [Self.probe("com.example.daemon"), "/bin/launchctl disable system/com.example.daemon"])
        }
    }

    /// Ist der Dienst aus dieser Plist geladen und das Label eindeutig, läuft der Override.
    @Test func setEnabledRunsForLoadedDaemonWithUniqueLabel() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: layout.daemons)
            try LaunchdPlistFixture.write(label: "com.example.other", in: layout.appleDaemons)
            let runner = MockCommandRunner([
                Self.probe("com.example.daemon"): Self.loaded(from: plist.resolvingSymlinksInPath().path),
                "/bin/launchctl disable system/com.example.daemon": Self.ok,
            ])
            let error = await await1 { reply in service(runner, layout: layout).setEnabled(plistPath: plist.path, enabled: false, reply: reply) }
            #expect(error == nil)
            #expect(runner.calls == [Self.probe("com.example.daemon"), "/bin/launchctl disable system/com.example.daemon"])
        }
    }

    /// Ein doppeltes Label blockiert nur den labelgebundenen Override: `bootout`/`bootstrap` tragen den Plist-Pfad und
    /// laufen, solange launchd den Dienst dieser Plist (bzw. keinem) zuordnet.
    @Test func ambiguousLabelDoesNotBlockBootoutAndBootstrap() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", named: "mine.plist", in: layout.daemons)
            try LaunchdPlistFixture.write(label: "com.example.daemon", named: "twin.plist", in: layout.appleDaemons)
            let canonical = plist.resolvingSymlinksInPath().path
            let runner = MockCommandRunner([
                Self.probe("com.example.daemon"): Self.loaded(from: canonical),
                "/bin/launchctl bootout system \(canonical)": Self.ok,
                "/bin/launchctl bootstrap system \(canonical)": Self.ok,
            ])
            let sut = service(runner, layout: layout)
            let bootoutError = await await1 { reply in sut.bootout(plistPath: plist.path, reply: reply) }
            runner.stub(Self.probe("com.example.daemon"), Self.notLoaded)
            let bootstrapError = await await1 { reply in sut.bootstrap(plistPath: plist.path, reply: reply) }
            #expect(bootoutError == nil)
            #expect(bootstrapError == nil)
            #expect(runner.calls.filter { !$0.contains(" print ") } == [
                "/bin/launchctl bootout system \(canonical)", "/bin/launchctl bootstrap system \(canonical)",
            ])
        }
    }

    /// Wirft die Abfrage selbst (Start-/Zeitfehler), antwortet der Helper mit deren Meldung und führt nichts aus.
    @Test func throwingProbeStopsBeforeAnyChange() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: layout.daemons)
            let runner = ThrowingRunner(error: CommandError.timedOut(executable: "/bin/launchctl", seconds: 10))
            let error = await await1 { reply in service(runner, layout: layout).setEnabled(plistPath: plist.path, enabled: false, reply: reply) }
            #expect(error?.contains("kein Ergebnis") == true)
            #expect(runner.calls == [Self.probe("com.example.daemon")])
        }
    }

    /// Nicht geladen: Es gibt nichts zu entladen – Ziel erreicht, kein Befehl. Entsprechend lädt `bootstrap` einen
    /// bereits aus dieser Plist geladenen Dienst nicht erneut.
    @Test func bootoutOfUnloadedAndBootstrapOfLoadedDaemonDoNothing() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: layout.daemons)
            let canonical = plist.resolvingSymlinksInPath().path
            let runner = MockCommandRunner([Self.probe("com.example.daemon"): Self.notLoaded])
            let sut = service(runner, layout: layout)
            let bootoutError = await await1 { reply in sut.bootout(plistPath: plist.path, reply: reply) }
            runner.stub(Self.probe("com.example.daemon"), Self.loaded(from: canonical))
            let bootstrapError = await await1 { reply in sut.bootstrap(plistPath: plist.path, reply: reply) }
            #expect(bootoutError == nil)
            #expect(bootstrapError == nil)
            #expect(runner.calls == [Self.probe("com.example.daemon"), Self.probe("com.example.daemon")])
        }
    }

    /// Lässt sich der Ladezustand nicht feststellen, läuft kein verändernder Befehl.
    @Test func failedProbeStopsBeforeAnyChange() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: layout.daemons)
            let runner = MockCommandRunner([Self.probe("com.example.daemon"): CommandResult(exitCode: 5, stdout: "", stderr: "Input/output error")])
            let sut = service(runner, layout: layout)
            let calls: [(@escaping @Sendable (String?) -> Void) -> Void] = [
                { sut.setEnabled(plistPath: plist.path, enabled: false, reply: $0) },
                { sut.bootout(plistPath: plist.path, reply: $0) },
                { sut.bootstrap(plistPath: plist.path, reply: $0) },
            ]
            for call in calls {
                let error = await await1(call)
                #expect(error?.contains("launchctl print system/com.example.daemon") == true)
                #expect(error?.contains("Exit 5") == true)
                #expect(error?.contains("Input/output error") == true)
            }
            #expect(runner.calls == Array(repeating: Self.probe("com.example.daemon"), count: 3))
        }
    }

    @Test func rejectsAppleLabelReadFromPlistWithoutRunningAnything() async throws {
        try await withLayout { layout in
            // Harmloser Dateiname, aber Apple-Label im Inhalt: maßgeblich ist das gelesene Label.
            let plist = try LaunchdPlistFixture.write(label: "com.apple.screensharing", named: "innocent.plist", in: layout.daemons)
            let runner = MockCommandRunner()
            let error = await await1 { reply in service(runner, layout: layout).bootout(plistPath: plist.path, reply: reply) }
            #expect(error?.contains("Apple") == true)
            #expect(runner.calls.isEmpty)
        }
    }

    @Test func rejectsPlistOutsideLaunchDaemonsWithoutRunningAnything() async throws {
        try await withLayout { layout in
            let agent = try LaunchdPlistFixture.write(label: "com.example.agent", in: layout.agents)
            let runner = MockCommandRunner()
            let sut = service(runner, layout: layout)
            for path in [agent.path, "/etc/hosts"] {
                let error = await await1 { reply in sut.setEnabled(plistPath: path, enabled: false, reply: reply) }
                #expect(error != nil)
            }
            #expect(runner.calls.isEmpty)
        }
    }

    @Test func removeAndRestorePlistRoundTrip() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: layout.daemons)
            let original = try Data(contentsOf: plist)
            let sut = service(Self.daemonNotLoaded, layout: layout)

            let (backup, _, removeError) = await remove(plist.path, on: sut)
            #expect(removeError == nil)
            #expect(!FileManager.default.fileExists(atPath: plist.path))

            let (restored, restoreError) = await await1 { reply in sut.restorePlist(backupPath: backup ?? "") { reply(($0, $1)) } }
            #expect(restoreError == nil)
            #expect(restored == plist.resolvingSymlinksInPath().path)
            #expect(FileManager.default.contents(atPath: plist.path) == original)
        }
    }

    /// #156, Codex-Runde 3: Der Helper sichert und löscht nur eine Plist mit dem Fingerabdruck aus dem Scan der App.
    /// Ersetzt oder umgeschrieben: keine Sicherung, nichts gelöscht, verständliche Meldung.
    @Test(arguments: [false, true])
    func removeRefusesAPlistThatNoLongerCarriesTheScanFingerprint(replaced: Bool) async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: layout.daemons)
            let scanned = try JSONEncoder().encode(FileFingerprint(status: try Self.linkStatus(plist)))
            if replaced {
                try FileManager.default.removeItem(at: plist)
                try LaunchdPlistFixture.write(payload: ["Label": "com.example.daemon", "New": true], named: plist.lastPathComponent, in: layout.daemons)
            } else {
                try LaunchdPlistFixture.overwriteInPlace(plist, payload: ["Label": "com.example.daemon", "New": true])
            }
            let (backup, _, error) = await remove(plist.path, expecting: scanned, on: service(Self.daemonNotLoaded, layout: layout))
            #expect(backup == nil)
            #expect(error?.contains("bitte neu scannen") == true)
            let current = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
            #expect(current?["New"] as? Bool == true)
            let leftovers = (try? FileManager.default.subpathsOfDirectory(atPath: layout.backups.path)) ?? []
            #expect(!leftovers.contains { $0.hasSuffix(".plist") })
        }
    }

    /// Mit dem Fingerabdruck aus dem Scan wird gesichert und gelöscht.
    @Test func removeWithTheScanFingerprintSucceeds() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: layout.daemons)
            let scanned = try JSONEncoder().encode(FileFingerprint(status: try Self.linkStatus(plist)))
            let (backup, _, error) = await remove(plist.path, expecting: scanned, on: service(Self.daemonNotLoaded, layout: layout))
            #expect(error == nil && backup != nil)
            #expect(!FileManager.default.fileExists(atPath: plist.path))
        }
    }

    // MARK: - Entladen und Entfernen in einem Ablauf (#166)

    /// Ein aus genau dieser Plist geladener Daemon wird nach der Abfrage pfadgebunden entladen, dann gesichert gelöscht.
    @Test func unloadAndRemoveBootsOutADaemonLoadedFromThePlist() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: layout.daemons)
            let canonical = plist.resolvingSymlinksInPath().path
            let scanned = try JSONEncoder().encode(FileFingerprint(status: try Self.linkStatus(plist)))
            let runner = MockCommandRunner([
                Self.probe("com.example.daemon"): Self.loaded(from: canonical), "/bin/launchctl bootout system \(canonical)": Self.ok,
            ])
            let (backup, unloaded, error) = await remove(plist.path, expecting: scanned, on: service(runner, layout: layout))
            #expect(error == nil && backup != nil && unloaded)
            #expect(runner.calls == [Self.probe("com.example.daemon"), "/bin/launchctl bootout system \(canonical)"])
            #expect(!FileManager.default.fileExists(atPath: plist.path))
        }
    }

    /// #166: Ersetzt ein Updater die Plist, während der Helper launchd fragt, lehnt er vor dem `bootout` ab – der Dienst
    /// bleibt geladen, nichts wird gesichert oder gelöscht.
    @Test func daemonReplacedWhileProbingIsRefusedBeforeBootout() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: layout.daemons)
            let canonical = plist.resolvingSymlinksInPath().path
            let scanned = try JSONEncoder().encode(FileFingerprint(status: try Self.linkStatus(plist)))
            let launchctl = MockCommandRunner([
                Self.probe("com.example.daemon"): Self.loaded(from: canonical), "/bin/launchctl bootout system \(canonical)": Self.ok,
            ])
            let runner = SideEffectCommandRunner(launchctl, on: Self.probe("com.example.daemon")) {
                try Self.replace(plist, payload: ["Label": "com.example.daemon", "New": true])
            }

            let (backup, unloaded, error) = await remove(plist.path, expecting: scanned, on: service(runner, layout: layout))
            #expect(backup == nil && !unloaded)
            #expect(error == BackupError.changedSinceScan(canonical).errorDescription)
            #expect(launchctl.calls == [Self.probe("com.example.daemon")])
            #expect(try Self.isReplacement(plist))
            #expect(Self.backupFiles(in: layout).isEmpty)
        }
    }

    /// #166: Fällt die Abweichung erst nach dem `bootout` auf, lädt der Helper **keine** Ersatzkonfiguration – weder mit
    /// gleichem Label und anderem Inhalt noch mit fremdem oder fehlendem Label. Nichts gelöscht, kein `bootstrap`, die
    /// Sicherung bleibt als Beleg; die Meldung sagt, dass der Dienst gestoppt bleibt.
    @Test(arguments: ["com.example.daemon", "com.example.other", nil] as [String?])
    func daemonReplacedDuringBootoutIsNotReloaded(replacementLabel: String?) async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: layout.daemons)
            let canonical = plist.resolvingSymlinksInPath().path
            let original = try Data(contentsOf: plist)
            let (launchctl, runner) = Self.unloading(plist, canonical: canonical, duringBootout: {
                try Self.replace(plist, payload: replacementLabel.map { ["Label": $0, "New": true] } ?? ["New": true])
            })

            let (backup, unloaded, error) = await remove(plist.path, on: service(runner, layout: layout))
            #expect(backup == nil && !unloaded)
            #expect(error == Self.removalFailure(canonical, reloadFailure: ServiceReloadError.plistReplaced.readableDescription))
            #expect(launchctl.calls == [Self.probe("com.example.daemon"), "/bin/launchctl bootout system \(canonical)"])
            #expect(try Self.isReplacement(plist))
            #expect(try Self.backupFiles(in: layout).map { try Data(contentsOf: $0) } == [original])
        }
    }

    /// #166: Lässt sich die Plist nach dem `bootout` nicht löschen, liegen dort aber noch genau die gesicherten Bytes
    /// (hier: neu geschrieben, gleiche Bytes, andere Inode), lädt der Helper den Daemon wieder – bestätigt durch eine
    /// erneute Abfrage.
    @Test func daemonWithUnchangedBytesIsReloadedAfterFailedRemoval() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: layout.daemons)
            let canonical = plist.resolvingSymlinksInPath().path
            let (launchctl, runner) = Self.unloading(plist, canonical: canonical, duringBootout: { try Self.rewriteIdentically(plist) })

            let (backup, unloaded, error) = await remove(plist.path, on: service(runner, layout: layout))
            #expect(backup == nil && !unloaded)
            #expect(error == Self.removalFailure(canonical, reloadFailure: nil))
            #expect(launchctl.calls == Self.bootoutAndReload(canonical) + [Self.probe("com.example.daemon")])
            #expect(FileManager.default.fileExists(atPath: plist.path))
        }
    }

    /// #166, Codex-Runde 5: Wird die Plist während der Rollback-Abfrage ersetzt, lädt der Helper nichts – die Bytes werden
    /// unmittelbar vor dem `bootstrap` erneut geprüft.
    @Test func daemonReplacedDuringTheRollbackQueryIsNotLoaded() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: layout.daemons)
            let canonical = plist.resolvingSymlinksInPath().path
            let (launchctl, runner) = Self.unloading(
                plist, canonical: canonical,
                duringBootout: { try Self.rewriteIdentically(plist) },
                duringRollbackQuery: { try Self.replace(plist, payload: ["Label": "com.example.other", "New": true]) }
            )

            let (_, _, error) = await remove(plist.path, on: service(runner, layout: layout))
            #expect(error == Self.removalFailure(canonical, reloadFailure: ServiceReloadError.plistReplaced.readableDescription))
            #expect(launchctl.calls == [
                Self.probe("com.example.daemon"), "/bin/launchctl bootout system \(canonical)", Self.probe("com.example.daemon"),
            ])
        }
    }

    /// #166: Scheitert das erneute Laden – oder bestätigt launchd es danach nicht –, meldet der Helper, dass der Dienst
    /// gestoppt bleibt.
    @Test(arguments: [true, false])
    func failedReloadAfterBootoutIsReported(bootstrapFails: Bool) async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: layout.daemons)
            let canonical = plist.resolvingSymlinksInPath().path
            let bootstrap = "/bin/launchctl bootstrap system \(canonical)"
            let (launchctl, runner) = Self.unloading(
                plist, canonical: canonical, duringBootout: { try Self.rewriteIdentically(plist) }, confirmed: false
            )
            if bootstrapFails { launchctl.stub(bootstrap, CommandResult(exitCode: 5, stdout: "", stderr: "Input/output error")) }

            let (_, _, error) = await remove(plist.path, on: service(runner, layout: layout))
            #expect(error == Self.removalFailure(canonical, reloadFailure: bootstrapFails
                ? "launchctl bootstrap system \(canonical) fehlgeschlagen (Exit 5): Input/output error"
                : ServiceReloadError.notReloaded("com.example.daemon").readableDescription))
            #expect(launchctl.calls == Self.bootoutAndReload(canonical) + (bootstrapFails ? [] : [Self.probe("com.example.daemon")]))
        }
    }

    /// Meldung des Helpers, wenn `canonical` nach dem `bootout` nicht gelöscht wurde (Löschen scheitert, weil die Datei
    /// nicht mehr das gesicherte Dateiobjekt ist).
    private static func removalFailure(_ canonical: String, reloadFailure: String?) -> String? {
        UnloadedRemovalFailure(
            path: canonical, reason: BackupError.sourceChanged(canonical).readableDescription, reloadFailure: reloadFailure
        ).errorDescription
    }

    /// Abfrage, `bootout`, erneute Abfrage und `bootstrap` für `com.example.daemon`.
    private static func bootoutAndReload(_ canonical: String) -> [String] {
        [
            probe("com.example.daemon"), "/bin/launchctl bootout system \(canonical)",
            probe("com.example.daemon"), "/bin/launchctl bootstrap system \(canonical)",
        ]
    }

    /// Ein aus einer anderen Plist geladener Dienst (#99) wird nicht entladen; gelöscht wird nur die Datei.
    @Test func unloadAndRemoveLeavesAServiceLoadedFromElsewhere() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: layout.daemons)
            let runner = MockCommandRunner([Self.probe("com.example.daemon"): Self.loaded(from: "/System/Library/LaunchDaemons/x.plist")])
            let (backup, unloaded, error) = await remove(plist.path, on: service(runner, layout: layout))
            #expect(error == nil && backup != nil && !unloaded)
            #expect(runner.calls == [Self.probe("com.example.daemon")])
            #expect(!FileManager.default.fileExists(atPath: plist.path))
        }
    }

    /// Plists in `LaunchAgents` sichert und löscht der Helper nur; launchd fragt er dafür nicht (Domain `gui/<uid>`).
    @Test func unloadAndRemoveOnlyDeletesSystemAgents() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: layout.agents)
            let runner = MockCommandRunner()
            let (backup, unloaded, error) = await remove(plist.path, on: service(runner, layout: layout))
            #expect(error == nil && backup != nil && !unloaded)
            #expect(runner.calls.isEmpty)
        }
    }

    /// launchctl für `com.example.daemon`, geladen aus `canonical`: Während des `bootout` läuft `duringBootout`, danach
    /// meldet launchd den Dienst als nicht geladen; während der Rollback-Abfrage läuft `duringRollbackQuery`; nach dem
    /// `bootstrap` meldet launchd ihn wieder aus `canonical` geladen, sofern `confirmed`. Liefert den protokollierenden
    /// Mock und den Runner mit Effekten.
    private static func unloading(
        _ plist: URL, canonical: String,
        duringBootout: @escaping SideEffectCommandRunner.Effect,
        duringRollbackQuery: @escaping SideEffectCommandRunner.Effect = {},
        confirmed: Bool = true
    ) -> (launchctl: MockCommandRunner, runner: SideEffectCommandRunner) {
        let probe = probe("com.example.daemon")
        let bootout = "/bin/launchctl bootout system \(canonical)"
        let bootstrap = "/bin/launchctl bootstrap system \(canonical)"
        let launchctl = MockCommandRunner([probe: loaded(from: canonical), bootout: ok, bootstrap: ok])
        let script: [(commandLine: String, effect: SideEffectCommandRunner.Effect)] = [
            (probe, {}),
            (bootout, {
                try duringBootout()
                launchctl.stub(probe, notLoaded)
            }),
            (probe, duringRollbackQuery),
            (bootstrap, { if confirmed { launchctl.stub(probe, loaded(from: canonical)) } }),
        ]
        let runner = SideEffectCommandRunner(launchctl, script: script)
        return (launchctl, runner)
    }

    /// Schreibt `plist` mit denselben Bytes neu (andere Inode): Das Löschen lehnt ab, der Inhalt ist unverändert.
    private static func rewriteIdentically(_ plist: URL) throws {
        let data = try Data(contentsOf: plist)
        try FileManager.default.removeItem(at: plist)
        try data.write(to: plist)
    }

    /// Ersetzt `plist` durch eine neue Datei (andere Inode) mit `payload`.
    private static func replace(_ plist: URL, payload: [String: Any]) throws {
        try FileManager.default.removeItem(at: plist)
        try LaunchdPlistFixture.write(payload: payload, named: plist.lastPathComponent, in: plist.deletingLastPathComponent())
    }

    /// Ob unter `plist` die Ersatzdatei (`New: true`) liegt.
    private static func isReplacement(_ plist: URL) throws -> Bool {
        let current = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
        return current?["New"] as? Bool == true
    }

    /// Alle Plist-Sicherungen im Backup-Speicher von `layout`.
    private static func backupFiles(in layout: Layout) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: layout.backups, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "plist" }
    }

    /// Ein nicht lesbarer Fingerabdruck wird abgelehnt, bevor etwas gesichert oder gelöscht wird.
    @Test func removeRejectsAnUndecodableFingerprint() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: layout.daemons)
            let (backup, _, error) = await remove(plist.path, expecting: Data("{".utf8), on: service(MockCommandRunner(), layout: layout))
            #expect(backup == nil)
            #expect(error == PolicyViolation.invalidFingerprint.errorDescription)
            #expect(FileManager.default.fileExists(atPath: plist.path))
            #expect(!FileManager.default.fileExists(atPath: layout.backups.path))
        }
    }

    /// `lstat` von `url`.
    private static func linkStatus(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
        return info
    }

    @Test func removeRejectsUnmanagedPath() async {
        let (backup, _, error) = await remove("/etc/hosts", on: service(MockCommandRunner()))
        #expect(backup == nil)
        #expect(error != nil)
    }

    @Test func removeRejectsAppleLabelAndKeepsFile() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.apple.x", named: "vendor.plist", in: layout.agents)
            let (backup, _, error) = await remove(plist.path, on: service(MockCommandRunner(), layout: layout))
            #expect(backup == nil)
            #expect(error?.contains("Apple") == true)
            #expect(FileManager.default.fileExists(atPath: plist.path))
            #expect(!FileManager.default.fileExists(atPath: layout.backups.path))
        }
    }

    /// #101: Ein gruppenbeschreibbarer Backup-Root macht jedes Backup unwiederherstellbar – der Helper legt dann
    /// keines an und löscht nichts.
    @Test func removeKeepsPlistWhenBackupRootIsUntrusted() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: layout.daemons)
            try FileManager.default.createDirectory(at: layout.backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o770])
            let (backup, _, error) = await remove(plist.path, on: service(Self.daemonNotLoaded, layout: layout))
            #expect(backup == nil)
            #expect(error?.contains("vertrauenswürdig") == true)
            #expect(FileManager.default.fileExists(atPath: plist.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: layout.backups.path).isEmpty)
        }
    }

    @Test func bootstrapRejectsSymlinkedPlist() async throws {
        try await withLayout { layout in
            let target = try LaunchdPlistFixture.write(label: "com.example.daemon", in: layout.agents)
            let link = layout.daemons.appending(path: "com.example.daemon.plist")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let runner = MockCommandRunner()
            let error = await await1 { reply in service(runner, layout: layout).bootstrap(plistPath: link.path, reply: reply) }
            #expect(error != nil)
            #expect(runner.calls.isEmpty)
        }
    }

    @Test func restoreFailsWhenDestinationExists() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: layout.daemons)
            let sut = service(Self.daemonNotLoaded, layout: layout)
            let (backup, _, _) = await remove(plist.path, on: sut)
            try LaunchdPlistFixture.write(label: "com.example.daemon", payload: ["Label": "com.example.daemon", "New": true], in: layout.daemons)

            let (restored, error) = await await1 { reply in sut.restorePlist(backupPath: backup ?? "") { reply(($0, $1)) } }
            #expect(restored == nil)
            #expect(error?.contains("existiert bereits") == true)
            let current = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
            #expect(current?["New"] as? Bool == true)
        }
    }

    /// Ruft die XPC-Methode zu `operation` auf.
    private func harden(_ operation: SecurityHardening, on service: HelperService) async -> String? {
        await await1 { reply in
            switch operation {
            case .enableFirewall: service.enableFirewall(reply: reply)
            case .enableStealthMode: service.enableStealthMode(reply: reply)
            case .enableGatekeeper: service.enableGatekeeper(reply: reply)
            case .enableAutomaticUpdates: service.enableAutomaticUpdates(reply: reply)
            case .updateXProtect: service.updateXProtect(reply: reply)
            }
        }
    }

    @Test(arguments: SecurityHardening.allCases)
    func hardeningRunsExactlyTheFixedCommands(_ operation: SecurityHardening) async {
        let runner = SecurityHardeningStubs.runnerRequiringAction(for: operation)
        let error = await harden(operation, on: service(runner))
        #expect(error == nil)
        #expect(runner.calls == SecurityHardeningStubs.commandLinesRequiringAction(for: operation))
    }

    private static let getGlobalState = "/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate"
    private static let getStealthMode = "/usr/libexec/ApplicationFirewall/socketfilterfw --getstealthmode"
    private static let gatekeeperStatus = "/usr/sbin/spctl --status"

    /// „Alle eingehenden blockieren“ – als `State = 2` (Fixture) oder als eigener Block-all-Zustand neben `State = 1`.
    @Test(arguments: [
        try SecurityHardeningStubs.fixture("socketfilterfw-block-all.txt"),
        "Firewall is enabled. (State = 1)\nFirewall has block all state set to enabled.\n",
        try SecurityHardeningStubs.fixture("socketfilterfw-on-stealth-off.txt"),
    ])
    func enablingFirewallNeverTouchesAnEnabledFirewall(_ state: String) async {
        let runner = MockCommandRunner([Self.getGlobalState: CommandResult(exitCode: 0, stdout: state)])
        let error = await harden(.enableFirewall, on: service(runner))
        #expect(error == nil)
        #expect(runner.calls == [Self.getGlobalState])
    }

    @Test func enablingFirewallSetsItOnlyWhenOff() async throws {
        let runner = MockCommandRunner([
            Self.getGlobalState: CommandResult(exitCode: 0, stdout: try SecurityHardeningStubs.fixture("socketfilterfw-off.txt")),
            "/usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on": CommandResult(exitCode: 0, stdout: ""),
        ])
        let error = await harden(.enableFirewall, on: service(runner))
        #expect(error == nil)
        #expect(runner.calls == [Self.getGlobalState, "/usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on"])
    }

    @Test func enablingStealthModeSkipsWhenAlreadyOn() async throws {
        let runner = MockCommandRunner([
            Self.getStealthMode: CommandResult(exitCode: 0, stdout: try SecurityHardeningStubs.fixture("socketfilterfw-on-stealth-on.txt")),
        ])
        let error = await harden(.enableStealthMode, on: service(runner))
        #expect(error == nil)
        #expect(runner.calls == [Self.getStealthMode])
    }

    /// Wie bei der Firewall: Ist Gatekeeper schon an, setzt der Helper nichts (Erfolg ohne Aktion).
    @Test func enablingGatekeeperSkipsWhenAlreadyEnabled() async throws {
        let runner = MockCommandRunner([
            Self.gatekeeperStatus: CommandResult(exitCode: 0, stdout: try SecurityHardeningStubs.fixture("spctl-enabled.txt")),
        ])
        let error = await harden(.enableGatekeeper, on: service(runner))
        #expect(error == nil)
        #expect(runner.calls == [Self.gatekeeperStatus])
    }

    /// `spctl --status` meldet „assessments disabled“ mit Exit 1 – genau der Fall, in dem eingeschaltet werden muss.
    @Test func enablingGatekeeperSetsItOnlyWhenDisabled() async throws {
        let status = try SecurityHardeningStubs.fixtureResult("spctl-disabled.txt")
        #expect(status.exitCode == 1)
        let runner = MockCommandRunner([
            Self.gatekeeperStatus: status,
            "/usr/sbin/spctl --global-enable": CommandResult(exitCode: 0, stdout: ""),
        ])
        let error = await harden(.enableGatekeeper, on: service(runner))
        #expect(error == nil)
        #expect(runner.calls == [Self.gatekeeperStatus, "/usr/sbin/spctl --global-enable"])
    }

    /// Unbekannte Ausgabe (etwa nach einem macOS-Update): lieber abbrechen als blind setzen.
    @Test(arguments: [
        (SecurityHardening.enableFirewall, getGlobalState), (.enableStealthMode, getStealthMode),
        (.enableGatekeeper, gatekeeperStatus),
    ])
    func unrecognizedStateAbortsWithoutSetting(_ operation: SecurityHardening, query: String) async {
        let runner = MockCommandRunner([query: CommandResult(exitCode: 0, stdout: "Something new\n")])
        let error = await harden(operation, on: service(runner))
        #expect(error?.contains("Something new") == true)
        #expect(runner.calls == [query])
    }

    /// Exit ≠ 0 ohne erkennbaren Zustand: abbrechen, mit Exit-Code und stderr.
    @Test(arguments: [
        (SecurityHardening.enableFirewall, getGlobalState), (.enableStealthMode, getStealthMode),
        (.enableGatekeeper, gatekeeperStatus),
    ])
    func unrecognizedStateWithNonZeroExitAbortsWithoutSetting(_ operation: SecurityHardening, query: String) async {
        let runner = MockCommandRunner([query: CommandResult(exitCode: 1, stdout: "Something new\n", stderr: "boom")])
        let error = await harden(operation, on: service(runner))
        #expect(error?.contains("Exit 1") == true)
        #expect(error?.contains("boom") == true)
        #expect(runner.calls == [query])
    }

    /// Exit ≠ 0 gilt nur für „Ziel nicht erreicht“ als gültiger Zustand (`spctl` meldet „aus“ so). Meldet die Abfrage
    /// „an“ und scheitert dabei, ist der Zustand zweifelhaft: abbrechen statt „bereits erreicht“ zu melden.
    @Test(arguments: [
        (SecurityHardening.enableFirewall, getGlobalState, "socketfilterfw-on-stealth-off.txt"),
        (.enableStealthMode, getStealthMode, "socketfilterfw-on-stealth-on.txt"),
        (.enableGatekeeper, gatekeeperStatus, "spctl-enabled.txt"),
    ])
    func reachedStateWithNonZeroExitAborts(_ operation: SecurityHardening, query: String, fixture: String) async throws {
        let output = try SecurityHardeningStubs.fixture(fixture)
        let runner = MockCommandRunner([query: CommandResult(exitCode: 1, stdout: output, stderr: "boom")])
        let error = await harden(operation, on: service(runner))
        #expect(error?.contains("Exit 1") == true)
        #expect(error?.contains("boom") == true)
        #expect(runner.calls == [query])
    }

    @Test func failingStateQueryAbortsWithoutSetting() async {
        let runner = MockCommandRunner([Self.getGlobalState: CommandResult(exitCode: 1, stdout: "", stderr: "denied")])
        let error = await harden(.enableFirewall, on: service(runner))
        #expect(error?.contains("denied") == true)
        #expect(runner.calls == [Self.getGlobalState])
    }

    @Test func longStderrIsShortenedInTheError() async {
        let line = SecurityHardening.enableGatekeeper.invocations[0].commandLine
        let runner = MockCommandRunner([
            Self.gatekeeperStatus: CommandResult(exitCode: 0, stdout: "assessments disabled\n"),
            line: CommandResult(exitCode: 1, stdout: "", stderr: String(repeating: "x", count: 5_000)),
        ])
        let error = await harden(.enableGatekeeper, on: service(runner))
        #expect((error?.count ?? 0) < 1_200)
        #expect(error?.hasSuffix("…") == true)
    }

    @Test func hardeningStopsAtFirstFailureAndReportsStderr() async {
        let first = SecurityHardening.enableAutomaticUpdates.invocations[0].commandLine
        let runner = MockCommandRunner([first: CommandResult(exitCode: 1, stdout: "", stderr: "Permission denied")])
        let error = await harden(.enableAutomaticUpdates, on: service(runner))
        #expect(error?.contains("Permission denied") == true)
        #expect(error?.contains("Exit 1") == true)
        #expect(runner.calls == [first])
    }

    @Test func hardeningStopsAfterFailingMiddleCommand() async {
        let lines = SecurityHardening.enableAutomaticUpdates.invocations.map(\.commandLine)
        let runner = MockCommandRunner([
            lines[0]: CommandResult(exitCode: 0, stdout: ""),
            lines[1]: CommandResult(exitCode: 4, stdout: "", stderr: "Could not write domain"),
        ])
        let error = await harden(.enableAutomaticUpdates, on: service(runner))
        #expect(error?.contains("Could not write domain") == true)
        #expect(runner.calls == Array(lines.prefix(2)))
    }

    @Test func hardeningPassesOperationTimeoutToRunner() async {
        let runner = ConcurrencyProbeRunner()
        let sut = HelperService(runner: runner)
        _ = await harden(.updateXProtect, on: sut)
        _ = await harden(.enableFirewall, on: sut)
        #expect(runner.timeouts == [.seconds(120), .seconds(30), .seconds(30)])  // Firewall: Abfrage + Setzen
    }

    /// Die Abfrage hat eine kurze, der Befehl die normale launchctl-Frist; `HelperClient.callTimeout` liegt darüber.
    @Test func launchctlProbeAndCommandUseTheirTimeouts() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: layout.daemons)
            let runner = ConcurrencyProbeRunner(loadedPlistPath: plist.resolvingSymlinksInPath().path)
            _ = await await1 { reply in service(runner, layout: layout).bootout(plistPath: plist.path, reply: reply) }
            #expect(runner.timeouts == [HelperService.probeTimeout, HelperService.launchctlTimeout])
            #expect(runner.timeouts == [.seconds(10), .seconds(30)])
        }
    }

    @Test func serializesHardeningWithOtherOperations() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: layout.daemons)
            let runner = ConcurrencyProbeRunner(loadedPlistPath: plist.resolvingSymlinksInPath().path)
            let sut = service(runner, layout: layout)
            let errors = await withTaskGroup(of: String?.self) { group in
                for operation in SecurityHardening.allCases {
                    group.addTask { await self.harden(operation, on: sut) }
                    group.addTask { await self.await1 { reply in sut.bootout(plistPath: plist.path, reply: reply) } }
                }
                return await group.reduce(into: [String?]()) { $0.append($1) }
            }
            #expect(errors.allSatisfy { $0 == nil })
            #expect(runner.maxConcurrent == 1)
            let hardeningCalls = SecurityHardening.allCases.map { SecurityHardeningStubs.commandLinesRequiringAction(for: $0).count }
            // Je `bootout`: Ladezustandsprüfung + Befehl.
            #expect(runner.callCount == hardeningCalls.reduce(0, +) + 2 * SecurityHardening.allCases.count)
        }
    }

    @Test func serializesConcurrentLaunchctlOperations() async throws {
        try await withLayout { layout in
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: layout.daemons)
            let runner = ConcurrencyProbeRunner(loadedPlistPath: plist.resolvingSymlinksInPath().path)
            let sut = service(runner, layout: layout)
            let errors = await withTaskGroup(of: String?.self) { group in
                for index in 0..<8 {
                    group.addTask {
                        await self.await1 { reply in
                            if index.isMultiple(of: 2) {
                                sut.bootout(plistPath: plist.path, reply: reply)
                            } else {
                                sut.setEnabled(plistPath: plist.path, enabled: false, reply: reply)
                            }
                        }
                    }
                }
                return await group.reduce(into: [String?]()) { $0.append($1) }
            }
            #expect(errors.count == 8)
            #expect(errors.allSatisfy { $0 == nil })
            #expect(runner.maxConcurrent == 1)
            #expect(runner.callCount == 16)  // je Operation: Ladezustandsprüfung + Befehl
        }
    }

    // MARK: Prozess beenden (Protokoll 4)

    private static let listenerProcess = RunningProcess(pid: 4242, uid: 0, executablePath: "/usr/local/sbin/listener", startTime: 1)

    private func terminationService(
        _ processes: [RunningProcess] = [HelperServiceTests.listenerProcess], signature: AppleSignatureVerdict = .notApple,
        listening: Set<pid_t> = [4242], signaler: any ProcessSignaling, runner: any CommandRunning = MockCommandRunner(),
        clock: TestClock = TestClock(), inspector: (any ProcessInspecting)? = nil
    ) -> HelperService {
        HelperService(
            runner: runner,
            terminationPolicy: ProcessTerminationPolicy(
                inspector: inspector ?? FixedProcessInspector(processes), appleSignature: FixedAppleSignature(signature),
                listening: ListeningRequirement(checker: FixedListeningPIDs(listening)),
                ownPID: 555, protectedBundlePaths: ["/Applications/Grantry.app"]
            ),
            processSignaler: signaler,
            callerPID: { 777 },
            clock: clock
        )
    }

    private func terminate(_ sut: HelperService, pid: Int32 = 4242, path: String = "/usr/local/sbin/listener",
                           startTime: UInt64 = 1, force: Bool = false) async -> String? {
        await await1 { reply in
            sut.terminateProcess(pid: pid, executablePath: path, startTime: startTime, force: force, reply: reply)
        }
    }

    @Test func terminateProcessSendsSIGTERMOrSIGKILL() async {
        let signaler = RecordingSignaler()
        let sut = terminationService(signaler: signaler)
        #expect(await terminate(sut) == nil)
        #expect(await terminate(sut, force: true) == nil)
        #expect(signaler.sent == [.init(signal: .terminate, pid: 4242), .init(signal: .kill, pid: 4242)])
    }

    @Test func endedProcessIsSuccessWithoutSignal() async {
        let signaler = RecordingSignaler()
        #expect(await terminate(terminationService([], signaler: signaler)) == nil)
        #expect(signaler.sent.isEmpty)
    }

    /// Prüfungen 1–3 der Spec (§5): geschützte PIDs, Grantry-Bundle, geänderter Pfad oder geänderte Startzeit
    /// (PID-Wiederverwendung), Apple bzw. unbekannte Signatur.
    @Test func rejectsWithoutSignal() async {
        let signaler = RecordingSignaler()
        let helper = RunningProcess(
            pid: 600, uid: 0, executablePath: "/Applications/Grantry.app/Contents/MacOS/GrantryHelper", startTime: 1
        )
        let sut = terminationService([Self.listenerProcess, helper], signaler: signaler)
        let rejections = [
            await terminate(sut, pid: 1), await terminate(sut, pid: 555), await terminate(sut, pid: 777),
            await terminate(sut, pid: 600, path: helper.executablePath),
            await terminate(sut, path: "/usr/local/sbin/other"), await terminate(sut, startTime: 2),
            await terminate(terminationService(signature: .apple, signaler: signaler)),
            await terminate(terminationService(signature: .unknown, signaler: signaler)),
        ]
        #expect(rejections == [
            "Prozess 1 ist geschützt und wird nicht beendet", "Prozess 555 ist geschützt und wird nicht beendet",
            "Prozess 777 ist geschützt und wird nicht beendet", "Grantry beendet sich nicht selbst: GrantryHelper",
            "Prozess 4242 hat sich geändert – Aktion abgebrochen", "Prozess 4242 hat sich geändert – Aktion abgebrochen",
            "Apple-Programme beendet der Helper nicht: listener",
            "Signatur von listener nicht prüfbar – etwa weil das Programm seit dem Start aktualisiert wurde. Nach einem Neustart des Dienstes erneut versuchen.",
        ])
        #expect(signaler.sent.isEmpty)
    }

    /// Der Helper beendet nur Prozesse, die gerade lauschen – auch mit `force` (ein kompromittierter Client soll keine
    /// beliebigen Nicht-Apple-Prozesse beenden können).
    @Test(arguments: [false, true])
    func processWithoutListenerIsRejected(force: Bool) async {
        let signaler = RecordingSignaler()
        let sut = terminationService(listening: [], signaler: signaler)
        #expect(await terminate(sut, force: force)
            == "listener lauscht nicht im Netzwerk – Grantry beendet nur Prozesse lauschender Dienste")
        #expect(signaler.sent.isEmpty)
    }

    /// Die Aufrufer-PID wird synchron beim Eingang des Aufrufs gelesen, nicht erst in der eingereihten Operation –
    /// `NSXPCConnection.current()` ist nur dort gültig.
    @Test func callerPIDIsReadSynchronouslyAtTheCall() async {
        let signaler = RecordingSignaler()
        let reads = Mutex(0)
        let sut = HelperService(
            runner: MockCommandRunner(),
            terminationPolicy: ProcessTerminationPolicy(
                inspector: FixedProcessInspector([Self.listenerProcess]), appleSignature: FixedAppleSignature(.notApple),
                ownPID: 555, protectedBundlePaths: []
            ),
            processSignaler: signaler,
            callerPID: { reads.withLock { $0 += 1 }; return 4242 }
        )
        let error = await await1 { reply in
            sut.terminateProcess(pid: 4242, executablePath: "/usr/local/sbin/listener", startTime: 1, force: false, reply: reply)
            #expect(reads.withLock { $0 } == 1)
        }
        #expect(error == "Prozess 4242 ist geschützt und wird nicht beendet")
        #expect(signaler.sent.isEmpty)
    }

    @Test func signalErrorIsReported() async {
        struct DeniedSignaler: ProcessSignaling {
            func send(_ signal: TerminationSignal, to process: RunningProcess) throws(ProcessTerminationViolation) -> SignalDelivery {
                throw .notPermitted(process.pid)
            }
        }
        let sut = HelperService(
            runner: MockCommandRunner(),
            terminationPolicy: ProcessTerminationPolicy(
                inspector: FixedProcessInspector([Self.listenerProcess]), appleSignature: FixedAppleSignature(.notApple),
                ownPID: 555, protectedBundlePaths: []
            ),
            processSignaler: DeniedSignaler(), callerPID: { 777 }
        )
        #expect(await terminate(sut) == "Keine Berechtigung, Prozess 4242 zu beenden")
    }

    /// Fail-closed: Ohne feststellbaren Aufrufer (`NSXPCConnection.current()` liefert `nil`) kein Signal.
    @Test func unknownCallerIsRejected() async {
        let signaler = RecordingSignaler()
        let sut = HelperService(
            runner: MockCommandRunner(),
            terminationPolicy: ProcessTerminationPolicy(
                inspector: FixedProcessInspector([Self.listenerProcess]), appleSignature: FixedAppleSignature(.notApple),
                ownPID: 555, protectedBundlePaths: []
            ),
            processSignaler: signaler, callerPID: { nil }
        )
        #expect(await terminate(sut) == "Aufrufer nicht feststellbar – Aktion abgebrochen")
        #expect(signaler.sent.isEmpty)
    }

    /// Die Meldung nennt das Programm laut Inspektor, nicht den vom Aufrufer übergebenen Pfadtext.
    @Test func rejectionNamesTheInspectedProgram() async {
        let signaler = RecordingSignaler()
        let sut = terminationService(signature: .apple, signaler: signaler)
        #expect(await terminate(sut, path: "/usr/local/sbin/listener/.") == "Apple-Programme beendet der Helper nicht: listener")
        #expect(signaler.sent.isEmpty)
    }

    /// Reiht den Auftrag **sofort** ein (synchron, in Aufrufreihenfolge); die Antwort kommt über die Rückgabe.
    private func startTermination(_ sut: HelperService, force: Bool = false) -> @Sendable () async -> String? {
        let (replies, continuation) = AsyncStream<String?>.makeStream()
        sut.terminateProcess(pid: 4242, executablePath: "/usr/local/sbin/listener", startTime: 1, force: force) {
            continuation.yield($0)
            continuation.finish()
        }
        return {
            var iterator = replies.makeAsyncIterator()
            return await iterator.next() ?? nil
        }
    }

    /// Signalgeber, dessen **erstes** Signal anhält, bis die per `whenHeld` übergebene Aktion gelaufen ist. Alle Signale
    /// werden protokolliert.
    private final class GatedSignaler: ProcessSignaling {
        let recording = RecordingSignaler()
        private let entered = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private let held = Mutex(false)

        /// Führt `action` aus, sobald das erste Signal anhält, und gibt es danach frei. Beides läuft auf einem eigenen
        /// Thread: Das angehaltene Signal belegt einen Thread des kooperativen Pools – bei wenigen Kernen womöglich den
        /// letzten freien.
        func whenHeld(_ action: @escaping @Sendable () -> Void) {
            Thread.detachNewThread { [entered, release] in
                entered.wait()
                action()
                release.signal()
            }
        }

        func send(_ signal: TerminationSignal, to process: RunningProcess) throws(ProcessTerminationViolation) -> SignalDelivery {
            let first = held.withLock { held in
                defer { held = true }
                return !held
            }
            if first {
                entered.signal()
                release.wait()  // synchron: die Warteschlange ist nicht reentrant
            }
            return try recording.send(signal, to: process)
        }
    }

    /// #153, Befund 4: Ein Auftrag, der länger als `terminationRequestLifetime` gewartet hat – der Client kann ihn
    /// längst als gescheitert gemeldet haben –, bekommt kein Signal mehr.
    @Test(.timeLimit(.minutes(1))) func expiredRequestIsRejectedWithoutSignal() async throws {
        let clock = TestClock()
        let signaler = GatedSignaler()
        let sut = terminationService(signaler: signaler, clock: clock)
        let first = startTermination(sut)
        let second = startTermination(sut, force: true)
        signaler.whenHeld { clock.advance(by: HelperService.terminationRequestLifetime + .seconds(1)) }  // erst nach beiden Aufträgen: ihre Frist läuft ab Aufruf
        #expect(await first() == nil)
        #expect(await second() == "Auftrag für Prozess 4242 abgelaufen – kein Signal gesendet")
        #expect(signaler.recording.sent == [.init(signal: .terminate, pid: 4242)])
    }

    /// Innerhalb der Frist läuft der Auftrag – auch nach Wartezeit.
    @Test(.timeLimit(.minutes(1))) func requestWithinLifetimeIsSignalled() async throws {
        let clock = TestClock()
        let signaler = GatedSignaler()
        let sut = terminationService(signaler: signaler, clock: clock)
        let first = startTermination(sut)
        let second = startTermination(sut, force: true)
        signaler.whenHeld { clock.advance(by: HelperService.terminationRequestLifetime) }  // erst nach beiden Aufträgen: ihre Frist läuft ab Aufruf
        #expect(await first() == nil)
        #expect(await second() == nil)
        #expect(signaler.recording.sent == [.init(signal: .terminate, pid: 4242), .init(signal: .kill, pid: 4242)])
    }

    /// Inspektor, der beim ersten Lesen die Uhr vorstellt – bildet eine Prüfung nach, die länger als die Frist blockiert
    /// (etwa Pfad- oder Signaturprüfung auf einem gestörten Volume).
    private final class ClockAdvancingInspector: ProcessInspecting {
        private let base: FixedProcessInspector
        private let clock: TestClock
        private let delay: Duration
        private let advanced = Mutex(false)

        init(_ processes: [RunningProcess], clock: TestClock, delay: Duration) {
            base = FixedProcessInspector(processes)
            self.clock = clock
            self.delay = delay
        }

        func process(_ pid: pid_t) -> RunningProcess? {
            if !advanced.withLock({ advanced in defer { advanced = true }; return advanced }) {
                clock.advance(by: delay)
            }
            return base.process(pid)
        }

        func liveness(of pid: pid_t) -> ProcessLiveness { base.liveness(of: pid) }
    }

    /// Die Frist gilt bis zum Signal, nicht nur bis zur Prüfung: Blockiert die Prüfung selbst länger als die Frist, geht
    /// danach kein Signal mehr (#153, Codex-Nachprüfung).
    @Test func expiryDuringValidationIsRejectedWithoutSignal() async {
        let clock = TestClock()
        let signaler = RecordingSignaler()
        let inspector = ClockAdvancingInspector(
            [Self.listenerProcess], clock: clock, delay: HelperService.terminationRequestLifetime + .seconds(1)
        )
        let sut = terminationService(signaler: signaler, clock: clock, inspector: inspector)
        #expect(await terminate(sut) == "Auftrag für Prozess 4242 abgelaufen – kein Signal gesendet")
        #expect(signaler.sent.isEmpty)
    }

    /// Die Frist liegt deutlich unter der Frist des Clients (`HelperClient.callTimeout`, 60 s).
    @Test func lifetimeIsWellBelowTheClientsTimeout() {
        #expect(HelperService.terminationRequestLifetime == .seconds(10))
    }

    /// Runner, dessen Befehl anhält, bis der Test ihn freigibt; `entered` meldet den Beginn.
    private final class GatedRunner: CommandRunning {
        let entered = Gate()
        let release = Gate()

        func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> CommandResult {
            entered.open()
            try await release.wait()
            return CommandResult(exitCode: 0, stdout: "")
        }
    }

    /// Ein langer Befehl in der allgemeinen Warteschlange (etwa `xprotect update`, 120 s) hält „Prozess beenden“
    /// nicht auf (#153, Befund 4).
    @Test(.timeLimit(.minutes(1))) func terminationIsNotQueuedBehindLongCommands() async throws {
        let runner = GatedRunner()
        let signaler = RecordingSignaler()
        let sut = terminationService(signaler: signaler, runner: runner)
        async let hardening = harden(.updateXProtect, on: sut)
        try await runner.entered.wait()
        #expect(await terminate(sut) == nil)
        #expect(signaler.sent == [.init(signal: .terminate, pid: 4242)])
        runner.release.open()
        #expect(await hardening == nil)
    }
}

/// Runner, dessen Aufrufe sämtlich mit `error` scheitern; protokolliert die Befehlszeilen.
private final class ThrowingRunner: CommandRunning {
    private let error: any Error & Sendable
    private let recorded = Mutex<[String]>([])

    init(error: any Error & Sendable) { self.error = error }

    var calls: [String] { recorded.withLock { $0 } }

    func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> CommandResult {
        recorded.withLock { $0.append(([executable] + arguments).joined(separator: " ")) }
        throw error
    }
}

/// Erfolgreicher Runner, der misst, wie viele Aufrufe gleichzeitig laufen, und die Fristen festhält. Zustandsabfragen
/// melden ausgeschalteten Schutz, damit der Helper jeweils auch setzt; `launchctl print` meldet einen aus
/// `loadedPlistPath` geladenen Dienst, damit launchctl-Operationen ebenfalls bis zum Befehl kommen.
private final class ConcurrencyProbeRunner: CommandRunning {
    private let state = Mutex((running: 0, maxConcurrent: 0, calls: 0, timeouts: [Duration]()))
    private let loadedPlistPath: String?

    init(loadedPlistPath: String? = nil) {
        self.loadedPlistPath = loadedPlistPath
    }

    var maxConcurrent: Int { state.withLock { $0.maxConcurrent } }
    var callCount: Int { state.withLock { $0.calls } }
    var timeouts: [Duration] { state.withLock { $0.timeouts } }

    func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> CommandResult {
        state.withLock { state in
            state.running += 1
            state.calls += 1
            state.timeouts.append(timeout)
            state.maxConcurrent = max(state.maxConcurrent, state.running)
        }
        try await Task.sleep(for: .milliseconds(10))
        state.withLock { $0.running -= 1 }
        if executable == HelperService.launchctl, arguments.first == "print", let loadedPlistPath {
            return CommandResult(exitCode: 0, stdout: "\tpath = \(loadedPlistPath)\n")
        }
        return SecurityHardening.allCases
            .first { $0.stateQuery?.invocation.executable == executable && $0.stateQuery?.invocation.arguments == arguments }
            .flatMap(SecurityHardeningStubs.resultRequiringAction(for:)) ?? CommandResult(exitCode: 0, stdout: "")
    }
}
