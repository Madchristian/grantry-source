import Foundation
import Testing
@testable import ManagerKit

@Suite struct ConfigObjectTests {
    @Test func lookupAndKeysStayFastForHugeObjects() throws {
        let count = 50_000
        var members = (0..<count).map { ConfigObject.Member(key: "key\($0)", value: .number("\($0)")) }
        members.append(ConfigObject.Member(key: "key0", value: .string("zuletzt")))
        let object = ConfigObject(members: members)

        var keys: [String] = []
        var allFound = true
        let elapsed = ContinuousClock().measure {
            keys = object.keys
            for index in 1..<count where object["key\(index)"] != .number("\(index)") { allFound = false }
        }
        #expect(allFound)
        #expect(keys.count == count)
        #expect(keys.first == "key0")
        #expect(object["key0"] == .string("zuletzt"))
        #expect(elapsed < .seconds(1))
    }

    @Test func parsedHugeObjectKeepsLastDuplicateAndFirstKeyOrder() throws {
        let count = 50_000
        let body = (0..<count).map { "\"k\($0)\": \($0)" }.joined(separator: ",")
        let text = "{\(body),\"k7\": \"neu\"}"
        let value = try ConfigParsing.parse(Data(text.utf8), syntax: .json, redaction: .none)
        let object = try #require(value.object)
        #expect(object.members.count == count + 1)
        #expect(object.keys.count == count)
        #expect(object.keys.prefix(3) == ["k0", "k1", "k2"])
        #expect(object["k7"] == .string("neu"))
        #expect(object["k49999"] == .number("49999"))
    }

    @Test func equalityAndHashIgnoreTheIndex() {
        let members = [
            ConfigObject.Member(key: "a", value: .number("1")),
            ConfigObject.Member(key: "a", value: .number("2")),
        ]
        var appended = ConfigObject()
        appended.append("a", .number("1"))
        appended.append("a", .number("2"))
        let built = ConfigObject(members: members)
        #expect(appended == built)
        #expect(appended.hashValue == built.hashValue)
        #expect(built != ConfigObject(members: [members[0]]))
        #expect(built["a"] == .number("2"))
        #expect(built.keys == ["a"])
    }
}
