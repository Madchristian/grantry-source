import Foundation
import Synchronization

/// Reihenfolge von Namen wie `localizedStandardCompare` (Finder: Groß-/Kleinschreibung egal, „Prozess 2“ vor
/// „Prozess 10“) als Rang je Name. Die Tabellen des Task-Managers sortieren je Takt rund 1 500 Prozesse; bei Gleichstand
/// (CPU 0, ungemessen) entscheidet der Name, und jeder dieser Vergleiche kostete einen lokalisierten Zeichenkettenvergleich
/// (Bewertung 2026.11.9, Mangel 2, #478). Hier wird jeder Name nur einmal eingeordnet, danach vergleichen die Tabellen
/// Ganzzahlen. Gleichwertige Namen („Safari“, „safari“) haben denselben Rang.
final class CollationOrder: Sendable {
    static let shared = CollationOrder()

    private struct State {
        /// Aufsteigend nach `localizedStandardCompare`.
        var names: [String] = []
        /// Ob ein Name gleichwertig zu seinem Vorgänger ist (gleicher Rang).
        var tiedWithPrevious: [Bool] = []
        var ranks: [String: Int] = [:]
        var comparisons = 0
    }

    /// Mehr Namen vergisst die Ordnung und beginnt mit den gerade gefragten neu: Prozessnamen kommen und gehen.
    private let capacity: Int
    private let state = Mutex(State())

    init(capacity: Int = 8_192) {
        self.capacity = capacity
    }

    /// Rang je Text in derselben Reihenfolge: kleiner = früher, gleich = gleichwertig.
    func ranks(of texts: [String]) -> [Int] {
        state.withLock { state in
            var missing = Set(texts.filter { state.ranks[$0] == nil })
            if !missing.isEmpty {
                if state.names.count + missing.count > capacity {
                    state = State(comparisons: state.comparisons)
                    missing = Set(texts)
                }
                for name in missing { Self.insert(name, into: &state) }
                Self.rank(&state)
            }
            return texts.map { state.ranks[$0] ?? 0 }
        }
    }

    /// Zahl der bekannten Namen (für Tests).
    var count: Int { state.withLock { $0.names.count } }

    /// Bisherige lokalisierte Vergleiche (für Tests).
    var comparisons: Int { state.withLock { $0.comparisons } }

    /// Binäre Suche hinter alle gleichwertigen Namen, dann die Gleichstände der neuen Nachbarschaft.
    private static func insert(_ name: String, into state: inout State) {
        var low = 0, high = state.names.count
        while low < high {
            let middle = (low + high) / 2
            state.comparisons += 1
            if state.names[middle].localizedStandardCompare(name) == .orderedDescending {
                high = middle
            } else {
                low = middle + 1
            }
        }
        let index = low
        state.names.insert(name, at: index)
        state.tiedWithPrevious.insert(index > 0 && isSame(state.names[index - 1], name, &state), at: index)
        if index + 1 < state.names.count {
            state.tiedWithPrevious[index + 1] = isSame(name, state.names[index + 1], &state)
        }
    }

    private static func isSame(_ lhs: String, _ rhs: String, _ state: inout State) -> Bool {
        state.comparisons += 1
        return lhs.localizedStandardCompare(rhs) == .orderedSame
    }

    private static func rank(_ state: inout State) {
        var ranks: [String: Int] = [:]
        ranks.reserveCapacity(state.names.count)
        var rank = 0
        for (index, name) in state.names.enumerated() {
            if index > 0 && !state.tiedWithPrevious[index] { rank += 1 }
            ranks[name] = rank
        }
        state.ranks = ranks
    }
}
