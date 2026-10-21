import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct ExecutableKindTests {
    private func kind(_ text: String) -> ExecutableKind? { ExecutableKind.parse(Data(text.utf8)) }

    @Test func recognizesShebangForms() {
        #expect(kind("#!/usr/bin/env node\nrequire('x')") == .environmentScript("node"))
        #expect(kind("#! /opt/homebrew/Cellar/pnpm/9.0.0/libexec/node --x\n")
                == .script(interpreter: "/opt/homebrew/Cellar/pnpm/9.0.0/libexec/node"))
        #expect(kind("#!/bin/bash\nexec node \"$@\"") == .script(interpreter: "/bin/bash"))
    }

    @Test func machOIsBinary() {
        #expect(ExecutableKind.parse(Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00])) == .binary)
    }

    @Test func unclearShebangIsUnknown() {
        #expect(kind("#!node\n") == nil)
        #expect(kind("#!/usr/bin/env\n") == nil)
        // `env` mit Optionen kann die Suche verändern: unklar, also wie bisher `node` daneben verlangen.
        #expect(kind("#!/usr/bin/env -S node --no-warnings\n") == nil)
        #expect(kind("#!\n") == nil)
        #expect(ExecutableKind.parse(Data()) == nil)
    }

    @Test func readsTheResolvedFileOnly() throws {
        try ScratchDirectory.withCanonical(prefix: "executable-kind") { scratch in
            let script = scratch.appending(path: "pnpm.cjs")
            try Data("#!/usr/bin/env node\n".utf8).write(to: script)
            let link = scratch.appending(path: "pnpm")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: script)
            #expect(ExecutableKind.of(link.path) == .environmentScript("node"))
            #expect(ExecutableKind.of(scratch.path) == nil)
            #expect(ExecutableKind.of(scratch.appending(path: "missing").path) == nil)
        }
    }
}
