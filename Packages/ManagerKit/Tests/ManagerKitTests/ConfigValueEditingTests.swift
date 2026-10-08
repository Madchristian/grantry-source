import Testing
@testable import ManagerKit

@Suite struct ConfigValueEditingTests {
    private let tree = ConfigValue.object(ConfigObject(members: [
        .init(key: "a", value: .object(ConfigObject(members: [.init(key: "x", value: .number("1"))]))),
        .init(key: "b", value: .bool(true)),
    ]))

    @Test func removesAndSetsAlongPaths() {
        #expect(tree.removing(["a", "x"]).value(at: ["a"]) == .object(ConfigObject()))
        #expect(tree.removing(["b"]).object?.keys == ["a"])
        #expect(tree.removing(["c", "d"]) == tree)
        #expect(tree.setting(["a", "y"], to: .null).value(at: ["a", "y"]) == .null)
        #expect(tree.setting(["n", "m"], to: .bool(false)).value(at: ["n", "m"]) == .bool(false))
        #expect(tree.removing(["a", "x"]).removingEmptyObjects(along: ["a"]).object?.keys == ["b"])
    }

    @Test func equivalenceIgnoresKeyOrderButNotArrayOrder() {
        let reordered = ConfigValue.object(ConfigObject(members: [
            .init(key: "b", value: .bool(true)),
            .init(key: "a", value: .object(ConfigObject(members: [.init(key: "x", value: .number("1"))]))),
        ]))
        #expect(tree.isEquivalent(to: reordered))
        #expect(!tree.isEquivalent(to: tree.setting(["b"], to: .bool(false))))
        #expect(!ConfigValue.array([.null, .bool(true)]).isEquivalent(to: .array([.bool(true), .null])))
    }

    private func object(_ members: (String, ConfigValue)...) -> ConfigValue {
        .object(ConfigObject(members: members.map { ConfigObject.Member(key: $0.0, value: $0.1) }))
    }

    @Test func removingDropsEveryDuplicateAndFollowsAllOccurrences() {
        let duplicated = object(("a", object(("x", .null))), ("k", .bool(true)), ("a", object(("x", .null), ("y", .null))))
        #expect(duplicated.removing(["k"]).object?.keys == ["a"])
        let withoutX = duplicated.removing(["a", "x"])
        #expect(withoutX.object?.members.map { $0.value.object?.keys ?? [] } == [[], [], ["y"]])
        #expect(object(("a", .null), ("a", .null)).removing(["a"]) == object())
    }

    @Test func pathsThroughNonObjectsChangeNothing() {
        let list = object(("l", .array([object(("x", .null))])), ("s", .string("t")))
        #expect(list.removing(["l", "x"]) == list)
        #expect(list.setting(["l", "x"], to: .null) == list)
        #expect(list.setting(["s", "x"], to: .null) == list)
    }

    @Test func settingReplacesEveryOccurrence() {
        let duplicated = object(("a", .bool(true)), ("a", .bool(true)))
        #expect(duplicated.setting(["a"], to: .bool(false)) == object(("a", .bool(false)), ("a", .bool(false))))
        #expect(tree.setting(["a", "x"], to: .null).value(at: ["a"]) == object(("x", .null)))
    }

    @Test func removingEmptyObjectsClimbsAndStopsAtTheFirstNonEmpty() {
        let nested = object(("a", object(("b", object(("c", object()))))), ("z", .null))
        #expect(nested.removingEmptyObjects(along: ["a", "b", "c"]) == object(("z", .null)))
        let kept = object(("a", object(("b", object(("c", object()))), ("k", .null))))
        #expect(kept.removingEmptyObjects(along: ["a", "b", "c"]) == object(("a", object(("k", .null)))))
        #expect(tree.removingEmptyObjects(along: ["a"]) == tree)
    }

    @Test func equivalenceSeesNestedChangesKeySetsAndNumberText() {
        #expect(!tree.isEquivalent(to: tree.setting(["a", "x"], to: .number("2"))))
        #expect(!tree.isEquivalent(to: tree.setting(["c"], to: .null)))
        #expect(!tree.isEquivalent(to: tree.removing(["b"])))
        #expect(!ConfigValue.number("1.0").isEquivalent(to: .number("1")))
        // Verdeckte Dublette: Es zählt der letzte Wert, wie beim Lesen.
        #expect(object(("a", .number("1")), ("a", .number("2"))).isEquivalent(to: object(("a", .number("2")))))
    }

    /// Bewusste Entscheidung (Doc von `isEquivalent`, Spec §3.5): Geschwärzte Werte gelten untereinander als gleich –
    /// die Nachprüfung sieht Änderungen an Geheimwerten nicht, weil sie sie nie liest.
    @Test func redactedValuesAreEquivalentToEachOther() {
        #expect(ConfigValue.redacted.isEquivalent(to: .redacted))
        #expect(object(("env", .redacted)).isEquivalent(to: object(("env", .redacted))))
        #expect(!ConfigValue.redacted.isEquivalent(to: .string("GEHEIM")))
    }
}
