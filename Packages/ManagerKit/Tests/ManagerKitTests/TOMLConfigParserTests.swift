import Foundation
import Testing
@testable import ManagerKit

@Suite struct TOMLConfigParserTests {
    private func parse(_ text: String, redacting keys: Set<String> = []) throws -> ConfigValue {
        try ConfigParsing.parse(Data(text.utf8), syntax: .toml, redaction: ConfigRedaction(keys: keys))
    }

    @Test func parsesCodexStyleConfig() throws {
        let text = """
        model = "gpt-5" # Kommentar
        approval_policy = 'never'

        [mcp_servers.filesystem]
        command = "npx"
        args = ["-y", "@modelcontextprotocol/server-filesystem", "~/"]
        enabled = false
        startup_timeout_sec = 20

        [mcp_servers."team-chat".env]
        CHAT_TOKEN = "GEHEIM-1"

        [mcp_servers.remote]
        url = "https://example.com/mcp"
        http_headers = { Authorization = "GEHEIM-2" }
        """
        let value = try parse(text, redacting: ["env", "http_headers"])
        #expect(value.value(at: ["approval_policy"]) == .string("never"))
        let servers = try #require(value.value(at: ["mcp_servers"])?.object)
        #expect(servers.keys == ["filesystem", "team-chat", "remote"])
        #expect(value.value(at: ["mcp_servers", "filesystem", "args"])
            == .array([.string("-y"), .string("@modelcontextprotocol/server-filesystem"), .string("~/")]))
        #expect(value.value(at: ["mcp_servers", "filesystem", "enabled"]) == .bool(false))
        #expect(value.value(at: ["mcp_servers", "filesystem", "startup_timeout_sec"]) == .number("20"))
        #expect(value.value(at: ["mcp_servers", "team-chat", "env"])?.object?.keys == ["CHAT_TOKEN"])
        #expect(value.value(at: ["mcp_servers", "team-chat", "env", "CHAT_TOKEN"]) == .redacted)
        #expect(value.value(at: ["mcp_servers", "remote", "http_headers"])?.object?.keys == ["Authorization"])
        #expect(!String(describing: value).contains("GEHEIM"))
    }

    @Test func dottedKeysAndInlineTables() throws {
        let value = try parse(#"a.b.c = 1"# + "\n" + #"d = { e = [1, 2], f = { g = true } }"#)
        #expect(value.value(at: ["a", "b", "c"]) == .number("1"))
        #expect(value.value(at: ["d", "f", "g"]) == .bool(true))
    }

    @Test func dottedEnvKeyIsRedacted() throws {
        let value = try parse(#"[mcp_servers.x]"# + "\n" + #"env.TOKEN = "GEHEIM""#, redacting: ["env"])
        #expect(value.value(at: ["mcp_servers", "x", "env", "TOKEN"]) == .redacted)
    }

    @Test func serverNamedLikeARedactedKeyStaysReadable() throws {
        let text = """
        [env]
        T = "GEHEIM-1"

        [mcp_servers.env]
        command = "/tmp/x"

        [mcp_servers.env.env]
        K = "GEHEIM-2"

        [mcp_servers.inline]
        env = { L = "GEHEIM-3" }
        """
        let redaction = ConfigRedaction(keys: ["env"], exemptParents: [["mcp_servers"]])
        let value = try ConfigParsing.parse(Data(text.utf8), syntax: .toml, redaction: redaction)
        #expect(value.value(at: ["mcp_servers", "env", "command"]) == .string("/tmp/x"))
        #expect(value.value(at: ["mcp_servers", "env", "env"])?.object?.keys == ["K"])
        #expect(value.value(at: ["mcp_servers", "env", "env", "K"]) == .redacted)
        #expect(value.value(at: ["env", "T"]) == .redacted)
        #expect(!String(describing: value).contains("GEHEIM"))
    }

    @Test func exemptionDoesNotReachIntoArrays() throws {
        let redaction = ConfigRedaction(keys: ["env"], exemptParents: [["mcp_servers"]])
        let documents = [
            "[[mcp_servers]]\nenv = { K = \"GEHEIM-1\" }\n",
            "[[mcp_servers]]\n[mcp_servers.env]\nK = \"GEHEIM-2\"\n",
            "mcp_servers = [{ env = \"GEHEIM-3\" }]\n",
        ]
        for text in documents {
            let value = try ConfigParsing.parse(Data(text.utf8), syntax: .toml, redaction: redaction)
            #expect(!String(describing: value).contains("GEHEIM"), "\(text)")
        }
    }

    @Test func strings() throws {
        let text = #"""
        basic = "a\tb\u00e4\U0001F600"
        literal = 'C:\pfad'
        multi = """
        eins \
          zwei"""
        lit = '''
        roh\n'''
        """#
        let value = try parse(text)
        #expect(value.value(at: ["basic"]) == .string("a\tbä😀"))
        #expect(value.value(at: ["literal"]) == .string(#"C:\pfad"#))
        #expect(value.value(at: ["multi"]) == .string("eins zwei"))
        #expect(value.value(at: ["lit"]) == .string(#"roh\n"#))
    }

    @Test func numbersDatesAndMultilineArrays() throws {
        let text = """
        a = -1_000
        b = 0xFF
        c = 3.14e-2
        d = inf
        e = 1979-05-27T07:32:00Z
        f = 1979-05-27 07:32:00
        g = [
          "x", # Kommentar
          "y",
        ]
        """
        let value = try parse(text)
        #expect(value.value(at: ["a"]) == .number("-1_000"))
        #expect(value.value(at: ["b"]) == .number("0xFF"))
        #expect(value.value(at: ["c"]) == .number("3.14e-2"))
        #expect(value.value(at: ["d"]) == .number("inf"))
        #expect(value.value(at: ["e"]) == .string("1979-05-27T07:32:00Z"))
        #expect(value.value(at: ["f"]) == .string("1979-05-27 07:32:00"))
        #expect(value.value(at: ["g"]) == .array([.string("x"), .string("y")]))
    }

    @Test func arrayOfTables() throws {
        let value = try parse("[[p]]\nn = 1\n[[p]]\nn = 2\n[p.sub]\nx = 3")
        let list = try #require(value.value(at: ["p"])?.array)
        #expect(list.count == 2)
        #expect(list[1].value(at: ["sub", "x"]) == .number("3"))
    }

    @Test func rejectsDuplicatesAndGarbage() {
        #expect(throws: ConfigParseError.self) { try parse("a = 1\na = 2") }
        #expect(throws: ConfigParseError.self) { try parse("[t]\n[t]") }
        #expect(throws: ConfigParseError.self) { try parse("a = 1 b = 2") }
        #expect(throws: ConfigParseError.self) { try parse("a = \"offen") }
        #expect(throws: ConfigParseError.self) { try parse("= 1") }
        #expect(throws: ConfigParseError(line: 2, reason: "Wert erwartet")) { try parse("a = 1\nb =") }
    }

    @Test func rejectsInvalidBareValues() {
        #expect(throws: ConfigParseError.self) { try parse("a = nope") }
        #expect(throws: ConfigParseError.self) { try parse("a = truthy") }
        #expect(throws: ConfigParseError.self) { try parse("a = -x") }
        #expect(throws: ConfigParseError.self) { try parse("a = 12abc!") }
    }

    @Test func parsesSignedSpecialFloats() throws {
        let value = try parse("a = +inf\nb = -inf\nc = nan\nd = -nan")
        #expect(value.value(at: ["a"]) == .number("+inf"))
        #expect(value.value(at: ["b"]) == .number("-inf"))
        #expect(value.value(at: ["c"]) == .number("nan"))
        #expect(value.value(at: ["d"]) == .number("-nan"))
    }

    @Test func toleratesWindowsLineEndings() throws {
        let value = try parse("a = 1\r\n\r\n[t]\r\nb = \"x\" # k\r\n")
        #expect(value.value(at: ["a"]) == .number("1"))
        #expect(value.value(at: ["t", "b"]) == .string("x"))
    }

    // MARK: Tiefe

    @Test func rejectsExcessiveNesting() {
        let deepArray = "a = " + String(repeating: "[", count: 300) + String(repeating: "]", count: 300)
        #expect(throws: ConfigParseError.self) { try parse(deepArray) }
        let deepTable = "a = " + String(repeating: "{ a = ", count: 300) + "1" + String(repeating: " }", count: 300)
        #expect(throws: ConfigParseError.self) { try parse(deepTable) }
    }

    @Test func acceptsNestingUpToTheLimitOnly() throws {
        let limit = TOMLConfigParser.maximumDepth
        _ = try parse("a = " + String(repeating: "[", count: limit) + String(repeating: "]", count: limit))
        #expect(throws: ConfigParseError.self) {
            try parse("a = " + String(repeating: "[", count: limit + 1) + String(repeating: "]", count: limit + 1))
        }
    }

    @Test func rejectsExcessivelyLongKeyPaths() {
        let longKey = Array(repeating: "k", count: 5_000).joined(separator: ".")
        #expect(throws: ConfigParseError.self) { try parse("\(longKey) = 1") }
        #expect(throws: ConfigParseError.self) { try parse("[\(longKey)]") }
        #expect(throws: ConfigParseError.self) { try parse("[\(longKey)]\nx = 1") }
    }

    @Test func acceptsKeyPathsUpToTheLimitOnly() throws {
        let limit = TOMLConfigParser.maximumDepth
        let atLimit = Array(repeating: "k", count: limit).joined(separator: ".")
        _ = try parse("\(atLimit) = 1")
        _ = try parse("[\(atLimit)]")
        let beyond = Array(repeating: "k", count: limit + 1).joined(separator: ".")
        #expect(throws: ConfigParseError.self) { try parse("\(beyond) = 1") }
        #expect(throws: ConfigParseError.self) { try parse("[\(beyond)]") }
        // Tabellenkopf plus punktierter Schlüssel zählen zusammen.
        let half = Array(repeating: "k", count: limit / 2 + 1).joined(separator: ".")
        #expect(throws: ConfigParseError.self) { try parse("[\(half)]\n\(half) = 1") }
    }

    @Test func handlesManyKeysInOneTable() throws {
        let text = (0..<20_000).map { "key\($0) = \($0)" }.joined(separator: "\n")
        let value = try parse(text)
        #expect(value.object?.members.count == 20_000)
        #expect(value.value(at: ["key19999"]) == .number("19999"))
    }

    // MARK: Schwärzung

    @Test func redactionCoversEveryValueShapeAndNeverCollectsContent() throws {
        let text = #"""
        [s]
        env = { A = "GEHEIM-1", B = ["GEHEIM-2", { C = 'GEHEIM-3' }], D = """GEHEIM-4""", E = 12345678, F = true }
        headers = ["GEHEIM-5", 'GEHEIM-6', 99887766]
        token = "kein-Geheimnis"

        [t.env.nested]
        G = '''GEHEIM-7'''
        H = 1979-05-27T07:32:00Z

        [[list]]
        env.I = "GEHEIM-8"
        """#
        let value = try parse(text, redacting: ["env", "headers"])
        #expect(value.value(at: ["s", "env", "A"]) == .redacted)
        #expect(value.value(at: ["s", "env", "B"]) == .redacted)
        #expect(value.value(at: ["s", "env", "D"]) == .redacted)
        #expect(value.value(at: ["s", "env", "E"]) == .redacted)
        #expect(value.value(at: ["s", "env", "F"]) == .redacted)
        #expect(value.value(at: ["t", "env", "nested", "G"]) == .redacted)
        #expect(value.value(at: ["t", "env", "nested", "H"]) == .redacted)
        #expect(value.value(at: ["s", "headers"]) == .redacted)
        #expect(value.value(at: ["list"])?.array?.first?.value(at: ["env", "I"]) == .redacted)
        #expect(value.value(at: ["s", "token"]) == .string("kein-Geheimnis"))
        let dump = String(describing: value)
        for marker in ["GEHEIM", "12345678", "99887766", "1979"] {
            #expect(!dump.contains(marker))
        }
    }

    @Test func redactedScalarsAreValidatedButNotCollected() throws {
        let value = try parse("env = { A = true, B = 0xFF, C = 1979-05-27 07:32:00, D = inf, E = 07:32:00 }", redacting: ["env"])
        for key in ["A", "B", "C", "D", "E"] {
            #expect(value.value(at: ["env", key]) == .redacted)
        }
        #expect(throws: ConfigParseError.self) { try parse("env = truthy", redacting: ["env"]) }
        #expect(throws: ConfigParseError.self) { try parse("env = 12abc!", redacting: ["env"]) }
        #expect(throws: ConfigParseError.self) { try parse("env =", redacting: ["env"]) }
    }

    @Test func errorsNeverContainValues() {
        let errors = [
            "env = \"GEHEIM-offen",
            "env = { A = \"GEHEIM\" B = 1 }",
            "env = [\"GEHEIM\" \"x\"]",
            "env = GEHEIM-ohne-Anfuehrungszeichen",
            "[t]\nenv = \"GEHEIM\"\nenv = \"GEHEIM\"",
            // Schlüsselnamen sind Dateiinhalt und gehören ebenso wenig in eine Fehlermeldung.
            "\"GEHEIM-K\" = 1\n\"GEHEIM-K\" = 2",
            "\"GEHEIM-K\" = 1\n\"GEHEIM-K\".x = 2",
            "'GEHEIM-K' = {}\n'GEHEIM-K'.x = 2",
            "[\"GEHEIM-T\"]\n[\"GEHEIM-T\"]",
            "[a.\"GEHEIM-T\"]\n[a.\"GEHEIM-T\"]",
            "[[\"GEHEIM-A\"]]\n[\"GEHEIM-A\"]",
            "[\"GEHEIM-A\"]\n[[\"GEHEIM-A\"]]",
            "\"GEHEIM-K\" = 1\n[[\"GEHEIM-K\"]]",
            "\"GEHEIM-K\" = 1\n[\"GEHEIM-K\".sub]",
            "env = { \"GEHEIM-K\" = 1, \"GEHEIM-K\" = 2 }",
        ]
        for text in errors {
            do {
                _ = try parse(text, redacting: ["env"])
                Issue.record("Fehler erwartet für \(text)")
            } catch {
                #expect(!String(describing: error).contains("GEHEIM"))
            }
        }
    }

    // MARK: Fehlerpositionen

    private func errorLine(_ text: String) -> Int? {
        do {
            _ = try parse(text)
            return nil
        } catch let error as ConfigParseError {
            return error.line
        } catch {
            return nil
        }
    }

    @Test func reportsTheLineOfDuplicates() {
        #expect(errorLine("a = 1\n[t]\n[t]\nb = 2") == 3)
        #expect(errorLine("a = 1\n[[t]]\n[t]\nb = 2") == 3)
        #expect(errorLine("a = 1\na = [\n1,\n2\n]") == 2)
        #expect(errorLine("a = 1\na = \"\"\"\nx\ny\n\"\"\"") == 2)
        #expect(errorLine("a = 1\nb.c = 1\nb = [\n1\n]\n") == 3)
        #expect(errorLine("a = 1\na.b = [\n1\n]") == 2)
        #expect(errorLine("[t]\nk = 1\nk = {\nx = 1 }") == 3)
    }

    @Test func reportsTheLineOfStructuralErrors() {
        #expect(errorLine("a = 1\n[t]\nx = 1 y = 2") == 3)
        #expect(errorLine("[t]\n\n[ u") == 3)
        #expect(errorLine("a = [\n1,\n2") == 3)
    }

    @Test func structuralErrorsUseGenericReasons() {
        func reason(_ text: String) -> String? {
            do {
                _ = try parse(text)
                return nil
            } catch let error as ConfigParseError {
                return error.reason
            } catch {
                return nil
            }
        }
        #expect(reason("a = 1\na = 2") == "Schlüssel doppelt definiert")
        #expect(reason("[t]\n[t]") == "Tabelle doppelt definiert")
        #expect(reason("a = 1\na.b = 2") == "Schlüssel ist keine Tabelle")
        #expect(reason("[[t]]\n[t]") == "Tabelle doppelt definiert")
        #expect(reason("a = 1\n[[a]]") == "Tabelle schon anders definiert")
    }

    // MARK: Laufzeit

    @Test func handlesManyArrayTableHeaders() throws {
        let text = String(repeating: "[[a]]\n", count: 50_000)
        var value: ConfigValue?
        let elapsed = try ContinuousClock().measure { value = try parse(text) }
        #expect(value?.value(at: ["a"])?.array?.count == 50_000)
        #expect(elapsed < .seconds(2))
    }

    // MARK: Mehrzeilige Strings

    @Test func multilineStringsKeepUpToTwoQuotesBeforeTheClosingDelimiter() throws {
        let text = ##"""
        a = """x"""""
        b = '''y''''
        c = '''z'''''
        d = """p""q"""
        e = """"r"""
        f = """"""
        g = ''''''
        h = '''s''t'''
        """##
        let value = try parse(text)
        #expect(value.value(at: ["a"]) == .string("x\"\""))
        #expect(value.value(at: ["b"]) == .string("y'"))
        #expect(value.value(at: ["c"]) == .string("z''"))
        #expect(value.value(at: ["d"]) == .string("p\"\"q"))
        #expect(value.value(at: ["e"]) == .string("\"r"))
        #expect(value.value(at: ["f"]) == .string(""))
        #expect(value.value(at: ["g"]) == .string(""))
        #expect(value.value(at: ["h"]) == .string("s''t"))
    }

    @Test func multilineStringsWithTooManyClosingQuotesAreRejected() {
        let basic = "a = \"\"\"x" + String(repeating: "\"", count: 6)
        let literal = "a = '''x" + String(repeating: "'", count: 6)
        #expect(throws: ConfigParseError.self) { try parse(basic) }
        #expect(throws: ConfigParseError.self) { try parse(literal) }
    }

    @Test func redactedMultilineStringsWithTrailingQuotesAreAccepted() throws {
        let text = ##"""
        env = """GEHEIM"""""
        headers = '''GEHEIM''''
        """##
        let value = try parse(text, redacting: ["env", "headers"])
        #expect(value.value(at: ["env"]) == .redacted)
        #expect(value.value(at: ["headers"]) == .redacted)
    }

    @Test func lineContinuationWorksWithWindowsLineEndings() throws {
        let value = try parse("multi = \"\"\"\r\neins \\\r\n  zwei\"\"\"\r\nnext = 1\r\n")
        #expect(value.value(at: ["multi"]) == .string("eins zwei"))
        #expect(value.value(at: ["next"]) == .number("1"))
    }

    // MARK: Zahlen und Datum

    @Test func parsesOctalBinaryAndLocalDateTimes() throws {
        let text = """
        a = 0o755
        b = 0b1010
        c = 1979-05-27
        d = 07:32:00
        e = 1979-05-27T07:32:00.999-07:00
        f = 07:32:00.5
        """
        let value = try parse(text)
        #expect(value.value(at: ["a"]) == .number("0o755"))
        #expect(value.value(at: ["b"]) == .number("0b1010"))
        #expect(value.value(at: ["c"]) == .string("1979-05-27"))
        #expect(value.value(at: ["d"]) == .string("07:32:00"))
        #expect(value.value(at: ["e"]) == .string("1979-05-27T07:32:00.999-07:00"))
        #expect(value.value(at: ["f"]) == .string("07:32:00.5"))
    }

    // MARK: Strukturregeln

    @Test func inlineTablesStayOnOneLineWithoutTrailingComma() {
        #expect(throws: ConfigParseError.self) { try parse("a = { b = 1,\n c = 2 }") }
        #expect(throws: ConfigParseError.self) { try parse("a = {\n b = 1 }") }
        #expect(throws: ConfigParseError.self) { try parse("a = { b = 1\n}") }
        #expect(throws: ConfigParseError.self) { try parse("a = { b = 1, }") }
    }

    @Test func inlineTablesAreClosed() {
        #expect(throws: ConfigParseError.self) { try parse("a = {}\n[a]") }
        #expect(throws: ConfigParseError.self) { try parse("a = {}\na.b = 1") }
        #expect(throws: ConfigParseError.self) { try parse("a = { b = 1 }\n[a.c]") }
        #expect(throws: ConfigParseError.self) { try parse("a = [1]\n[[a]]") }
    }

    @Test func tablesAndArraysOfTablesDoNotMix() {
        #expect(throws: ConfigParseError.self) { try parse("[[a]]\n[a]") }
        #expect(throws: ConfigParseError.self) { try parse("[a]\n[[a]]") }
        #expect(throws: ConfigParseError.self) { try parse("[a]\nb = 1\n[[a.b]]") }
    }

    @Test func arrayOfTablesKeepsShapeUnderRedactedKey() throws {
        let value = try parse("[[env]]\nA = \"GEHEIM\"\n[[env]]\nB = 2", redacting: ["env"])
        let list = try #require(value.value(at: ["env"])?.array)
        #expect(list.count == 2)
        #expect(list[0].value(at: ["A"]) == .redacted)
        #expect(list[1].value(at: ["B"]) == .redacted)
    }
}
