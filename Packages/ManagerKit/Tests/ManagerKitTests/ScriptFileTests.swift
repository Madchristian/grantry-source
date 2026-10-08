import Foundation
import Testing
@testable import ManagerKit
import TestSupport

@Suite struct ScriptFileTests {
    private func shebang(_ text: String) -> Shebang? {
        ScriptFile.shebang(in: Data(text.utf8))
    }

    @Test func parsesInterpreterAndArguments() {
        #expect(shebang("#!/bin/zsh\necho hi\n") == Shebang(interpreter: "/bin/zsh", arguments: []))
        #expect(shebang("#! /bin/sh -e\t-u \n") == Shebang(interpreter: "/bin/sh", arguments: ["-e", "-u"]))
        #expect(shebang("#!/bin/zsh\n")?.envProgram == nil)
    }

    /// Wie XNU (`exec_shell_imgact`): Die Zeile endet an `\n` oder `#`, `\r` gehört zum Pfad. Eine CRLF-Datei nennt
    /// also `/bin/sh\r` – den findet auch der Kernel nicht.
    @Test(arguments: [
        ("#!/bin/sh\r\necho hi\r\n", Shebang(interpreter: "/bin/sh\r", arguments: [])),
        ("#! /bin/sh -e\r\n", Shebang(interpreter: "/bin/sh", arguments: ["-e\r"])),
        ("#!~/.x/sh\r/evil\n", Shebang(interpreter: "~/.x/sh\r/evil", arguments: [])),
        ("#!/path/evil#x\n", Shebang(interpreter: "/path/evil", arguments: [])),
        ("#!/bin/sh -e # Kommentar\n", Shebang(interpreter: "/bin/sh", arguments: ["-e"])),
        ("#!#/bin/sh\n", Shebang(interpreter: "", arguments: [])),
    ])
    func parsesLikeTheKernel(_ text: String, expected: Shebang) {
        #expect(shebang(text) == expected)
    }

    /// Ohne Zeilenende (`\n` oder `#`) in den ersten `maximumHeadLength` Bytes verweigert der Kernel die Ausführung
    /// (`ENOEXEC`): ein Skript ohne gültigen Interpreter.
    @Test func withoutLineEndThereIsNoInterpreter() {
        #expect(shebang("#!/bin/zsh") == Shebang(interpreter: "", arguments: []))
        #expect(shebang("#!/bin/sh -e\r") == Shebang(interpreter: "", arguments: []))
    }

    /// Die Zeile muss samt `#!` und Zeilenende in `maximumHeadLength` (512) Bytes passen.
    @Test func lineEndMustFitInTheHead() {
        let limit = ScriptFile.maximumHeadLength
        #expect(limit == 512)
        let fitting = "#!/" + String(repeating: "a", count: limit - 4) + "\n"
        #expect(fitting.utf8.count == limit)
        #expect(ScriptFile.shebang(in: Data(fitting.utf8))?.interpreter.utf8.count == limit - 3)
        let tooLong = Data(("#!/" + String(repeating: "a", count: limit - 3) + "\n").utf8).prefix(limit)
        #expect(ScriptFile.shebang(in: tooLong)?.interpreter == "")
    }

    /// `env` sucht das Programm über `PATH`. Eindeutig ist nur genau `/usr/bin/env <name>`: Optionen (`-S`, `-P`,
    /// `-u`), Zuweisungen (`PATH=…`), weitere Argumente oder ein Pfad statt eines Namens ergeben kein Programm.
    @Test(arguments: [
        ("#!/usr/bin/env python3\n", "python3"),
        ("#!/usr/bin/env -S python3 -u\n", nil),
        ("#!/usr/bin/env -S -P/Users/x/.bin python3\n", nil),
        ("#!/usr/bin/env -P /Users/x/.bin python3\n", nil),
        ("#!/usr/bin/env -u PATH python3\n", nil),
        ("#!/usr/bin/env PATH=/Users/x/.bin python3\n", nil),
        ("#!/usr/bin/env LANG=C ruby\n", nil),
        ("#!/usr/bin/env python3 -u\n", nil),
        ("#!/usr/bin/env ./python3\n", nil),
        ("#!/usr/bin/env /Users/x/evil\n", nil),
        ("#!/usr/bin/env\n", nil),
    ] as [(String, String?)])
    func envProgram(_ text: String, program: String?) {
        #expect(shebang(text)?.interpreter == "/usr/bin/env")
        #expect(shebang(text)?.envProgram == program)
    }

    /// Nur `/usr/bin/env` selbst – ein anderes `env` kann alles tun.
    @Test func envProgramOnlyForTheSystemEnv() {
        #expect(shebang("#!/usr/local/bin/env python3\n")?.envProgram == nil)
        #expect(shebang("#!/Users/x/env python3\n")?.envProgram == nil)
    }

    @Test func withoutShebangThereIsNoScript() {
        #expect(shebang("echo hi\n") == nil)
        #expect(shebang("#") == nil)
        #expect(shebang("") == nil)
    }

    /// „#!“ ohne Interpreter bleibt ein Skript – mit leerem Interpreter, den die Bewertung als unbekannt behandelt.
    @Test func emptyInterpreterIsStillAScript() {
        #expect(shebang("#!\nfoo\n") == Shebang(interpreter: "", arguments: []))
    }

    /// Gelesen wird höchstens `maximumHeadLength` Bytes: Eine endlos lange erste Zeile hat dort kein Zeilenende.
    @Test func readsAtMostTheHeadLimit() throws {
        try ScratchDirectory.with(prefix: "shebang") { directory in
            let long = directory.appending(path: "long")
            try ("#!/" + String(repeating: "a", count: 10_000) + "\n").write(to: long, atomically: true, encoding: .utf8)
            #expect(ScriptFile.shebang(atPath: long.path) == Shebang(interpreter: "", arguments: []))
            let crlf = directory.appending(path: "crlf")
            try "#!/bin/sh\r\necho hi\r\n".write(to: crlf, atomically: true, encoding: .utf8)
            #expect(ScriptFile.shebang(atPath: crlf.path)?.interpreter == "/bin/sh\r")
        }
    }

    @Test func missingOrDirectoryIsNoScript() throws {
        try ScratchDirectory.with(prefix: "shebang") { directory in
            #expect(ScriptFile.shebang(atPath: directory.path) == nil)
            #expect(ScriptFile.shebang(atPath: directory.appending(path: "missing").path) == nil)
        }
    }
}
