import Foundation
import Synchronization
import Testing
@testable import ManagerKit
import TestSupport

@Suite struct LaunchdSourceTests {
    /// Legt ein Verzeichnis mit den Plists `plists` und den Rohdateien `rawFiles` an und übergibt seinen Pfad an `body`.
    private func withDirectory<T>(
        _ plists: [String: [String: Any]], rawFiles: [String: String] = [:], _ body: (String) async throws -> T
    ) async throws -> T {
        try await ScratchDirectory.with(prefix: "launchd") { directory in
            for (name, dictionary) in plists {
                let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
                try data.write(to: directory.appending(path: name))
            }
            for (name, text) in rawFiles {
                try text.write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
            }
            return try await body(directory.path)
        }
    }

    /// Gültige Ausgaben ohne Overrides bzw. geladene Dienste.
    private static let emptyDisabled = CommandResult(exitCode: 0, stdout: "\n\tdisabled services = {\n\t}\n")
    private static let emptyPrint = CommandResult(exitCode: 0, stdout: "gui/501 = {\n\tservices = {\n\t}\n}\n")

    /// Runner, der für alle Domains in `domains` gültige Ausgaben ohne Einträge liefert.
    private func succeedingRunner(domains: [String] = ["gui/501"]) -> MockCommandRunner {
        let runner = MockCommandRunner()
        for domain in domains {
            runner.stub("/bin/launchctl print-disabled \(domain)", Self.emptyDisabled)
            runner.stub("/bin/launchctl print \(domain)", Self.emptyPrint)
        }
        return runner
    }

    private func userAgents(at path: String) -> LaunchdDirectory {
        LaunchdDirectory(path: path, kind: .launchAgent, domain: .user, launchctlDomain: "gui/501")
    }

    @Test func buildsItemsWithStateAndOwner() async throws {
        let plists: [String: [String: Any]] = [
            "com.docker.helper.plist": ["Label": "com.docker.helper", "Program": "/bin/ls", "AssociatedBundleIdentifiers": "com.docker.docker"],
            "com.off.plist": ["Label": "com.off", "Program": "/opt/missing/off"],
        ]
        let runner = MockCommandRunner()
        runner.stub("/bin/launchctl print-disabled system", CommandResult(exitCode: 0, stdout: "\tdisabled services = {\n\t\t\"com.off\" => disabled\n\t}\n"))
        runner.stub("/bin/launchctl print system", CommandResult(exitCode: 0, stdout: "\tservices = {\n\t\t   12      - \tcom.docker.helper\n\t}\n"))

        let (source, items, directory) = try await withDirectory(plists) { directory in
            let source = LaunchdSource(
                directories: [LaunchdDirectory(path: directory, kind: .launchDaemon, domain: .system, launchctlDomain: "system")],
                runner: runner, resolver: StubAppResolver()
            )
            return (source, try await source.collect().autostartItems.sorted { $0.label < $1.label }, directory)
        }

        #expect(source.id == .launchd)
        #expect(items.map(\.label) == ["com.docker.helper", "com.off"])
        let helper = items[0]
        #expect(helper.kind == .launchDaemon && helper.domain == .system && helper.source == .launchd)
        #expect(helper.isEnabled && helper.isLoaded == true && helper.programPresence == .present)
        #expect(helper.program == "/bin/ls")
        #expect(helper.owner?.bundleID == "com.docker.docker")
        #expect(helper.plistPath == directory + "/com.docker.helper.plist")
        let off = items[1]
        #expect(!off.isEnabled && off.isLoaded == false && off.programPresence == .missing)
        #expect(off.owner == nil)
    }

    @Test func itemsCarrySessionTypes() async throws {
        let plists: [String: [String: Any]] = [
            "a.plist": ["Label": "a", "Program": "/bin/ls", "LimitLoadToSessionType": "Background"],
            "b.plist": ["Label": "b", "Program": "/bin/ls"],
        ]
        let items = try await withDirectory(plists) { directory in
            try await LaunchdSource(directories: [userAgents(at: directory)], runner: succeedingRunner(), resolver: StubAppResolver())
                .collect().autostartItems.sorted { $0.label < $1.label }
        }
        #expect(items.map(\.sessionTypes) == [["Background"], nil])
    }

    /// Inhalt und Fingerabdruck eines Eintrags gehören zu demselben Lesevorgang (#156, Codex-Nachprüfung): Ersetzt ein
    /// Updater die Plist, während die Quelle auf launchctl wartet, trägt der Eintrag die Angaben der gelesenen Datei und
    /// deren Fingerabdruck – nie die Angaben der alten mit dem Fingerabdruck der neuen, sonst hielte das Aufräumen die
    /// ersetzte Plist für den beobachteten Eintrag.
    @Test func plistFingerprintBelongsToTheContentThatWasRead() async throws {
        let original: [String: Any] = ["Label": "a", "Program": "/bin/ls", "LimitLoadToSessionType": "Background"]
        let replacement = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "a", "Program": "/bin/ls"] as [String: Any], format: .xml, options: 0
        )
        let (item, before, after) = try await withDirectory(["a.plist": original]) { directory in
            let path = directory + "/a.plist"
            let before = try #require(FileFingerprint(of: path))
            let runner = SideEffectCommandRunner(succeedingRunner(), on: "/bin/launchctl print gui/501") {
                try replacement.write(to: URL(filePath: path), options: .atomic)
            }
            let items = try await LaunchdSource(directories: [userAgents(at: directory)], runner: runner, resolver: StubAppResolver())
                .collect().autostartItems
            return (try #require(items.first), before, try #require(FileFingerprint(of: path)))
        }
        #expect(before != after)
        #expect(item.sessionTypes == ["Background"])
        #expect(item.plistFingerprint == before)
    }

    /// Eine kaputte Plist liefert keinen Eintrag, ist aber eine Lücke (#139); ein fehlendes Verzeichnis und Dateien
    /// ohne `.plist` sind es nicht.
    @Test func reportsBrokenPlistsAsGapsAndSkipsMissingDirectories() async throws {
        let (contribution, directory) = try await withDirectory(
            ["ok.plist": ["Label": "ok", "Program": "/bin/ls"]], rawFiles: ["broken.plist": "kein plist", "notes.txt": "x"]
        ) { directory in
            let source = LaunchdSource(
                directories: [
                    userAgents(at: directory),
                    LaunchdDirectory(path: "/nonexistent", kind: .launchAgent, domain: .system, launchctlDomain: "gui/501"),
                ],
                runner: succeedingRunner(), resolver: StubAppResolver()
            )
            return (try await source.collect(), directory)
        }
        #expect(contribution.autostartItems.map(\.label) == ["ok"])
        #expect(contribution.incompletePlistPaths == [directory + "/broken.plist"])
        #expect(contribution.limitations == [
            "Plist \(directory)/broken.plist nicht auswertbar (\(LaunchdSource.invalidPlistText)) – bekannte Einträge bleiben mit altem Stand erhalten",
        ])
    }

    @Test func ownerFallsBackToAppBundleInProgramPath() async throws {
        let items = try await withDirectory(["x.plist": ["Label": "x", "Program": "/Applications/Foo.app/Contents/MacOS/foo-agent"]]) { directory in
            try await LaunchdSource(directories: [userAgents(at: directory)], runner: succeedingRunner(), resolver: StubAppResolver())
                .collect().autostartItems
        }
        let item = try #require(items.first)
        #expect(item.owner?.path == "/Applications/Foo.app")
    }

    @Test func failedLaunchctlFailsWholeSource() async throws {
        // Ungestubbte Befehle liefern Exit 127 – wie eine nicht zugängliche Domain.
        let runner = MockCommandRunner()
        runner.stub("/bin/launchctl print-disabled gui/501", Self.emptyDisabled)
        let error = try await withDirectory(["a.plist": ["Label": "a", "Program": "/bin/ls"]]) { directory in
            await #expect(throws: LaunchdSourceError.self) {
                try await LaunchdSource(directories: [userAgents(at: directory)], runner: runner, resolver: StubAppResolver()).collect()
            }
        }
        #expect(error == .launchctlFailed(
            domain: "gui/501", arguments: ["print", "gui/501"], exitCode: 127, message: "not stubbed: /bin/launchctl print gui/501"
        ))
    }

    /// Exit 0, aber ohne erwarteten Blockkopf: Statt alle Einträge als deaktiviert/entladen zu melden, scheitert die Quelle.
    @Test(arguments: [["print-disabled", "gui/501"], ["print", "gui/501"]])
    func unexpectedOutputFormatFailsWholeSource(arguments: [String]) async throws {
        let runner = succeedingRunner()
        runner.stub("/bin/launchctl " + arguments.joined(separator: " "), CommandResult(exitCode: 0, stdout: "neues Format\n"))
        let error = try await withDirectory(["a.plist": ["Label": "a", "Program": "/bin/ls"]]) { directory in
            await #expect(throws: LaunchdSourceError.self) {
                try await LaunchdSource(directories: [userAgents(at: directory)], runner: runner, resolver: StubAppResolver()).collect()
            }
        }
        #expect(error == .launchctlFailed(domain: "gui/501", arguments: arguments, exitCode: 0, message: "unerwartetes Ausgabeformat"))
    }

    @Test func launchErrorFailsWholeSource() async throws {
        let runner = ThrowingRunner(error: CommandError.timedOut(executable: "/bin/launchctl", seconds: 30))
        let error = try await withDirectory(["a.plist": ["Label": "a", "Program": "/bin/ls"]]) { directory in
            await #expect(throws: LaunchdSourceError.self) {
                try await LaunchdSource(directories: [userAgents(at: directory)], runner: runner, resolver: StubAppResolver()).collect()
            }
        }
        guard case .launchctlFailed(let domain, let arguments, let exitCode, _) = error else {
            Issue.record("unerwarteter Fehler: \(String(describing: error))")
            return
        }
        #expect(domain == "gui/501" && arguments == ["print-disabled", "gui/501"] && exitCode == nil)
    }

    @Test func cancellationPropagatesUnchanged() async throws {
        let runner = ThrowingRunner(error: CancellationError())
        _ = try await withDirectory(["a.plist": ["Label": "a", "Program": "/bin/ls"]]) { directory in
            await #expect(throws: CancellationError.self) {
                try await LaunchdSource(directories: [userAgents(at: directory)], runner: runner, resolver: StubAppResolver()).collect()
            }
        }
    }

    @Test func queriesEachLaunchctlDomainOnceAndSkipsEmptyDirectories() async throws {
        let runner = succeedingRunner()
        try await withDirectory(["a.plist": ["Label": "a", "Program": "/bin/ls"]]) { first in
            try await withDirectory(["b.plist": ["Label": "b", "Program": "/bin/ls"]]) { second in
                try await withDirectory([:]) { empty in
                    _ = try await LaunchdSource(
                        directories: [
                            userAgents(at: first),
                            LaunchdDirectory(path: second, kind: .launchAgent, domain: .system, launchctlDomain: "gui/501"),
                            LaunchdDirectory(path: empty, kind: .launchDaemon, domain: .system, launchctlDomain: "system"),
                        ],
                        runner: runner, resolver: StubAppResolver()
                    ).collect()
                }
            }
        }
        #expect(runner.calls.sorted() == ["/bin/launchctl print gui/501", "/bin/launchctl print-disabled gui/501"])
    }

    @Test func nonAbsoluteOrMissingProgramsHaveUnknownPresence() async throws {
        let plists: [String: [String: Any]] = [
            "bare.plist": ["Label": "bare", "ProgramArguments": ["node", "/Users/x/server.js"]],
            "env.plist": ["Label": "env", "ProgramArguments": ["/usr/bin/env", "node"]],
            "none.plist": ["Label": "none"],
        ]
        let items = try await withDirectory(plists) { directory in
            try await LaunchdSource(directories: [userAgents(at: directory)], runner: succeedingRunner(), resolver: StubAppResolver())
                .collect().autostartItems.sorted { $0.label < $1.label }
        }

        #expect(items.map(\.label) == ["bare", "env", "none"])
        #expect(items.map(\.program) == ["node", "/usr/bin/env", nil])
        #expect(items.map(\.programPresence) == [.unknown, .present, .unknown])
    }

    @Test func itemsCarryInterpreterLaunches() async throws {
        let plists: [String: [String: Any]] = [
            "a.plist": ["Label": "a", "ProgramArguments": ["/bin/sh", "-c", "~/Library/.x/evil"]],
            "b.plist": ["Label": "b", "Program": "/bin/ls"],
        ]
        let items = try await withDirectory(plists) { directory in
            try await LaunchdSource(directories: [userAgents(at: directory)], runner: succeedingRunner(), resolver: StubAppResolver())
                .collect().autostartItems.sorted { $0.label < $1.label }
        }
        #expect(items.map(\.launchesInterpreter) == [true, false])
    }

    /// Ein vorhandenes Programm mit `#!` am Anfang ist ein Skript; Binärprogramme, fehlende und nicht absolute
    /// Programme nicht. Der Interpreter wird samt Signatur festgehalten – nur vorhandene, absolute Interpreter werden
    /// geprüft.
    @Test func itemsMarkShebangScriptsWithTheirInterpreter() async throws {
        let inspector = RecordingSigningInspector(result: SigningInfo(kind: .apple))
        let items = try await ScratchDirectory.with(prefix: "scripts") { scripts in
            let script = scripts.appending(path: "agent.sh")
            try "#!/bin/sh\necho hi\n".write(to: script, atomically: true, encoding: .utf8)
            let envScript = scripts.appending(path: "env.py")
            try "#!/usr/bin/env python3\nprint(1)\n".write(to: envScript, atomically: true, encoding: .utf8)
            let missingInterpreter = scripts.appending(path: "gone.sh")
            try "#!/opt/missing/interp\n".write(to: missingInterpreter, atomically: true, encoding: .utf8)
            let crlfScript = scripts.appending(path: "crlf.sh")
            try "#!/bin/sh\r\necho hi\r\n".write(to: crlfScript, atomically: true, encoding: .utf8)
            let shortFile = scripts.appending(path: "short")
            try "#".write(to: shortFile, atomically: true, encoding: .utf8)
            let plists: [String: [String: Any]] = [
                "a.plist": ["Label": "a", "Program": script.path],
                "b.plist": ["Label": "b", "Program": "/bin/ls"],
                "c.plist": ["Label": "c", "Program": scripts.appending(path: "missing.sh").path],
                "d.plist": ["Label": "d", "ProgramArguments": ["agent.sh"]],
                "e.plist": ["Label": "e", "Program": shortFile.path],
                "f.plist": ["Label": "f", "Program": envScript.path],
                "g.plist": ["Label": "g", "Program": missingInterpreter.path],
                "h.plist": ["Label": "h", "Program": crlfScript.path],
            ]
            return try await withDirectory(plists) { directory in
                try await LaunchdSource(
                    directories: [userAgents(at: directory)], runner: succeedingRunner(), resolver: StubAppResolver(),
                    inspector: inspector
                ).collect().autostartItems.sorted { $0.label < $1.label }
            }
        }
        let apple = SigningInfo(kind: .apple)
        #expect(items.map(\.programScript) == [
            ProgramScript(interpreter: "/bin/sh", interpreterSigning: apple), nil, nil, nil, nil,
            ProgramScript(
                interpreter: "/usr/bin/env", arguments: ["python3"], interpreterSigning: apple,
                resolvedEnvProgram: ProgramScript.ResolvedProgram(path: "/usr/bin/python3", signing: apple)
            ),
            ProgramScript(interpreter: "/opt/missing/interp", interpreterSigning: nil),
            // CRLF: `/bin/sh\r` gibt es nicht – wie für den Kernel.
            ProgramScript(interpreter: "/bin/sh\r", interpreterSigning: nil),
        ])
        #expect(items.last?.programScript?.interpreterOrigin == .unknown)
        #expect(inspector.paths.contains("/bin/sh") && inspector.paths.contains("/usr/bin/env"))
        #expect(!inspector.paths.contains("/opt/missing/interp"))
    }

    /// `env` wird nur in der eindeutigen Form `/usr/bin/env <name>` und ohne eigenen `PATH` der Plist aufgelöst – gegen
    /// launchds Standard-PATH. Optionen, Zuweisungen oder ein `PATH` in `EnvironmentVariables` lassen es offen.
    @Test func envIsResolvedOnlyInItsPlainFormWithTheStandardPath() async throws {
        let inspector = RecordingSigningInspector(result: SigningInfo(kind: .apple))
        let items = try await ScratchDirectory.with(prefix: "env") { scripts in
            func script(_ name: String, _ line: String) throws -> String {
                let file = scripts.appending(path: name)
                try "\(line)\nprint(1)\n".write(to: file, atomically: true, encoding: .utf8)
                return file.path
            }
            let plain = try script("plain.py", "#!/usr/bin/env python3")
            let plists: [String: [String: Any]] = [
                "a.plist": ["Label": "a", "Program": plain],
                "b.plist": ["Label": "b", "Program": plain, "EnvironmentVariables": ["PATH": scripts.path]],
                "c.plist": ["Label": "c", "Program": try script("s.py", "#!/usr/bin/env -S -P\(scripts.path) python3")],
                "d.plist": ["Label": "d", "Program": try script("u.py", "#!/usr/bin/env -u PATH python3")],
                "e.plist": ["Label": "e", "Program": try script("p.py", "#!/usr/bin/env PATH=\(scripts.path) python3")],
                "f.plist": ["Label": "f", "Program": try script("x.py", "#!/usr/bin/env grantry-missing-program")],
            ]
            return try await withDirectory(plists) { directory in
                try await LaunchdSource(
                    directories: [userAgents(at: directory)], runner: succeedingRunner(), resolver: StubAppResolver(),
                    inspector: inspector
                ).collect().autostartItems.sorted { $0.label < $1.label }
            }
        }
        #expect(items.map { $0.programScript?.resolvedEnvProgram?.path } == ["/usr/bin/python3", nil, nil, nil, nil, nil])
        #expect(items.map { $0.programScript?.interpreterOrigin } == [.verified, .unknown, .unknown, .unknown, .unknown, .unknown])
    }

    /// Mit der echten Signaturprüfung: `#!/usr/bin/env python3` findet Apples `/usr/bin/python3`.
    @Test func envPythonResolvesToApplesPython() async throws {
        let items = try await ScratchDirectory.with(prefix: "env") { scripts in
            let file = scripts.appending(path: "agent.py")
            try "#!/usr/bin/env python3\nprint(1)\n".write(to: file, atomically: true, encoding: .utf8)
            return try await withDirectory(["a.plist": ["Label": "a", "Program": file.path]]) { directory in
                try await LaunchdSource(directories: [userAgents(at: directory)], runner: succeedingRunner(), resolver: StubAppResolver())
                    .collect().autostartItems
            }
        }
        let script = try #require(items.first?.programScript)
        #expect(script.resolvedEnvProgram?.path == "/usr/bin/python3")
        #expect(script.resolvedEnvProgram?.signing?.kind == .apple)
        #expect(script.interpreterOrigin == .verified)
    }

    /// Eine FIFO als Programm hält den Scan nicht an: keine Signatur, kein Skript.
    @Test func fifoProgramDoesNotBlockTheScan() async throws {
        try await ScratchDirectory.with(prefix: "fifo") { scratch in
            let fifo = try FIFOFixture.make(in: scratch)
            let plists: [String: [String: Any]] = ["a.plist": ["Label": "a", "Program": fifo.path]]
            try await withDirectory(plists) { directory in
                let source = LaunchdSource(directories: [userAgents(at: directory)], runner: succeedingRunner(), resolver: StubAppResolver())
                let collected = await FIFOFixture.completes(unblocking: fifo) { try? await source.collect().autostartItems }
                let item = try #require(collected??.first)
                #expect(item.programSigning == .unknown)
                #expect(item.programScript == nil)
            }
        }
    }

    @Test func inspectsSigningOnlyOfAbsoluteExistingPrograms() async throws {
        let plists: [String: [String: Any]] = [
            "abs.plist": ["Label": "abs", "Program": "/bin/ls"],
            "bare.plist": ["Label": "bare", "ProgramArguments": ["node", "/Users/x/server.js"]],
            "gone.plist": ["Label": "gone", "Program": "/opt/missing/gone"],
            "none.plist": ["Label": "none"],
        ]
        let inspector = RecordingSigningInspector(result: SigningInfo(kind: .adHoc))
        let items = try await withDirectory(plists) { directory in
            try await LaunchdSource(
                directories: [userAgents(at: directory)], runner: succeedingRunner(), resolver: StubAppResolver(),
                inspector: inspector
            ).collect().autostartItems.sorted { $0.label < $1.label }
        }

        #expect(items.map(\.label) == ["abs", "bare", "gone", "none"])
        #expect(items.map(\.programSigning) == [SigningInfo(kind: .adHoc), nil, nil, nil])
        #expect(inspector.paths == ["/bin/ls"])
    }

    @Test func standardInspectorReportsRealSigning() async throws {
        let items = try await withDirectory(["abs.plist": ["Label": "abs", "Program": "/bin/ls"]]) { directory in
            try await LaunchdSource(directories: [userAgents(at: directory)], runner: succeedingRunner(), resolver: StubAppResolver())
                .collect().autostartItems
        }
        #expect(items.map(\.programSigning?.kind) == [.apple])
    }

    /// Wie Wazuh unter `/Library/Ossec`: Ohne Leserecht auf das Elternverzeichnis ist die Existenz unbekannt.
    @Test(.disabled(if: geteuid() == 0, "root umgeht Dateirechte")) func programInsideUnreadableDirectoryHasUnknownPresence() async throws {
        try await LockedDirectoryFixture.with(fileNamed: "wazuh-execd") { file in
            #expect(LaunchdSource.programPresence(file.path) == .unknown)
        }
    }

    @Test func resolvesEachOwnerOncePerCollect() async throws {
        let plists: [String: [String: Any]] = [
            "a.plist": ["Label": "a", "Program": "/bin/ls", "AssociatedBundleIdentifiers": ["com.example.app"]],
            "b.plist": ["Label": "b", "Program": "/bin/ls", "AssociatedBundleIdentifiers": ["com.example.app"]],
            "c.plist": ["Label": "c", "Program": "/Applications/Foo.app/Contents/MacOS/c"],
            "d.plist": ["Label": "d", "Program": "/Applications/Foo.app/Contents/MacOS/d"],
        ]
        let resolver = CountingResolver()
        let items = try await withDirectory(plists) { directory in
            try await LaunchdSource(directories: [userAgents(at: directory)], runner: succeedingRunner(), resolver: resolver)
                .collect().autostartItems.sorted { $0.label < $1.label }
        }

        #expect(items.map(\.owner?.bundleID) == ["com.example.app", "com.example.app", nil, nil])
        #expect(items.map(\.owner?.path) == Array(repeating: "/Applications/com.example.app.app", count: 2) + Array(repeating: "/Applications/Foo.app", count: 2))
        #expect(resolver.calls == 2)
    }

    // MARK: - Ladezustand bei mehrdeutigen Labels

    /// `launchctl print <domain>` mit den geladenen Diensten `labels`.
    private static func domainPrint(loaded labels: [String]) -> CommandResult {
        let rows = labels.map { "\t\t     750      - \t\($0)\n" }.joined()
        return CommandResult(exitCode: 0, stdout: "gui/501 = {\n\tservices = {\n\(rows)\t}\n}\n")
    }

    /// `launchctl print <domain>/<label>` eines aus `plist` geladenen Dienstes.
    private static func servicePrint(path plist: String) -> CommandResult {
        CommandResult(exitCode: 0, stdout: "gui/501/x = {\n\tpath = \(plist)\n}\n")
    }

    /// Ein `com.apple.`-Label außerhalb der Apple-Verzeichnisse kann mit einem echten Apple-Dienst kollidieren: Es gilt
    /// nur als geladen, wenn launchd den Dienst aus genau dieser Plist geladen hat; ist das nicht feststellbar, bleibt
    /// der Ladezustand unbekannt.
    @Test func appleLabelCountsAsLoadedOnlyFromThisPlist() async throws {
        let plists: [String: [String: Any]] = [
            "dock.plist": ["Label": "com.apple.Dock.agent", "Program": "/bin/ls"],
            "odd.plist": ["Label": "com.apple.odd", "Program": "/bin/ls"],
            "own.plist": ["Label": "com.apple.update.agent", "Program": "/bin/ls"],
            "idle.plist": ["Label": "com.apple.idle", "Program": "/bin/ls"],
        ]
        let runner = succeedingRunner()
        runner.stub("/bin/launchctl print gui/501", Self.domainPrint(loaded: ["com.apple.Dock.agent", "com.apple.odd", "com.apple.update.agent"]))
        runner.stub("/bin/launchctl print gui/501/com.apple.Dock.agent", Self.servicePrint(path: "/System/Library/LaunchAgents/com.apple.Dock.plist"))
        runner.stub("/bin/launchctl print gui/501/com.apple.odd", CommandResult(exitCode: 5, stdout: "", stderr: "Input/output error"))
        let items = try await withDirectory(plists) { directory in
            runner.stub("/bin/launchctl print gui/501/com.apple.update.agent", Self.servicePrint(path: directory + "/own.plist"))
            return try await LaunchdSource(directories: [userAgents(at: directory)], runner: runner, resolver: StubAppResolver())
                .collect().autostartItems.sorted { $0.label < $1.label }
        }
        #expect(items.map(\.label) == ["com.apple.Dock.agent", "com.apple.idle", "com.apple.odd", "com.apple.update.agent"])
        #expect(items.map(\.isLoaded) == [false, false, nil, true])
        // Nicht geladene Labels brauchen keine Einzelabfrage.
        #expect(!runner.calls.contains("/bin/launchctl print gui/501/com.apple.idle"))
    }

    /// Dasselbe Label in zwei Verzeichnissen derselben Domain: Nur die Plist, aus der launchd geladen hat, gilt als geladen.
    @Test func duplicateLabelIsLoadedOnlyFromItsPlist() async throws {
        let runner = succeedingRunner()
        runner.stub("/bin/launchctl print gui/501", Self.domainPrint(loaded: ["com.vendor.agent", "com.vendor.other"]))
        let items = try await withDirectory(["a.plist": ["Label": "com.vendor.agent", "Program": "/bin/ls"]]) { first in
            try await withDirectory([
                "a.plist": ["Label": "com.vendor.agent", "Program": "/bin/ls"],
                "b.plist": ["Label": "com.vendor.other", "Program": "/bin/ls"],
            ]) { second in
                runner.stub("/bin/launchctl print gui/501/com.vendor.agent", Self.servicePrint(path: second + "/a.plist"))
                return try await LaunchdSource(
                    directories: [userAgents(at: first), LaunchdDirectory(path: second, kind: .launchAgent, domain: .system, launchctlDomain: "gui/501")],
                    runner: runner, resolver: StubAppResolver()
                ).collect().autostartItems
            }
        }
        #expect(items.map(\.label) == ["com.vendor.agent", "com.vendor.agent", "com.vendor.other"])
        #expect(items.map(\.isLoaded) == [false, true, true])
        #expect(!runner.calls.contains("/bin/launchctl print gui/501/com.vendor.other"))
    }

    @Test func standardDirectoriesCoverUserAndSystemLocations() {
        let directories = LaunchdDirectory.standard(uid: 501, home: "/Users/test")
        #expect(directories == [
            LaunchdDirectory(path: "/Users/test/Library/LaunchAgents", kind: .launchAgent, domain: .user, launchctlDomain: "gui/501"),
            LaunchdDirectory(path: "/Library/LaunchAgents", kind: .launchAgent, domain: .system, launchctlDomain: "gui/501"),
            LaunchdDirectory(path: "/Library/LaunchDaemons", kind: .launchDaemon, domain: .system, launchctlDomain: "system"),
        ])
    }
}

/// Wirft bei jedem Aufruf `error`.
private struct ThrowingRunner: CommandRunning {
    let error: any Error

    func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> CommandResult {
        throw error
    }
}
