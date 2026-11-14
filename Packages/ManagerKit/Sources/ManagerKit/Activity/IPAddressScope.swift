/// Ob sich Reverse-DNS für eine Adresse lohnt: Lokale, private und Sonderadressen (Loopback, RFC 1918, CGNAT/Tailscale
/// `100.64.0.0/10`, Link-Local, ULA `fc00::/7`, Multicast, unbestimmt) haben keinen öffentlichen Namen und würden nur
/// den lokalen Resolver befragen.
public enum IPAddressScope {
    /// Wo eine Gegenstelle liegt – grobe Einordnung für die Anzeige.
    public enum Location: Hashable, Sendable {
        /// Loopback (`127.0.0.0/8`, `::1`, `::ffff:127.x.x.x`).
        case thisMac
        /// Private, Link-Local-, CGNAT- und Sonderadressen.
        case localNetwork
        /// Öffentlich routbar.
        case internet

        /// „Dieser Mac“, „Lokales Netz“, „Internet“.
        public var displayName: String {
            switch self {
            case .thisMac: "Dieser Mac"
            case .localNetwork: "Lokales Netz"
            case .internet: "Internet"
            }
        }
    }

    /// Einordnung von `address`; unlesbare Adressen gelten als lokales Netz (sie werden nie öffentlich aufgelöst).
    public static func location(of address: String) -> Location {
        if isPublic(address) { return .internet }
        return ListenerReachability(addresses: [address]) == .thisMac ? .thisMac : .localNetwork
    }

    /// `true` für eine öffentlich routbare IPv4- oder IPv6-Adresse (Zone `%en0` wird ignoriert).
    public static func isPublic(_ address: String) -> Bool {
        NumericIPAddress(address).map(isPublic) ?? false
    }

    /// Netze, deren Adressen nie öffentlich sind: (Netzadresse, Präfixlänge).
    private static let nonPublicV4: [(network: UInt32, prefix: UInt32)] = [
        (0x0000_0000, 8), (0x0A00_0000, 8), (0x6440_0000, 10), (0x7F00_0000, 8), (0xA9FE_0000, 16),
        (0xAC10_0000, 12), (0xC0A8_0000, 16), (0xE000_0000, 4), (0xF000_0000, 4),
    ]

    static func isPublic(_ address: NumericIPAddress) -> Bool {
        if let v4 = address.embeddedV4 {
            return !nonPublicV4.contains { v4 >> (32 - $0.prefix) == $0.network >> (32 - $0.prefix) }
        }
        guard case .v6(let high, let low) = address else { return false }
        // Unbestimmt und Loopback, ULA `fc00::/7`, Link-Local `fe80::/10`, Multicast `ff00::/8`.
        if high == 0, low <= 1 { return false }
        if high >> 57 == 0xFC >> 1 { return false }
        if high >> 54 == 0xFE80 >> 6 { return false }
        return high >> 56 != 0xFF
    }
}
