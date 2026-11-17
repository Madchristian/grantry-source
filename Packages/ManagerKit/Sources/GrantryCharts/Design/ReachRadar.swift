import SwiftUI

/// Erreichbarkeitsradar (§3.13, Netzwerk › Verbindungen): Ringe um diesen Mac – nur dieser Mac, lokales Netz, aus dem
/// Netz – mit lauschenden und gebundenen Programmen als Peilpunkten auf ihrem Ring. Ab `maximumPerRing` Echos fasst ein
/// Ring den Rest zu „+n“ zusammen; vergrößert zeigt er, was sein Umfang fasst. Geometrie und Zeichnung aus `RingRadar`;
/// VoiceOver liest die Echos als Liste. Mit `onPick` nimmt jedes Echo Klicks an wie beim `RingRadar` (#640); was ein
/// Klick bewirkt, entscheidet der Aufrufer. Vergleicht ohne den Rückruf (`.equatable()`).
public struct ReachRadar: View, Equatable {
    public enum Ring: Int, CaseIterable, Sendable {
        case thisMac, localNetwork, network

        public var title: String {
            switch self {
            case .thisMac: String(localized: "nur dieser Mac")
            case .localNetwork: String(localized: "lokales Netz")
            case .network: String(localized: "aus dem Netz")
            }
        }

        var tone: StatusTone {
            switch self {
            case .thisMac: .positive
            case .localNetwork: .info
            case .network: .finding
            }
        }

        var spec: RingRadar.Ring {
            RingRadar.Ring(title: title, tone: tone, isDashed: self == .network, capacity: ReachRadar.maximumPerRing)
        }
    }

    public struct Echo: Identifiable, Hashable, Sendable {
        public let id: String
        public let label: String
        public let ring: Ring

        public init(id: String, label: String, ring: Ring) {
            self.id = id
            self.label = label
            self.ring = ring
        }
    }

    nonisolated static let maximumPerRing = 8

    let echoes: [Echo]
    let picked: Set<Echo.ID>
    let isExpanded: Bool
    let pickHint: String?
    let onPick: ((Set<Echo.ID>) -> Void)?

    /// - Parameters:
    ///   - picked: Gewählte Echos, etwa ein Filter.
    ///   - isExpanded: Vergrößerte Karte: jeder Ring zeigt, was sein Umfang fasst (`RingRadar`).
    ///   - pickHint: Was ein Klick bewirkt, als Tooltip und VoiceOver-Hinweis.
    ///   - onPick: Klick auf ein Echo mit den Kennungen, für die es steht; `nil` nimmt keine Klicks an.
    public init(echoes: [Echo], picked: Set<Echo.ID> = [], isExpanded: Bool = false, pickHint: String? = nil,
                onPick: ((Set<Echo.ID>) -> Void)? = nil) {
        self.echoes = echoes
        self.picked = picked
        self.isExpanded = isExpanded
        self.pickHint = pickHint
        self.onPick = onPick
    }

    nonisolated public static func == (lhs: ReachRadar, rhs: ReachRadar) -> Bool {
        lhs.echoes == rhs.echoes && lhs.picked == rhs.picked && lhs.isExpanded == rhs.isExpanded
            && lhs.pickHint == rhs.pickHint && (lhs.onPick == nil) == (rhs.onPick == nil)
    }

    nonisolated static let rings = Ring.allCases.map(\.spec)

    public var body: some View {
        RingRadar(rings: Self.rings, echoes: echoes.map(\.ringEcho), centerSymbol: "laptopcomputer",
                  title: String(localized: "Erreichbarkeit"), picked: picked, isExpanded: isExpanded, pickHint: pickHint,
                  onPick: onPick)
    }
}

private extension ReachRadar.Echo {
    var ringEcho: RingRadar.Echo { RingRadar.Echo(id: id, label: label, ring: ring.rawValue) }
}
