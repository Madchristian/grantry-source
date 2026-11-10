import Foundation

/// Reihenfolge der Task-Manager-Tabellen („Prozesse“, „Details“): nach Zahl oder nach Text. Fehlende Werte stehen in
/// beiden Richtungen am Ende, Gleichstände entscheiden Text (aufsteigend) und Kennung – so bleibt die Reihenfolge von
/// Takt zu Takt stabil. Zahl, Textrang (`CollationOrder`) und Kennung werden je Zeile einmal bestimmt, nicht je Vergleich
/// (#478).
enum TableOrdering {
    private struct Key {
        let number: Double?
        /// Rang des Texts; `nil` ohne Text.
        let rank: Int?
        let id: String
    }

    /// - Parameters:
    ///   - byText: `true` sortiert nach `text` in Richtung `ascending`, sonst nach `number`.
    ///   - text: bei Zahlenspalten nur für Gleichstände.
    static func sorted<Item>(_ items: [Item], ascending: Bool, byText: Bool, number: (Item) -> Double?,
                             text: (Item) -> String?, id: (Item) -> String) -> [Item] {
        let texts = items.map(text)
        var ranks = CollationOrder.shared.ranks(of: texts.compactMap(\.self)).makeIterator()
        let keys = zip(items, texts).map { item, text in
            Key(number: byText ? nil : number(item), rank: text == nil ? nil : ranks.next(), id: id(item))
        }
        let textAscending = byText ? ascending : true
        return keys.indices.sorted { left, right in
            let lhs = keys[left], rhs = keys[right]
            if !byText {
                switch (lhs.number, rhs.number) {
                case let (left?, right?) where left != right: return ascending ? left < right : left > right
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            }
            switch (lhs.rank, rhs.rank) {
            case let (left?, right?) where left != right: return textAscending == (left < right)
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.id < rhs.id
            }
        }
        .map { items[$0] }
    }
}
