import Foundation

/// Entscheidet, welche von mehreren laufenden Instanzen der App weiterläuft: die zuerst gestartete. Starten zwei
/// gleichzeitig, sehen beide einander; die Reihenfolge nach Startzeit und PID ist für beide dieselbe, daher weicht
/// genau eine.
public enum InstanceArbitration {
    /// Eine laufende Instanz der App.
    public struct Instance: Hashable, Sendable {
        public let processIdentifier: Int32
        /// `nil`, wenn das System keine Startzeit kennt; zählt dann als früher gestartet.
        public let launchDate: Date?

        public init(processIdentifier: Int32, launchDate: Date?) {
            self.processIdentifier = processIdentifier
            self.launchDate = launchDate
        }
    }

    /// Instanz, der `current` den Vortritt lassen muss; `nil`, wenn `current` weiterläuft.
    public static func instance(toDeferTo others: [Instance], current: Instance) -> Instance? {
        others
            .filter { $0.processIdentifier != current.processIdentifier && precedes($0, current) }
            .min { precedes($0, $1) }
    }

    private static func precedes(_ lhs: Instance, _ rhs: Instance) -> Bool {
        let lhsDate = lhs.launchDate ?? .distantPast
        let rhsDate = rhs.launchDate ?? .distantPast
        return lhsDate != rhsDate ? lhsDate < rhsDate : lhs.processIdentifier < rhs.processIdentifier
    }
}
