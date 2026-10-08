import Foundation
import Testing
@testable import ManagerKit

@Suite struct AgentConfigEditorJSONTests {
    private let three = """
    {
      "mcpServers": {
        "a": { "command": "a", "env": { "TOKEN": "GEHEIM-A" } },
        "b": {
          "command": "b",
          "args": ["-y", "b"]
        },
        "c": { "command": "c" }
      },
      "other": true
    }

    """

    private func removing(_ name: String, from text: String) throws -> String {
        try AgentEditing.apply(.remove, to: text, AgentEditing.reference(name))
    }

    @Test func removesFirstMiddleAndLastEntryLineByLine() throws {
        #expect(try removing("a", from: three) == three.replacingOccurrences(
            of: "    \"a\": { \"command\": \"a\", \"env\": { \"TOKEN\": \"GEHEIM-A\" } },\n", with: ""))
        #expect(try removing("b", from: three) == three.replacingOccurrences(
            of: "    \"b\": {\n      \"command\": \"b\",\n      \"args\": [\"-y\", \"b\"]\n    },\n", with: ""))
        // Das letzte hat kein Komma: Das des vorigen fällt weg, sonst wäre strenges JSON kaputt.
        #expect(try removing("c", from: three) == three.replacingOccurrences(
            of: "    },\n    \"c\": { \"command\": \"c\" }\n", with: "    }\n"))
    }

    @Test func removesTheOnlyEntryAndKeepsTheEmptyObject() throws {
        let text = "{\n  \"mcpServers\": {\n    \"x\": {\"command\": \"x\"}\n  }\n}\n"
        #expect(try removing("x", from: text) == "{\n  \"mcpServers\": {\n  }\n}\n")
    }

    @Test func removesEntriesWithinOneLine() throws {
        let text = #"{"mcpServers": {"a": {"command": "a"}, "b": {"command": "b"}}}"#
        #expect(try removing("a", from: text) == #"{"mcpServers": {"b": {"command": "b"}}}"#)
        #expect(try removing("b", from: text) == #"{"mcpServers": {"a": {"command": "a"}}}"#)
    }

    @Test func keepsCommentsAndTrailingCommasInJSONC() throws {
        let text = """
        // Einstellungen
        {
          "editor.fontSize": 13, // Schrift
          "mcp": {
            "servers": {
              // Dateien
              "files": {
                "command": "npx", /* Paket */
                "args": ["-y", "pkg",],
              }, // Ende files
              "git": { "command": "git-mcp" },
            },
          },
        }

        """
        let reference = AgentEditing.reference("files", tool: AgentEditing.vscodeSettings.tool, path: AgentEditing.vscodeSettings.path)
        #expect(try AgentEditing.apply(.remove, to: text, reference) == """
        // Einstellungen
        {
          "editor.fontSize": 13, // Schrift
          "mcp": {
            "servers": {
              // Dateien
              "git": { "command": "git-mcp" },
            },
          },
        }

        """)
        let git = AgentEditing.reference("git", tool: AgentEditing.vscodeSettings.tool, path: AgentEditing.vscodeSettings.path)
        #expect(try AgentEditing.apply(.remove, to: text, git) == text.replacingOccurrences(
            of: "      \"git\": { \"command\": \"git-mcp\" },\n", with: ""))
    }

    @Test func keepsCRLFAndByteOrderMark() throws {
        let text = "\u{FEFF}{\r\n  \"mcpServers\": {\r\n    \"a\": {\"command\": \"a\"},\r\n    \"b\": {\"command\": \"b\"}\r\n  }\r\n}\r\n"
        #expect(try removing("b", from: text)
            == "\u{FEFF}{\r\n  \"mcpServers\": {\r\n    \"a\": {\"command\": \"a\"}\r\n  }\r\n}\r\n")
    }

    @Test func keepsOtherSecretsByteForByte() throws {
        let result = try removing("c", from: three)
        #expect(result.contains(#""TOKEN": "GEHEIM-A""#))
    }

    @Test func refusesDuplicateNamesAndChangedEntries() throws {
        let duplicate = #"{"mcpServers": {"a": {"command": "1"}, "a": {"command": "2"}}}"#
        #expect(throws: AgentConfigEditError.unsupportedLayout) { try removing("a", from: duplicate) }
        #expect(throws: AgentConfigEditError.entryChanged) { try removing("z", from: three) }
        let shown = TestData.mcpServer("a", transport: .local(command: "anders", arguments: []))
        let editor = try AgentEditing.editor(AgentEditing.reference("a"))
        #expect(throws: AgentConfigEditError.entryChanged) {
            try editor.apply(.remove, expected: shown, to: Data(three.utf8))
        }
        #expect(throws: AgentConfigEditError.unreadable("Zeile 1: Schlüssel erwartet")) { try removing("a", from: "{") }
    }

    @Test func switchesWindsurfDisabledField() throws {
        let reference = AgentEditing.reference("w", tool: AgentEditing.windsurf.tool, path: AgentEditing.windsurf.path)
        let missing = "{\n  \"mcpServers\": {\n    \"w\": {\n      \"command\": \"w\"\n    }\n  }\n}\n"
        let disabled = try AgentEditing.apply(.setEnabled(false), to: missing, reference)
        #expect(disabled == "{\n  \"mcpServers\": {\n    \"w\": {\n      \"command\": \"w\",\n      \"disabled\": true\n    }\n  }\n}\n")
        #expect(try AgentEditing.apply(.setEnabled(true), to: disabled, reference)
            == "{\n  \"mcpServers\": {\n    \"w\": {\n      \"command\": \"w\",\n      \"disabled\": false\n    }\n  }\n}\n")
        #expect(throws: AgentConfigEditError.alreadyInState) { try AgentEditing.apply(.setEnabled(true), to: missing, reference) }
        let text = #"{"mcpServers": {"w": {"command": "w", "disabled": "ja"}}}"#
        #expect(throws: AgentConfigEditError.self) { try AgentEditing.apply(.setEnabled(false), to: text, reference) }
    }

    @Test func formatsWithoutSwitchRefuseToggling() throws {
        #expect(throws: AgentConfigEditError.unsupportedLayout) { try AgentEditing.apply(.setEnabled(false), to: three, AgentEditing.reference("a")) }
    }

    @Test func switchesClaudeCodeProjectServersThroughTheNameList() throws {
        let text = """
        {
          "numStartups": 5,
          "projects": {
            "/Users/test/web": {
              "mcpServers": {
                "db": { "command": "db" }
              },
              "disabledMcpServers": []
            },
            "/Users/test/api/": {
              "mcpServers": { "x": { "command": "x" } }
            }
          }
        }

        """
        let database = AgentEditing.reference("db", tool: AgentEditing.claudeCode.tool, path: AgentEditing.claudeCode.path,
                                               scope: .project(path: "/Users/test/web"))
        let disabled = try AgentEditing.apply(.setEnabled(false), to: text, database)
        #expect(disabled == text.replacingOccurrences(of: "\"disabledMcpServers\": []", with: "\"disabledMcpServers\": [\"db\"]"))
        #expect(try AgentEditing.apply(.setEnabled(true), to: disabled, database) == text)

        // Projekt mit abschließendem `/` und ohne Liste: Die Liste entsteht.
        let api = AgentEditing.reference("x", tool: AgentEditing.claudeCode.tool, path: AgentEditing.claudeCode.path,
                                          scope: .project(path: "/Users/test/api"))
        #expect(try AgentEditing.apply(.setEnabled(false), to: text, api) == text.replacingOccurrences(
            of: "\"mcpServers\": { \"x\": { \"command\": \"x\" } }\n",
            with: "\"mcpServers\": { \"x\": { \"command\": \"x\" } },\n      \"disabledMcpServers\": [\"x\"]\n"))

        // Mehrfach eingetragen: Aktivieren entfernt jedes Vorkommen.
        let twice = text.replacingOccurrences(of: "\"disabledMcpServers\": []", with: "\"disabledMcpServers\": [\"db\", \"y\", \"db\"]")
        #expect(try AgentEditing.apply(.setEnabled(true), to: twice, database)
            == text.replacingOccurrences(of: "\"disabledMcpServers\": []", with: "\"disabledMcpServers\": [\"y\"]"))
    }

    /// Regression (Codex-Review zu #155, Folge): Auch über die Namensliste vergleicht die Wiederherstellung die
    /// unmaskierten Argumente – `--token abc` und `--token xyz` sind maskiert gleich.
    @Test func revertSwitchOfANameListComparesTheUnmaskedArguments() throws {
        let text = """
        {
          "projects": {
            "/Users/test/web": {
              "mcpServers": { "db": { "command": "db", "args": ["--token", "abc"] } },
              "disabledMcpServers": ["db"]
            }
          }
        }

        """
        let database = AgentEditing.reference("db", tool: AgentEditing.claudeCode.tool, path: AgentEditing.claudeCode.path,
                                               scope: .project(path: "/Users/test/web"))
        let editor = try AgentEditing.editor(database)
        let backup = Data(text.replacingOccurrences(of: "[\"db\"]", with: "[]").utf8)
        let replaced = Data(text.replacingOccurrences(of: "\"abc\"", with: "\"xyz\"").utf8)
        #expect(throws: AgentConfigEditError.nameTaken) { _ = try editor.revertSwitch(to: true, from: backup, into: replaced) }
        #expect(try editor.revertSwitch(to: true, from: backup, into: Data(text.utf8)) == backup)
    }

    @Test func reinsertsARemovedEntryIntoAChangedFile() throws {
        let reference = AgentEditing.reference("b")
        let removed = try removing("b", from: three)
        let changed = removed.replacingOccurrences(of: "\"other\": true", with: "\"other\": false")
        let editor = try AgentEditing.editor(reference)
        let restored = String(decoding: try editor.reinsert(from: Data(three.utf8), into: Data(changed.utf8)), as: UTF8.self)
        #expect(restored == changed.replacingOccurrences(
            of: "    \"c\": { \"command\": \"c\" }\n",
            with: "    \"c\": { \"command\": \"c\" },\n    \"b\": {\n      \"command\": \"b\",\n      \"args\": [\"-y\", \"b\"]\n    }\n"))
        #expect(throws: AgentConfigEditError.alreadyInState) {
            try editor.reinsert(from: Data(three.utf8), into: Data(three.utf8))
        }
    }

    /// Steht inzwischen ein anderer Server unter demselben Namen in der Datei, ist das kein „bereits wiederhergestellt“.
    @Test func refusesToReinsertOverADifferentServerOfTheSameName() throws {
        let editor = try AgentEditing.editor(AgentEditing.reference("b"))
        let other = three.replacingOccurrences(of: "\"command\": \"b\"", with: "\"command\": \"anders\"")
        #expect(throws: AgentConfigEditError.nameTaken) {
            try editor.reinsert(from: Data(three.utf8), into: Data(other.utf8))
        }
        // Doppelter Name: Der Quelltext ist nicht bestimmbar – Lage, kein Konflikt.
        let duplicated = three.replacingOccurrences(of: "    \"c\": { \"command\": \"c\" }\n",
                                                    with: "    \"c\": { \"command\": \"c\" },\n    \"b\": { \"command\": \"b\" }\n")
        #expect(throws: AgentConfigEditError.unsupportedLayout) {
            try editor.reinsert(from: Data(three.utf8), into: Data(duplicated.utf8))
        }
    }

    /// VS Code kennt zwei Server-Listen (`mcp` → `servers` und `mcp.servers`). Steht ein Name in beiden, zeigt der Scan
    /// die erste – geändert wird keine: Lage, nicht „Nachprüfung gescheitert“.
    @Test func refusesANamePresentInTwoServerLists() throws {
        let text = """
        {
          "mcp": { "servers": { "files": { "command": "a" } } },
          "mcp.servers": { "files": { "command": "b" } }
        }

        """
        let reference = AgentEditing.reference("files", tool: AgentEditing.vscodeSettings.tool, path: AgentEditing.vscodeSettings.path)
        #expect(throws: AgentConfigEditError.unsupportedLayout) { try AgentEditing.apply(.remove, to: text, reference) }
        let single = text.replacingOccurrences(of: "  \"mcp.servers\": { \"files\": { \"command\": \"b\" } }\n", with: "  \"mcp.servers\": {}\n")
        #expect(throws: AgentConfigEditError.unsupportedLayout) {
            try AgentEditing.editor(reference).reinsert(from: Data(single.utf8), into: Data(text.utf8))
        }
        #expect(try AgentEditing.apply(.remove, to: single, reference) == """
        {
          "mcp": { "servers": { } },
          "mcp.servers": {}
        }

        """)
    }

    /// Zwei Einfügungen an derselben Stelle landen in Array-Reihenfolge im Text.
    @Test func appliesEditsAtTheSamePositionInArrayOrder() {
        let bytes = Array("xy".utf8)
        let first = ByteEdit.insert(Array("A".utf8), at: 1)
        let second = ByteEdit.insert(Array("B".utf8), at: 1)
        #expect(String(decoding: bytes.applying([first, second]), as: UTF8.self) == "xABy")
        #expect(String(decoding: bytes.applying([second, first]), as: UTF8.self) == "xBAy")
        #expect(String(decoding: bytes.applying([.delete(0..<1), first, .insert(Array("Z".utf8), at: 2)]), as: UTF8.self) == "AyZ")
    }

    /// Ein leerer, mehrzeiliger Container bekommt den Eintrag in eigener Zeile, eine Stufe tiefer als die Klammer.
    @Test func reinsertsIntoAnEmptyMultilineContainerWithIndentation() throws {
        let text = "{\n  \"mcpServers\": {\n    \"x\": {\"command\": \"x\"}\n  }\n}\n"
        let removed = try removing("x", from: text)
        let editor = try AgentEditing.editor(AgentEditing.reference("x"))
        #expect(String(decoding: try editor.reinsert(from: Data(text.utf8), into: Data(removed.utf8)), as: UTF8.self) == text)
        let inline = #"{"mcpServers": {}}"#
        #expect(String(decoding: try editor.reinsert(from: Data(text.utf8), into: Data(inline.utf8)), as: UTF8.self)
            == #"{"mcpServers": {"x": {"command": "x"}}}"#)
    }

    @Test func handlesEscapedNamesAndBlockComments() throws {
        let text = "{\"mcp\": {\"servers\": {\n  /* eins */ \"a \\\"b\\\"\": {\"command\": \"a\"}, /* zwei */\n  \"c\": {\"command\": \"c\"}\n}}}\n"
        let reference = AgentEditing.reference("a \"b\"", tool: AgentEditing.vscodeSettings.tool, path: AgentEditing.vscodeSettings.path)
        let result = try AgentEditing.apply(.remove, to: text, reference)
        #expect(result == "{\"mcp\": {\"servers\": {\n  /* eins */ /* zwei */\n  \"c\": {\"command\": \"c\"}\n}}}\n")
    }

    /// Server aus einer Projektdatei (`.mcp.json`, Ziel über die Registerdatei): entfernbar, aber ohne Schalter in der Datei.
    @Test func editsServersInProjectFiles() throws {
        let reference = AgentEditing.reference("p", tool: AgentEditing.claudeCode.tool, path: "/Users/test/web/.mcp.json",
                                                scope: .project(path: "/Users/test/web"), registryPath: AgentEditing.home + "/.claude.json")
        let text = "{\n  \"mcpServers\": {\n    \"p\": { \"command\": \"p\" },\n    \"q\": { \"command\": \"q\" }\n  }\n}\n"
        #expect(try AgentEditing.apply(.remove, to: text, reference)
            == "{\n  \"mcpServers\": {\n    \"q\": { \"command\": \"q\" }\n  }\n}\n")
        #expect(throws: AgentConfigEditError.unsupportedLayout) { try AgentEditing.apply(.setEnabled(false), to: text, reference) }
    }
}
