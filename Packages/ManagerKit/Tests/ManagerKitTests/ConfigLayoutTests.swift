import Foundation
import Testing
@testable import ManagerKit

@Suite struct ConfigLayoutTests {
    private func document(_ text: String, _ syntax: ConfigSyntax, containers: Set<[String]> = []) throws -> ConfigDocument {
        try ConfigDocument(bytes: Array(text.utf8), syntax: syntax, redaction: .agentConfig(serverPaths: [["s"]]), containers: containers)
    }

    private func text(_ document: ConfigDocument, _ range: Range<Int>) -> String {
        String(decoding: document.bytes[range], as: UTF8.self)
    }

    @Test func recordsRequestedJSONContainersWithCommas() throws {
        let source = #"{"s": {"a": 1, "b": {"env": {"K": "GEHEIM"}}}, "l": ["x", "y"]}"#
        let document = try document(source, .json, containers: [["s"], ["l"]])
        guard case .json(let layout) = document.layout else { Issue.record("kein JSON"); return }
        let servers = try #require(layout.containers[["s"]]?.first)
        #expect(text(document, servers.open..<servers.close + 1).hasPrefix("{\"a\""))
        #expect(servers.items.map { text(document, $0.start..<$0.end) } == [#""a": 1"#, #""b": {"env": {"K": "GEHEIM"}}"#])
        #expect(servers.items.map { $0.comma != nil } == [true, false])
        #expect(text(document, servers.items[0].valueStart..<servers.items[0].end) == "1")
        let list = try #require(layout.containers[["l"]]?.first)
        #expect(list.items.map { text(document, $0.start..<$0.end) } == [#""x""#, #""y""#])
        #expect(layout.containers[["s", "b"]] == nil)
        // Die Lage ändert nichts an der Schwärzung.
        #expect(document.tree.value(at: ["s", "b", "env", "K"]) == .redacted)
    }

    @Test func recordsTrailingCommaAndDuplicatesInJSONC() throws {
        let document = try document("{\"s\": {\"a\": 1, \"a\": 2,}, \"s\": {}}", .jsonc, containers: [["s"]])
        guard case .json(let layout) = document.layout else { Issue.record("kein JSON"); return }
        let spans = try #require(layout.containers[["s"]])
        #expect(spans.count == 2)
        #expect(spans[0].items.count == 2 && spans[0].items[1].comma != nil)
        #expect(spans[1].items.isEmpty)
    }

    @Test func recordsTOMLStatementsWithLinesAndValues() throws {
        let source = "a = 1 # c\n\n  [s.x]\ncommand = \"x\"\r\n[s.x.env]\nK = \"\"\"\nGEHEIM\n\"\"\"\n[[t]]\nb.c = { d = 1 }"
        let document = try document(source, .toml)
        guard case .toml(let layout) = document.layout else { Issue.record("kein TOML"); return }
        let statements = layout.statements
        #expect(statements.map(\.kind) == [.keyValue, .table, .keyValue, .table, .keyValue, .arrayTable, .keyValue])
        #expect(statements.map(\.path) == [["a"], ["s", "x"], ["s", "x", "command"], ["s", "x", "env"], ["s", "x", "env", "K"],
                                           ["t"], ["t", "b", "c"]])
        #expect(statements.map(\.tablePath) == [[], ["s", "x"], ["s", "x"], ["s", "x", "env"], ["s", "x", "env"], ["t"], ["t"]])
        #expect(text(document, statements[0].range) == "a = 1 # c\n")
        #expect(text(document, statements[1].range) == "  [s.x]\n")
        #expect(text(document, statements[2].range) == "command = \"x\"\r\n")
        #expect(text(document, statements[4].range) == "K = \"\"\"\nGEHEIM\n\"\"\"\n")
        #expect(text(document, try #require(statements[6].valueRange)) == "{ d = 1 }")
        #expect(document.tree.value(at: ["s", "x", "env", "K"]) == .redacted)
    }

    @Test func scanParsingRecordsNothing() throws {
        var parser = TOMLConfigParser(bytes: Array("[a]\nb = 1\n".utf8), redaction: .none)
        _ = try parser.parseDocument()
        #expect(parser.layout.statements.isEmpty)
        var json = JSONConfigParser(bytes: Array(#"{"s": {"a": 1}}"#.utf8), allowsExtensions: false, redaction: .none)
        _ = try json.parseDocument()
        #expect(json.layout.containers.isEmpty)
    }

    private func jsonLayout(_ document: ConfigDocument) throws -> JSONLayout {
        guard case .json(let layout) = document.layout else { throw LayoutMismatch() }
        return layout
    }

    private func tomlStatements(_ document: ConfigDocument) throws -> [TOMLStatement] {
        guard case .toml(let layout) = document.layout else { throw LayoutMismatch() }
        return layout.statements
    }

    private struct LayoutMismatch: Error {}

    @Test func recordsExactBracketsOfRootAndNestedContainers() throws {
        let source = #"{"s": {"b": {"c": []}}}"#
        let document = try document(source, .json, containers: [[], ["s"], ["s", "b"], ["s", "b", "c"]])
        let layout = try jsonLayout(document)
        let root = try #require(layout.containers[[]]?.first)
        #expect(root.open == 0 && root.close == source.utf8.count - 1)
        let servers = try #require(layout.containers[["s"]]?.first)
        #expect(text(document, servers.open..<servers.open + 1) == "{" && text(document, servers.close..<servers.close + 1) == "}")
        #expect(text(document, servers.open..<servers.close + 1) == #"{"b": {"c": []}}"#)
        let nested = try #require(layout.containers[["s", "b"]]?.first)
        #expect(text(document, nested.open..<nested.close + 1) == #"{"c": []}"#)
        let empty = try #require(layout.containers[["s", "b", "c"]]?.first)
        #expect(empty.items.isEmpty && text(document, empty.open..<empty.close + 1) == "[]")
    }

    @Test func recordsPositionsAcrossCommentsCRLFMultibyteAndEscapedKeys() throws {
        let source = "{\r\n  // Kommentar mit ü\r\n  \"s\": { /* ä */ \"\\u00fc\\\"x\": \"Grüße\" , \"b\": 2 },\r\n}"
        let document = try document(source, .jsonc, containers: [["s"]])
        let servers = try #require(try jsonLayout(document).containers[["s"]]?.first)
        #expect(servers.items.map { text(document, $0.start..<$0.end) } == [#""\u00fc\"x": "Grüße""#, #""b": 2"#])
        #expect(text(document, servers.items[0].valueStart..<servers.items[0].end) == "\"Grüße\"")
        #expect(servers.items[0].comma.map { text(document, $0..<$0 + 1) } == ",")
        #expect(document.tree.value(at: ["s"])?.object?.keys == ["ü\"x", "b"])
    }

    @Test func recordsNothingUnderArraysOrForNonContainers() throws {
        let source = #"{"l": [{"s": {"a": 1}}], "s": 5, "t": {"u": 1}}"#
        let layout = try jsonLayout(try document(source, .json, containers: [["s"], ["l", "s"], ["t", "u"]]))
        #expect(layout.containers.isEmpty)
    }

    /// Ausnahme laut Doc: Die Lage nennt die Elemente eines geschwärzten Arrays, der Baum nur `.redacted`.
    @Test func recordsRedactedArraysWithoutValuesInTheTree() throws {
        let document = try document(#"{"s": {"x": {"env": ["A", "B"]}}}"#, .json, containers: [["s", "x", "env"]])
        let list = try #require(try jsonLayout(document).containers[["s", "x", "env"]]?.first)
        #expect(list.items.count == 2)
        #expect(document.tree.value(at: ["s", "x", "env"]) == .redacted)
    }

    @Test func recordsTOMLEdgeCases() throws {
        let source = "mcp_servers.x.command = \"x\"\n[s.y] # Kopf\r\n    args = [\n  \"a\", # eins\n  \"b\",\n]\nlast = 1"
        let document = try document(source, .toml)
        let statements = try tomlStatements(document)
        #expect(statements.map(\.kind) == [.keyValue, .table, .keyValue, .keyValue])
        #expect(statements[0].path == ["mcp_servers", "x", "command"] && statements[0].tablePath.isEmpty)
        #expect(text(document, statements[1].range) == "[s.y] # Kopf\r\n")
        #expect(text(document, statements[2].range) == "    args = [\n  \"a\", # eins\n  \"b\",\n]\n")
        #expect(text(document, try #require(statements[2].valueRange)) == "[\n  \"a\", # eins\n  \"b\",\n]")
        // Letzte Zeile ohne Zeilenende: bis zum Dateiende.
        #expect(statements[3].range.upperBound == source.utf8.count)
        #expect(text(document, statements[3].range) == "last = 1")
    }

    /// Array-Ebenen fehlen in Pfaden: `[s.x]` hinter `[[s]]` sieht aus wie eine gewöhnliche Tabelle.
    @Test func dropsArrayLevelsFromTOMLPaths() throws {
        let statements = try tomlStatements(try document("[[s]]\n[s.x]\na = 1\n", .toml))
        #expect(statements.map(\.kind) == [.arrayTable, .table, .keyValue])
        #expect(statements.map(\.tablePath) == [["s"], ["s", "x"], ["s", "x"]])
    }

    @Test func describesDocumentsWithoutContent() throws {
        let document = try document(#"{"s": {"x": {"env": {"K": "GEHEIM"}}}}"#, .json)
        for text in [String(describing: document), String(reflecting: document), dumped(document)] {
            #expect(!text.contains("GEHEIM"))
        }
    }

    private func dumped(_ value: some Any) -> String {
        var text = ""
        dump(value, to: &text)
        return text
    }
}
