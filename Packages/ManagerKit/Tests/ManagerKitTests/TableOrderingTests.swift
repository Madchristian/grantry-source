import Foundation
import Testing
@testable import ManagerKit

@Suite struct TableOrderingTests {
    private struct Item: Equatable {
        let number: Double?
        let text: String?
        let id: String
    }

    /// Die Reihenfolge vor #478: jeder Vergleich mit `localizedStandardCompare`.
    private func reference(_ items: [Item], ascending: Bool, byText: Bool) -> [Item] {
        items.sorted { lhs, rhs in
            if !byText {
                switch (lhs.number, rhs.number) {
                case let (left?, right?) where left != right: return ascending ? left < right : left > right
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            }
            switch (lhs.text, rhs.text) {
            case let (left?, right?):
                let order = left.localizedStandardCompare(right)
                if order != .orderedSame { return (byText ? ascending : true) == (order == .orderedAscending) }
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): break
            }
            return lhs.id < rhs.id
        }
    }

    /// Viele Gleichstände wie im Alltag: CPU 0 oder ungemessen, gleiche Namen in anderer Schreibweise.
    private func items(count: Int, seed: UInt64) -> [Item] {
        var generator = SeededGenerator(seed: seed)
        let names = ["Safari", "safari", "mds", "mds_stores", "Prozess 2", "Prozess 10", "Äpfel", "apfel", "zsh"]
        return (0..<count).map { index in
            let number: Double? = switch Int.random(in: 0..<4, using: &generator) {
            case 0: nil
            case 1: 0
            default: Double(Int.random(in: 0..<5, using: &generator)) / 10
            }
            let text: String? = Int.random(in: 0..<8, using: &generator) == 0 ? nil
                : names[Int.random(in: 0..<names.count, using: &generator)]
            return Item(number: number, text: text, id: "\(Int.random(in: 0..<1_000, using: &generator))-\(index)")
        }
    }

    @Test(arguments: [(true, false), (false, false), (true, true), (false, true)])
    func matchesTheOrderBefore(ascending: Bool, byText: Bool) {
        for seed in 1...20 as ClosedRange<UInt64> {
            let items = items(count: 300, seed: seed)
            let sorted = TableOrdering.sorted(items, ascending: ascending, byText: byText, number: \.number,
                                              text: \.text, id: \.id)
            #expect(sorted == reference(items, ascending: ascending, byText: byText))
        }
    }
}

/// Reproduzierbare Zufallszahlen (SplitMix64).
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
