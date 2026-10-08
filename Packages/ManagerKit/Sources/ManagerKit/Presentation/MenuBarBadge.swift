/// Badge am Menüleistensymbol für ungelesene Änderungen: bis 9 als Zahl, darüber als Punkt – mehr Stellen passen
/// nicht lesbar ins Symbol. Läuft eine Beobachtung (#127), zeigt das Symbol ohne ungelesene Änderungen einen Punkt.
public enum MenuBarBadge: Hashable, Sendable {
    case none
    case count(Int)
    case dot

    /// Höchste Zahl, die das Badge noch als Ziffer zeigt.
    public static let maximumCount = 9

    public init(unreadCount: Int, isObserving: Bool = false) {
        switch unreadCount {
        case ...0: self = isObserving ? .dot : .none
        case 1...Self.maximumCount: self = .count(unreadCount)
        default: self = .dot
        }
    }

    /// Text im Badge; `nil` ohne Badge oder beim Punkt.
    public var text: String? {
        if case .count(let count) = self { String(count) } else { nil }
    }

    /// VoiceOver-Beschreibung des Menüleistensymbols.
    public static func accessibilityLabel(unreadCount: Int, isObserving: Bool = false) -> String {
        let unread = switch unreadCount {
        case ...0: "Grantry"
        case 1: "Grantry, 1 ungelesene Änderung"
        default: "Grantry, \(unreadCount) ungelesene Änderungen"
        }
        return isObserving ? unread + ", Beobachtung läuft" : unread
    }
}
