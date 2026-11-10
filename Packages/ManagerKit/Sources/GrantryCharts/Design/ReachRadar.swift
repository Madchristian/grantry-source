import SwiftUI

/// Erreichbarkeitsradar (§3.13, Netzwerk › Verbindungen): Ringe um diesen Mac – nur dieser Mac, lokales Netz, aus dem
/// Netz – mit lauschenden und gebundenen Programmen als Peilpunkten auf ihrem Ring. Ab `maximumPerRing` Echos fasst ein
/// Ring den Rest zu „+n“ zusammen. Geometrie und Zeichnung aus `RingRadar`; VoiceOver liest die Echos als Liste.
public struct ReachRadar: View {
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

    public init(echoes: [Echo]) {
        self.echoes = echoes
    }

    private nonisolated static let rings = Ring.allCases.map(\.spec)

    /// Echos je Ring mit Winkel (Grad) nach `RingRadar.placed`.
    nonisolated static func placed(_ echoes: [Echo]) -> [(echo: Echo, degrees: Double)] {
        RingRadar.placed(echoes.map(\.ringEcho), rings: rings).compactMap { item in
            Ring(rawValue: item.echo.ring).map { (Echo(id: item.echo.id, label: item.echo.label, ring: $0), item.degrees) }
        }
    }

    public var body: some View {
        RingRadar(rings: Self.rings, echoes: echoes.map(\.ringEcho), centerSymbol: "laptopcomputer",
                  title: String(localized: "Erreichbarkeit"))
    }
}

private extension ReachRadar.Echo {
    var ringEcho: RingRadar.Echo { RingRadar.Echo(id: id, label: label, ring: ring.rawValue) }
}
