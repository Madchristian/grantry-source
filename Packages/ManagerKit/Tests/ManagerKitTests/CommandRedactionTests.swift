import Darwin
import Foundation
import Testing
import TestSupport
@testable import ManagerKit

/// Regressionen aus #173. Sämtliche Geheimnisse sind synthetische Testwerte.
@Suite struct CommandRedactionTests {
    @Test(arguments: [
        ["python", "-c", "password='fixture173';print(password)"],
        ["/usr/bin/Python3.12", "-Ic", "d={'token':'fixture173'}"],
        ["node", "-e", "const token='fixture173';console.log(token)"],
        ["node", "--eval=const token='fixture173'"],
        ["perl5.34", "-we", "$password='fixture173';print $password"],
        ["ruby", "-e", "password='fixture173';puts password"],
        ["osascript", "-e", "set password to \"fixture173\""],
        ["env", "-Ssh", "-c", "true&&API_TOKEN=fixture173 run"],
        ["env", "-Ssh -c 'true&&API_TOKEN=fixture173 run'"],
        ["env", "--split-string=sh -c 'true&&API_TOKEN=fixture173 run'"],
        ["env", "-Snode -e \"const token='fixture173'\""],
    ])
    func inlineCodeIsHiddenAsAWhole(_ arguments: [String]) throws {
        let masked = MaskedCommand(program: nil, arguments: arguments, fingerprinter: .ephemeral())
        #expect(masked.arguments.last == "•••")
        #expect(!masked.arguments.joined().contains("fixture173"))
        #expect(masked.fingerprint != nil)
        let entry = try server(arguments)
        #expect(!String(decoding: try JSONEncoder().encode(entry), as: UTF8.self).contains("fixture173"))
        #expect(MCPServerDetail(entry: entry, findings: [], starter: .unknown).commandNote == MaskedCommandNote.hiddenScript)
    }

    @Test(arguments: [
        ["python3", "-u", "server.py", "--port", "8080"],
        ["node", "server.js", "-e", "some text"],
        ["env", "-Spython3 -u server.py"],
        ["python3", "-c", "print(42)"],
        ["node", "-e", "console.log(42)"],
        ["ruby", "-e", "puts 42"],
        ["osascript", "-e", "return 42"],
        ["tool", "a&&b", "<in>", "c|d"],
    ])
    func ordinaryArgumentsRemainReadable(_ arguments: [String]) {
        #expect(ArgumentRedactor.redact(arguments: arguments).values == arguments)
    }

    @Test(arguments: [false, true])
    func renamedShellAndSymlinkAreHiddenInMCPAndKeepTheirNoteAfterRemoval(copy: Bool) throws {
        try ScratchDirectory.with { directory in
            let executable = directory.appending(path: "runner")
            if copy {
                try FileManager.default.copyItem(atPath: "/bin/sh", toPath: executable.path)
            } else {
                try FileManager.default.createSymbolicLink(atPath: executable.path, withDestinationPath: "/bin/sh")
            }
            let entry = try server([executable.path, "-c", "true&&API_TOKEN=fixture173 run"])
            try FileManager.default.removeItem(at: executable)
            let data = try JSONEncoder().encode(entry)
            #expect(!String(decoding: data, as: UTF8.self).contains("fixture173"))
            let restored = try JSONDecoder().decode(MCPServerEntry.self, from: data)
            #expect(MCPServerDetail(entry: restored, findings: [], starter: .unknown).commandNote == MaskedCommandNote.hiddenScript)
        }
    }

    @Test func oldEntriesAreRemaskedEvenWithAFingerprint() throws {
        var entry = try server(["python3", "-c", "password='fixture173'", "--token", "another-fixture"])
        entry.transport = .local(command: "python3", arguments: ["-c", "password='fixture173'", "--token", "•••"])
        let restored = try JSONDecoder().decode(MCPServerEntry.self, from: legacyData(entry))
        #expect(!restored.transport.commandLine!.contains("fixture173"))
        var item = TestData.item("agent")
        item.program = "python3"
        item.programArguments = ["python3", "-c", "password='fixture173'", "--token", "•••"]
        item.programArgumentsFingerprint = entry.transportFingerprint
        let restoredItem = try JSONDecoder().decode(AutostartItem.self, from: legacyData(item))
        #expect(!restoredItem.commandLine!.contains("fixture173"))
    }

    /// Alte neutrale Interpreter können inzwischen fehlen oder auf einem unerreichbaren Volume liegen.
    /// Die Migration darf ihre heutige Datei nicht brauchen, um alte Inline-Geheimnisse ganz zu verbergen.
    @Test func legacyAbsoluteCommandsAreRemaskedIndependentlyOfTheirFiles() throws {
        try ScratchDirectory.with { directory in
            let executable = directory.appending(path: "runner")
            try FileManager.default.createSymbolicLink(atPath: executable.path, withDestinationPath: "/bin/echo")
            let arguments = [executable.path, "-c", "true&&API_TOKEN=fixture173 run"]
            var item = TestData.item("agent")
            item.program = executable.path
            item.programArguments = arguments
            var entry = try server(["tool", "ordinary"])
            entry.transport = .local(command: executable.path, arguments: Array(arguments.dropFirst()))
            let itemData = try legacyData(item), entryData = try legacyData(entry)
            for remove in [false, true] {
                if remove { try FileManager.default.removeItem(at: executable) }
                let restoredItem = try JSONDecoder().decode(AutostartItem.self, from: itemData)
                let restoredEntry = try JSONDecoder().decode(MCPServerEntry.self, from: entryData)
                #expect(restoredItem.programArguments == [executable.path, "-c", "•••"])
                #expect(restoredEntry.transport == .local(command: executable.path, arguments: ["-c", "•••"]))
                #expect(restoredItem.hasHiddenScript)
                #expect(restoredEntry.hasHiddenScript)
            }
        }
    }

    /// Ein aktueller Snapshot enthält schon die Scan-Einstufung. Eine spätere Dateiänderung darf normale
    /// Programmargumente beim Laden nicht nachträglich zu Shell-Code machen (und keinen Dateizugriff auslösen).
    @Test func storedClassificationDoesNotDependOnAChangedInterpreterFile() throws {
        try ScratchDirectory.with { directory in
            let executable = directory.appending(path: "runner")
            try FileManager.default.createSymbolicLink(atPath: executable.path, withDestinationPath: "/bin/echo")
            let entry = try server([executable.path, "literal $(value)"])
            var item = TestData.item("agent")
            item.program = executable.path
            item.programArguments = [executable.path, "literal $(value)"]
            let itemData = try JSONEncoder().encode(item), entryData = try JSONEncoder().encode(entry)
            try FileManager.default.removeItem(at: executable)
            try FileManager.default.createSymbolicLink(atPath: executable.path, withDestinationPath: "/bin/sh")
            let restoredItem = try JSONDecoder().decode(AutostartItem.self, from: itemData)
            let restoredEntry = try JSONDecoder().decode(MCPServerEntry.self, from: entryData)
            #expect(restoredItem.programArguments == [executable.path, "literal $(value)"])
            #expect(restoredEntry.transport == .local(command: executable.path, arguments: ["literal $(value)"]))
            #expect(!restoredItem.hasHiddenScript)
            #expect(!restoredEntry.hasHiddenScript)
        }
    }

    @Test(arguments: ["/bin/sh", "/bin/bash", "/bin/zsh"])
    func systemShellCopiesAreRecognizedWithoutSignatures(_ original: String) throws {
        try ScratchDirectory.with { directory in
            let executable = directory.appending(path: "curl")
            try FileManager.default.copyItem(atPath: original, toPath: executable.path)
            let redacted = ArgumentRedactor.redact(arguments: ["env", executable.path, "-c", "true&&API_TOKEN=fixture173 run"])
            #expect(redacted.values.last == "•••")
        }
    }

    @Test func unrelatedExecutableAndSpecialFileDoNotBecomeShells() throws {
        try ScratchDirectory.with { directory in
            let executable = directory.appending(path: "runner")
            try FileManager.default.copyItem(atPath: "/bin/echo", toPath: executable.path)
            let arguments = [executable.path, "-c", "ordinary argument"]
            #expect(ArgumentRedactor.redact(arguments: arguments).values == arguments)
            // POSIX resolution may keep /private where Foundation displays /var; the file identity must agree.
            #expect(FileFingerprint(of: try #require(CommandInterpreterPath.resolve(directory.path))) == FileFingerprint(of: directory.path))
            let fifo = directory.appending(path: "pipe")
            #expect(mkfifo(fifo.path, 0o600) == 0)
            #expect(FileFingerprint(of: try #require(CommandInterpreterPath.resolve(fifo.path))) == FileFingerprint(of: fifo.path))
        }
    }

    @Test(arguments: ["ordinary", "a b"])
    func manyOrdinaryArgumentsRemainReadableWithoutQuadraticCopies(_ argument: String) {
        let arguments = ["tool"] + Array(repeating: argument, count: ArgumentRedactor.maximumArgumentCount - 1)
        let elapsed = ContinuousClock().measure {
            #expect(ArgumentRedactor.redact(arguments: arguments).values == arguments)
        }
        #expect(elapsed < .seconds(5))
    }

    @Test(arguments: [
        ["env", "-Spython3 -W", "ignore", "-c", "password='fixture199'"],
        ["env", "--split-string=node --require", "module", "--eval", "const token='fixture199'"],
        ["env", "-Sperl -I", "lib", "-e", "$password='fixture199'"],
        ["env", "-Sruby -r", "library", "-e", "password='fixture199'"],
        ["env", "-Sosascript -l", "AppleScript", "-e", "set password to \"fixture199\""],
    ])
    func inlineOptionsContinueAcrossSplitStringAndArgumentList(_ arguments: [String]) {
        let result = ArgumentRedactor.redact(arguments: arguments, resolvingPath: { _ in nil })
        #expect(result.values.last == ArgumentRedactor.mask)
        #expect(result.hasHiddenScript)
    }

    private func legacyData(_ value: some Encodable) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        object.removeValue(forKey: "hasHiddenScript")
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func server(_ arguments: [String]) throws -> MCPServerEntry {
        let tool = try #require(AgentToolCatalog.standard.tool(id: "claudeDesktop"))
        let file = tool.files[0]
        let data = try JSONSerialization.data(withJSONObject: ["mcpServers": ["test": [
            "command": arguments[0], "args": Array(arguments.dropFirst())
        ]]])
        let document = try ConfigParsing.parse(data, syntax: .json, redaction: file.redaction)
        return try #require(AgentConfigExtractor.extract(document, file: file, tool: tool, configPath: "/fixture/config.json").servers.first)
    }
}
