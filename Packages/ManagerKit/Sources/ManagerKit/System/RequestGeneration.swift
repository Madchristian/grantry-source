/// Zählt Anfragen, deren Ergebnisse asynchron eintreffen: Nur das Ergebnis der jüngsten Anfrage gilt, ältere, später
/// fertige werden verworfen.
public struct RequestGeneration: Sendable {
    /// Kennung einer Anfrage.
    public struct Token: Hashable, Sendable {
        fileprivate let value: Int
    }

    private var current = 0

    public init() {}

    /// Beginnt eine Anfrage; alle früheren gelten ab jetzt als veraltet.
    public mutating func begin() -> Token {
        current += 1
        return Token(value: current)
    }

    /// Macht alle laufenden Anfragen ungültig, ohne eine neue zu beginnen.
    public mutating func invalidate() {
        current += 1
    }

    /// Ob `token` zur jüngsten Anfrage gehört.
    public func isCurrent(_ token: Token) -> Bool {
        token.value == current
    }
}
