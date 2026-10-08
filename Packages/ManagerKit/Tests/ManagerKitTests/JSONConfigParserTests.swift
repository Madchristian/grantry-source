import Foundation
import Testing
@testable import ManagerKit

@Suite struct JSONConfigParserTests {
    private func parse(_ text: String, _ syntax: ConfigSyntax = .json, redacting keys: Set<String> = []) throws -> ConfigValue {
        try ConfigParsing.parse(Data(text.utf8), syntax: syntax, redaction: ConfigRedaction(keys: keys))
    }

    @Test func parsesNestedDocumentInOrder() throws {
        let value = try parse(#"{"b": 1, "a": {"x": [true, null, "s\u00e4\n"], "y": -1.5e3}}"#)
        let root = try #require(value.object)
        #expect(root.keys == ["b", "a"])
        #expect(root["b"] == .number("1"))
        #expect(value.value(at: ["a", "x"]) == .array([.bool(true), .null, .string("sä\n")]))
        #expect(value.value(at: ["a", "y"]) == .number("-1.5e3"))
    }

    @Test func lastDuplicateKeyWins() throws {
        let value = try parse(#"{"a": 1, "a": 2}"#)
        #expect(value.value(at: ["a"]) == .number("2"))
        #expect(value.object?.keys == ["a"])
    }

    @Test func decodesSurrogatePairs() throws {
        #expect(try parse(#""\ud83d\ude00""#) == .string("😀"))
    }

    @Test func skipsByteOrderMark() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("{}".utf8))
        #expect(try ConfigParsing.parse(data, syntax: .json, redaction: .none) == .object(ConfigObject()))
    }

    @Test func strictJSONRejectsCommentsAndTrailingCommas() {
        #expect(throws: ConfigParseError.self) { try parse("{\n// x\n}") }
        #expect(throws: ConfigParseError.self) { try parse(#"{"a": 1,}"#) }
    }

    @Test func jsoncAcceptsCommentsAndTrailingCommas() throws {
        let text = """
        // Kopf
        {
          /* Block */ "a": [1, 2,], // Rest
          "b": "//kein Kommentar",
        }
        """
        let value = try parse(text, .jsonc)
        #expect(value.value(at: ["a"]) == .array([.number("1"), .number("2")]))
        #expect(value.value(at: ["b"]) == .string("//kein Kommentar"))
    }

    @Test func reportsLineOfError() {
        #expect(throws: ConfigParseError(line: 3, reason: "„,“ oder „}“ erwartet")) {
            try parse("{\n\"a\": 1\n\"b\": 2}")
        }
    }

    @Test func rejectsUnterminatedString() {
        #expect(throws: ConfigParseError.self) { try parse(#"{"a": "x"#) }
    }

    @Test func rejectsControlCharacterInString() {
        #expect(throws: ConfigParseError.self) { try parse("\"a\u{01}\"") }
    }

    @Test func rejectsTrailingGarbageAfterDocument() {
        #expect(throws: ConfigParseError.self) { try parse("{} x") }
    }

    @Test func rejectsLeadingZero() {
        #expect(throws: ConfigParseError.self) { try parse("01") }
    }

    @Test func rejectsMalformedNumbers() {
        for text in ["-", "1.", ".5", "+1", "1e", "1e+", "--1"] {
            #expect(throws: ConfigParseError.self, "Eingabe \(text)") { try parse(text) }
        }
    }

    @Test func rejectsInvalidEscape() {
        #expect(throws: ConfigParseError.self) { try parse(#""\x""#) }
        #expect(throws: ConfigParseError.self) { try parse(#""\u12""#) }
    }

    @Test func rejectsUnterminatedBlockComment() {
        #expect(throws: ConfigParseError.self) { try parse("{} /* offen", .jsonc) }
    }

    @Test func rejectsDoubleCommaEvenInJSONC() {
        #expect(throws: ConfigParseError.self) { try parse("[1,,]", .jsonc) }
        #expect(throws: ConfigParseError.self) { try parse(#"{"a": 1,,}"#, .jsonc) }
    }

    @Test func reportsLineOfRawNewlineInString() {
        // Der Zeilenumbruch steht in Zeile 2 – dort beginnt der String, dort muss der Fehler gemeldet werden.
        #expect(throws: ConfigParseError(line: 2, reason: "Steuerzeichen im String")) {
            try parse("{\n\"a\": \"x\ny\"}")
        }
    }

    @Test func loneSurrogateBecomesReplacementCharacter() throws {
        #expect(try parse(#""\ud83d""#) == .string("\u{FFFD}"))
        #expect(try parse(#""\ude00""#) == .string("\u{FFFD}"))
    }

    @Test func highSurrogateKeepsFollowingText() throws {
        #expect(try parse(#""\ud83dAB""#) == .string("\u{FFFD}AB"))
        #expect(try parse(#""\ud83d😀""#) == .string("\u{FFFD}😀"))
    }

    @Test func highSurrogateKeepsFollowingEscape() throws {
        // Das zweite Escape ist kein Low-Surrogat und darf nicht verschluckt werden.
        #expect(try parse(#""\ud83d\u0041B""#) == .string("\u{FFFD}AB"))
        // Folgt ein weiteres hohes Surrogat, bildet es mit dem Low-Surrogat danach ein gültiges Paar.
        #expect(try parse(#""\ud83d\ud83d\ude00""#) == .string("\u{FFFD}😀"))
    }

    @Test func rejectsExcessiveNesting() {
        let deep = String(repeating: "[", count: 300) + String(repeating: "]", count: 300)
        #expect(throws: ConfigParseError.self) { try parse(deep) }
    }

    @Test func acceptsNestingUpToTheLimitOnly() throws {
        let limit = JSONConfigParser.maximumDepth
        _ = try parse(String(repeating: "[", count: limit) + String(repeating: "]", count: limit))
        #expect(throws: ConfigParseError.self) {
            try parse(String(repeating: "[", count: limit + 1) + String(repeating: "]", count: limit + 1))
        }
    }

    @Test func redactedKeysKeepNamesButDropValues() throws {
        let text = #"{"env": {"API_KEY": "GEHEIM-123", "N": {"deep": "GEHEIM-456"}}, "headers": "GEHEIM-789", "args": ["ok"]}"#
        let value = try parse(text, redacting: ["env", "headers"])
        #expect(value.value(at: ["env"])?.object?.keys == ["API_KEY", "N"])
        #expect(value.value(at: ["env", "API_KEY"]) == .redacted)
        #expect(value.value(at: ["env", "N", "deep"]) == .redacted)
        #expect(value.value(at: ["headers"]) == .redacted)
        #expect(value.value(at: ["args"]) == .array([.string("ok")]))
        #expect(!String(describing: value).contains("GEHEIM"))
    }

    @Test func redactionAppliesToNestedServerTables() throws {
        let text = #"{"mcpServers": {"x": {"command": "npx", "env": {"TOKEN": "GEHEIM-1", "N": ["GEHEIM-2"]}}}}"#
        let value = try parse(text, redacting: ["env"])
        #expect(value.value(at: ["mcpServers", "x", "command"]) == .string("npx"))
        #expect(value.value(at: ["mcpServers", "x", "env"])?.object?.keys == ["TOKEN", "N"])
        #expect(value.value(at: ["mcpServers", "x", "env", "TOKEN"]) == .redacted)
        #expect(value.value(at: ["mcpServers", "x", "env", "N"]) == .redacted)
        #expect(!String(describing: value).contains("GEHEIM"))
    }

    @Test func serverNamedLikeARedactedKeyStaysReadable() throws {
        let text = #"{"mcpServers": {"env": {"command": "/tmp/x", "env": {"K": "GEHEIM-1"}}}, "env": {"T": "GEHEIM-2"}}"#
        let redaction = ConfigRedaction(keys: ["env"], exemptParents: [["mcpServers"]])
        let value = try ConfigParsing.parse(Data(text.utf8), syntax: .json, redaction: redaction)
        #expect(value.value(at: ["mcpServers", "env", "command"]) == .string("/tmp/x"))
        #expect(value.value(at: ["mcpServers", "env", "env"])?.object?.keys == ["K"])
        #expect(value.value(at: ["mcpServers", "env", "env", "K"]) == .redacted)
        #expect(value.value(at: ["env", "T"]) == .redacted)
        #expect(!String(describing: value).contains("GEHEIM"))
    }

    @Test func wildcardMatchesObjectKeysButNotArrayElements() throws {
        let redaction = ConfigRedaction(keys: ["env"], exemptParents: [["projects", "*", "mcpServers"]])
        let text = #"""
        {"projects": {"/p": {"mcpServers": {"env": {"command": "c"}}, "env": "GEHEIM-1"}},
         "liste": [{"mcpServers": {"env": "GEHEIM-2"}}], "mcpServers": {"env": "GEHEIM-3"}}
        """#
        let value = try ConfigParsing.parse(Data(text.utf8), syntax: .json, redaction: redaction)
        #expect(value.value(at: ["projects", "/p", "mcpServers", "env", "command"]) == .string("c"))
        #expect(value.value(at: ["projects", "/p", "env"]) == .redacted)
        #expect(value.value(at: ["mcpServers", "env"]) == .redacted)
        #expect(!String(describing: value).contains("GEHEIM"))
        let arrays = #"{"projects": [{"mcpServers": {"env": "GEHEIM-4"}}]}"#
        #expect(!String(describing: try ConfigParsing.parse(Data(arrays.utf8), syntax: .json, redaction: redaction))
            .contains("GEHEIM"))
    }

    @Test func redactionAppliesInsideArrays() throws {
        let text = #"[{"url": "https://example.test", "headers": {"Authorization": "GEHEIM-3"}}, {"headers": "GEHEIM-4"}]"#
        let value = try parse(text, redacting: ["headers"])
        let elements = try #require(value.array)
        #expect(elements.count == 2)
        #expect(elements[0].value(at: ["url"]) == .string("https://example.test"))
        #expect(elements[0].value(at: ["headers", "Authorization"]) == .redacted)
        #expect(elements[1].value(at: ["headers"]) == .redacted)
        #expect(!String(describing: value).contains("GEHEIM"))
    }

    @Test func syntaxErrorInsideRedactedValueDoesNotLeakContent() {
        let documents = [
            #"{"env": {"K": "GEHEIM-5" "L": 1}}"#,
            #"{"env": {"K": "GEHEIM-6\x"}}"#,
            #"{"headers": ["GEHEIM-7", }"#,
            #"{"env": "GEHEIM-8"#,
        ]
        for text in documents {
            do {
                _ = try parse(text, redacting: ["env", "headers"])
                Issue.record("Syntaxfehler erwartet: \(text)")
            } catch {
                #expect(!String(describing: error).contains("GEHEIM"))
            }
        }
    }
}
