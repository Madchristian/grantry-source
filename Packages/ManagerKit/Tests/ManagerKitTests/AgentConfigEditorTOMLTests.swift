import Foundation
import Testing
@testable import ManagerKit

@Suite struct AgentConfigEditorTOMLTests {
    private let config = """
    # Codex
    model = "o3"
    approval_policy = "never"

    [mcp_servers.alpha]
    command = "npx"
    args = ["-y", "alpha"]

    [mcp_servers.alpha.env]
    API_KEY = "GEHEIM"

    # Beta-Server
    [mcp_servers.beta]
    command = "beta"
    enabled = false

    [profiles.default]
    model = "o3"

    """

    private func reference(_ name: String) -> AgentServerReference {
        AgentEditing.reference(name, tool: AgentEditing.codex.tool, path: AgentEditing.codex.path)
    }

    private func apply(_ operation: AgentConfigEditor.Operation, _ name: String, to text: String) throws -> String {
        try AgentEditing.apply(operation, to: text, reference(name))
    }

    @Test func removesTableWithScatteredSubtables() throws {
        #expect(try apply(.remove, "alpha", to: config) == """
        # Codex
        model = "o3"
        approval_policy = "never"

        # Beta-Server
        [mcp_servers.beta]
        command = "beta"
        enabled = false

        [profiles.default]
        model = "o3"

        """)
    }

    @Test func keepsCommentsOutsideTheEntry() throws {
        // Der Kommentar über „beta“ steht außerhalb des Eintrags und bleibt.
        #expect(try apply(.remove, "beta", to: config) == config.replacingOccurrences(
            of: "[mcp_servers.beta]\ncommand = \"beta\"\nenabled = false\n\n", with: ""))
    }

    @Test func removesTheLastTableWithItsBlankLines() throws {
        let text = "model = \"o3\"\n\n[mcp_servers.x]\ncommand = \"x\"\n\n"
        #expect(try apply(.remove, "x", to: text) == "model = \"o3\"\n")
    }

    @Test func removesDottedKeysAndInlineTables() throws {
        let text = """
        [mcp_servers]
        gamma.command = "gamma"
        gamma.args = ["x"] # Argumente
        delta = { command = "delta" }

        [other]
        key = 1

        """
        #expect(try apply(.remove, "gamma", to: text) == text.replacingOccurrences(
            of: "gamma.command = \"gamma\"\ngamma.args = [\"x\"] # Argumente\n", with: ""))
        #expect(try apply(.remove, "delta", to: text) == text.replacingOccurrences(
            of: "delta = { command = \"delta\" }\n", with: ""))
    }

    @Test func keepsCRLFAndByteOrderMark() throws {
        let text = "\u{FEFF}a = 1\r\n\r\n[mcp_servers.x]\r\ncommand = \"x\"\r\n\r\n[mcp_servers.y]\r\ncommand = \"y\"\r\n"
        #expect(try apply(.remove, "x", to: text) == "\u{FEFF}a = 1\r\n\r\n[mcp_servers.y]\r\ncommand = \"y\"\r\n")
    }

    @Test func refusesEntriesInsideValuesOrArraysOfTables() throws {
        #expect(throws: AgentConfigEditError.unsupportedLayout) {
            try apply(.remove, "x", to: "mcp_servers = { x = { command = \"x\" } }\n")
        }
        // `[mcp_servers.x]` hinter `[[mcp_servers]]` steht im letzten Element des Arrays – Pfade kennen keine Array-Ebenen.
        let inArray = "[[mcp_servers]]\n[mcp_servers.x]\ncommand = \"x\"\n"
        #expect(throws: AgentConfigEditError.unsupportedLayout) { try apply(.remove, "x", to: inArray) }
        #expect(throws: AgentConfigEditError.unsupportedLayout) { try apply(.setEnabled(false), "x", to: inArray) }
        #expect(throws: AgentConfigEditError.unsupportedLayout) {
            try AgentEditing.editor(reference("x")).reinsert(from: Data("[mcp_servers.x]\ncommand = \"x\"\n".utf8), into: Data(inArray.utf8))
        }
    }

    @Test func switchesTheEnabledField() throws {
        #expect(try apply(.setEnabled(true), "beta", to: config)
            == config.replacingOccurrences(of: "enabled = false", with: "enabled = true"))
        #expect(try apply(.setEnabled(false), "alpha", to: config)
            == config.replacingOccurrences(of: "[mcp_servers.alpha]\n", with: "[mcp_servers.alpha]\nenabled = false\n"))
        #expect(throws: AgentConfigEditError.alreadyInState) { try apply(.setEnabled(true), "alpha", to: config) }
    }

    @Test func switchesDottedAndInlineEntries() throws {
        let text = "[mcp_servers]\n  gamma.command = \"gamma\"\n  gamma.args = [\"x\"]\nepsilon = { command = \"e\" }\nzeta = {command = \"z\", enabled = false}\n"
        #expect(try apply(.setEnabled(false), "gamma", to: text)
            == text.replacingOccurrences(of: "gamma.args = [\"x\"]\n", with: "gamma.args = [\"x\"]\n  gamma.enabled = false\n"))
        #expect(try apply(.setEnabled(false), "epsilon", to: text)
            == text.replacingOccurrences(of: "{ command = \"e\" }", with: "{ command = \"e\", enabled = false }"))
        // Ein Schalter innerhalb einer Inline-Tabelle steht nicht als eigene Zeile – nicht gezielt änderbar.
        #expect(throws: AgentConfigEditError.unsupportedLayout) { try apply(.setEnabled(true), "zeta", to: text) }
    }

    @Test func reinsertsTablesAtTheEndOfAChangedFile() throws {
        let removed = try apply(.remove, "alpha", to: config)
        let changed = removed.replacingOccurrences(of: "model = \"o3\"\napproval", with: "model = \"o4\"\napproval")
        let editor = try AgentEditing.editor(reference("alpha"))
        let restored = String(decoding: try editor.reinsert(from: Data(config.utf8), into: Data(changed.utf8)), as: UTF8.self)
        #expect(restored == changed + "\n[mcp_servers.alpha]\ncommand = \"npx\"\nargs = [\"-y\", \"alpha\"]\n\n[mcp_servers.alpha.env]\nAPI_KEY = \"GEHEIM\"\n")
    }

    @Test func reinsertsDottedKeysIntoTheirTable() throws {
        let text = "[mcp_servers]\ngamma.command = \"gamma\"\ndelta = { command = \"delta\" }\n\n[other]\nkey = 1\n"
        let removed = try apply(.remove, "gamma", to: text)
        let editor = try AgentEditing.editor(reference("gamma"))
        let restored = String(decoding: try editor.reinsert(from: Data(text.utf8), into: Data(removed.utf8)), as: UTF8.self)
        #expect(restored == "[mcp_servers]\ndelta = { command = \"delta\" }\ngamma.command = \"gamma\"\n\n[other]\nkey = 1\n")
    }

    /// Punktierter Schlüssel auf oberster Ebene und Untertabelle: Die Zeile kommt vor den ersten Kopf (hier ans Ende einer
    /// Datei ohne Kopf), der Block dahinter – beides an derselben Stelle, in der richtigen Reihenfolge.
    @Test func reinsertsTopLevelDottedKeysBeforeTheirSubtable() throws {
        let backup = "model = \"o3\"\nmcp_servers.x.command = \"x\"\n\n[mcp_servers.x.env]\nA = \"1\"\n"
        let editor = try AgentEditing.editor(reference("x"))
        #expect(try apply(.remove, "x", to: backup) == "model = \"o3\"\n")
        let restored = String(decoding: try editor.reinsert(from: Data(backup.utf8), into: Data("model = \"o4\"\n".utf8)), as: UTF8.self)
        #expect(restored == "model = \"o4\"\nmcp_servers.x.command = \"x\"\n\n[mcp_servers.x.env]\nA = \"1\"\n")
    }

    /// „Schon wiederhergestellt“ nur bei byte-gleichem Eintrag – Geheimwerte sieht der Baum nur geschwärzt.
    @Test func reinsertComparesTheEntryByteForByte() throws {
        let editor = try AgentEditing.editor(reference("alpha"))
        #expect(throws: AgentConfigEditError.alreadyInState) {
            try editor.reinsert(from: Data(config.utf8), into: Data(config.replacingOccurrences(of: "o3", with: "o4").utf8))
        }
        #expect(throws: AgentConfigEditError.nameTaken) {
            try editor.reinsert(from: Data(config.utf8), into: Data(config.replacingOccurrences(of: "GEHEIM", with: "ANDERS").utf8))
        }
    }

    /// Regression (Codex-Review zu #155, Folge): Die Schalter-Wiederherstellung vergleicht die unmaskierten
    /// Transportwerte – `?server=alpha` und `?server=beta` sind maskiert gleich (`server=•••`), ebenso `--token abc`
    /// und `--token xyz`. Ein anderer Server unter dem Namen: `nameTaken`; derselbe: der Schalter wird zurückgestellt.
    @Test(arguments: [
        (backup: "url = \"https://gateway.example/mcp?server=alpha\"", replaced: "url = \"https://gateway.example/mcp?server=beta\""),
        (backup: "command = \"npx\"\nargs = [\"--token\", \"abc\"]", replaced: "command = \"npx\"\nargs = [\"--token\", \"xyz\"]"),
    ])
    func revertSwitchComparesTheUnmaskedTransport(backup: String, replaced: String) throws {
        let editor = try AgentEditing.editor(reference("gw"))
        let original = Data("[mcp_servers.gw]\n\(backup)\n".utf8)
        #expect(throws: AgentConfigEditError.nameTaken) {
            _ = try editor.revertSwitch(to: true, from: original, into: Data("[mcp_servers.gw]\n\(replaced)\nenabled = false\n".utf8))
        }
        let restored = try editor.revertSwitch(to: true, from: original, into: Data("[mcp_servers.gw]\n\(backup)\nenabled = false\n".utf8))
        #expect(String(decoding: restored, as: UTF8.self) == "[mcp_servers.gw]\n\(backup)\nenabled = true\n")
    }

    private func reinserting(_ name: String, from backup: String, into text: String) throws -> String {
        String(decoding: try AgentEditing.editor(reference(name)).reinsert(from: Data(backup.utf8), into: Data(text.utf8)), as: UTF8.self)
    }

    @Test func handlesQuotedNames() throws {
        let text = "[mcp_servers.\"my server\"]\ncommand = \"m\"\n\n[mcp_servers]\n\"a.b\".command = \"ab\"\n"
        #expect(try apply(.remove, "my server", to: text) == "[mcp_servers]\n\"a.b\".command = \"ab\"\n")
        #expect(try apply(.remove, "a.b", to: text) == "[mcp_servers.\"my server\"]\ncommand = \"m\"\n\n[mcp_servers]\n")
        #expect(try apply(.setEnabled(false), "a.b", to: text) == text + "\"a.b\".enabled = false\n")
        #expect(try apply(.setEnabled(false), "my server", to: text)
            == text.replacingOccurrences(of: "\"]\ncommand", with: "\"]\nenabled = false\ncommand"))
    }

    @Test func handlesASubtableBeforeItsMainTable() throws {
        let text = "[mcp_servers.x.env]\nK = \"GEHEIM\"\n\n[mcp_servers.x]\ncommand = \"x\"\n\n[other]\na = 1\n"
        #expect(try apply(.remove, "x", to: text) == "[other]\na = 1\n")
        #expect(try apply(.setEnabled(false), "x", to: text)
            == text.replacingOccurrences(of: "[mcp_servers.x]\n", with: "[mcp_servers.x]\nenabled = false\n"))
    }

    @Test func handlesMixedFormsOfOneEntry() throws {
        let text = "[mcp_servers]\nx.command = \"x\"\ny = { command = \"y\" }\n\n[mcp_servers.x.env]\nK = \"GEHEIM\"\n"
        #expect(try apply(.remove, "x", to: text) == "[mcp_servers]\ny = { command = \"y\" }\n")
        #expect(try apply(.setEnabled(false), "x", to: text)
            == text.replacingOccurrences(of: "x.command = \"x\"\n", with: "x.command = \"x\"\nx.enabled = false\n"))
    }

    @Test func switchesWithCRLFAndIndentedHeaders() throws {
        let crlf = "[mcp_servers.x]\r\ncommand = \"x\"\r\n"
        #expect(try apply(.setEnabled(false), "x", to: crlf) == "[mcp_servers.x]\r\nenabled = false\r\ncommand = \"x\"\r\n")
        let indented = "  [mcp_servers.x]\n    command = \"x\"\n"
        #expect(try apply(.setEnabled(false), "x", to: indented) == "  [mcp_servers.x]\n    enabled = false\n    command = \"x\"\n")
    }

    /// Kein doppelter Abstand am Ende und keine Leerzeile am Anfang einer leeren Datei.
    @Test func reinsertsBlocksWithoutExtraBlankLines() throws {
        let backup = "[mcp_servers.x]\ncommand = \"x\"\n"
        #expect(try reinserting("x", from: backup, into: "") == backup)
        #expect(try reinserting("x", from: backup, into: "a = 1\n\n") == "a = 1\n\n" + backup)
        #expect(try reinserting("x", from: backup, into: "a = 1\n") == "a = 1\n\n" + backup)
        #expect(try reinserting("x", from: backup, into: "a = 1") == "a = 1\n\n" + backup)
    }
}
