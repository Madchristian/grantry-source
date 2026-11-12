import Foundation
import Testing
@testable import ManagerKit

/// Kernklassen (#589): eine Zuordnung nach dem Namen der Stufe (`hw.perflevelN.name`) für Chip-Tab, Menüleiste und
/// „Leistung“ – mit Super-Kernen, klassisch und für unbekannte künftige Klassen neutral.
@Suite struct CoreKindTests {
    /// Feste Topologien: Stufen schnellste zuerst, Kerne von der langsamsten Stufe an nummeriert, je Stufe ein Cluster.
    static func profile(_ levels: [(name: String?, type: String, count: Int)]) -> ChipProfile {
        ChipProfile(facts: ChipFacts(levels: levels.map { ChipFacts.Level(name: $0.name, logicalCPUs: $0.count) },
                                     cpus: ChipProfileTests.cpus(levels.reversed().map { ($0.type, $0.count) })))
    }

    static let classic = profile([("Performance", "P", 12), ("Efficiency", "E", 4)])
    static let superAndPerformance = profile([("Super", "S", 6), ("Performance", "P", 12)])
    static let threeClasses = profile([("Super", "S", 4), ("Performance", "P", 6), ("Efficiency", "E", 4)])

    private static func kinds(_ profile: ChipProfile) -> [CoreKind] {
        profile.levels.indices.map(profile.kind(ofLevel:))
    }

    @Test func classicChipHasPerformanceAndEfficiencyCores() {
        #expect(Self.kinds(Self.classic) == [.performance, .efficiency])
        #expect(Self.classic.coreKinds(coreCount: 16)
            == Array(repeating: .efficiency, count: 4) + Array(repeating: .performance, count: 12))
    }

    /// Zwei Stufen Super und Leistung (M5 Max): die langsamere Stufe sind Leistungs-, keine Effizienzkerne.
    @Test func superAndPerformanceCoresFollowTheSystemNames() {
        #expect(Self.kinds(Self.superAndPerformance) == [.super, .performance])
        #expect(Self.superAndPerformance.coreKinds(coreCount: 18)
            == Array(repeating: .performance, count: 12) + Array(repeating: .super, count: 6))
    }

    @Test func threeClassesFollowTheSystemNames() {
        #expect(Self.kinds(Self.threeClasses) == [.super, .performance, .efficiency])
    }

    /// Ohne Namen wie bisher nach Position: zwei Stufen sind Leistungs- und Effizienzkerne, weitere neutral.
    @Test func withoutNamesTwoLevelsFallBackToPosition() {
        #expect(Self.kinds(Self.profile([(nil, "P", 4), (nil, "E", 4)])) == [.performance, .efficiency])
        #expect(Self.kinds(Self.profile([("Super", "S", 2), (nil, "X", 4), ("Efficiency", "E", 2)]))
            == [.super, .other(level: 1, name: nil), .efficiency])
    }

    /// Unbekannte Namen künftiger Chips: eigene, neutral beschriftete Klasse statt einer falschen.
    @Test func unknownNamesBecomeTheirOwnNeutralClass() {
        let profile = Self.profile([("Turbo", "T", 2), ("Performance", "P", 4), ("Efficiency", "E", 2)])
        #expect(Self.kinds(profile) == [.other(level: 0, name: "Turbo"), .performance, .efficiency])
        #expect(Self.kinds(Self.profile([("efficiency", "E", 4)])) == [.efficiency])
        #expect(Self.kinds(Self.profile([(nil, "P", 4)])) == [.unknown])
    }

    @Test func textsPerClass() {
        let kinds: [CoreKind] = [.super, .performance, .efficiency, .other(level: 0, name: "Turbo"),
                                 .other(level: 1, name: nil), .unknown]
        #expect(kinds.map(\.title) == ["Super-Kerne", "Leistungskerne", "Effizienzkerne", "Turbo-Kerne",
                                       "Kerne der Stufe 2", "Kerne"])
        #expect(kinds.map(\.coreName) == ["Super-Kern", "Leistungskern", "Effizienzkern", "Turbo-Kern",
                                          "Kern der Stufe 2", "Kern"])
        #expect(kinds.map(\.tag) == ["S", "P", "E", nil, nil, nil])
    }

    /// Schnellste Klasse zuerst, unbekannte Klassen nach ihrer Stufe, Kerne ohne Klasse zuletzt.
    @Test func classesAreOrderedFromFastest() {
        let shuffled: [CoreKind] = [.unknown, .efficiency, .other(level: 2, name: nil), .performance, .super,
                                    .other(level: 0, name: "Turbo")]
        #expect(shuffled.sorted() == [.super, .performance, .other(level: 0, name: "Turbo"),
                                      .other(level: 2, name: nil), .efficiency, .unknown])
    }
}
