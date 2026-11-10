import Foundation
import Testing
@testable import ManagerKit

@Suite struct CollationOrderTests {
    private static let names = ["Safari", "safari", "Prozess 10", "Prozess 2", "Äpfel", "apfel", "Zebra", "zsh", "",
                                "Mail", "mds_stores", "mds", "Grantry Helper", "grantry", "Ü", "u", "10", "9"]

    private func localizedOrder(_ lhs: String, _ rhs: String) -> ComparisonResult { lhs.localizedStandardCompare(rhs) }

    @Test func ranksFollowLocalizedStandardCompareIncludingTies() {
        let order = CollationOrder()
        let ranks = order.ranks(of: Self.names)
        for (left, leftRank) in zip(Self.names, ranks) {
            for (right, rightRank) in zip(Self.names, ranks) {
                switch localizedOrder(left, right) {
                case .orderedAscending: #expect(leftRank < rightRank, "\(left) vor \(right)")
                case .orderedDescending: #expect(leftRank > rightRank, "\(left) nach \(right)")
                case .orderedSame: #expect(leftRank == rightRank, "\(left) gleich \(right)")
                }
            }
        }
    }

    @Test func namesArrivingLaterKeepTheOrder() {
        let order = CollationOrder()
        _ = order.ranks(of: Array(Self.names.prefix(5)))
        _ = order.ranks(of: Array(Self.names.suffix(8)))
        let ranks = order.ranks(of: Self.names)
        let sorted = zip(Self.names, ranks).sorted { $0.1 < $1.1 }.map(\.0)
        for (left, right) in zip(sorted, sorted.dropFirst()) {
            #expect(localizedOrder(left, right) != .orderedDescending, "\(left) vor \(right)")
        }
    }

    /// Je neuem Namen ein Vergleich mit wenigen Nachbarn statt einer Sortierung aller Namen je Takt.
    @Test func knownNamesNeedNoComparison() {
        let order = CollationOrder()
        _ = order.ranks(of: Self.names)
        let before = order.comparisons
        _ = order.ranks(of: Self.names.reversed())
        #expect(order.comparisons == before)
    }

    @Test func forgetsNamesBeyondItsCapacity() {
        let order = CollationOrder(capacity: 4)
        _ = order.ranks(of: ["a", "b", "c", "d"])
        let ranks = order.ranks(of: ["e", "b"])
        #expect(order.count == 2)
        #expect(ranks[1] < ranks[0])
    }
}
