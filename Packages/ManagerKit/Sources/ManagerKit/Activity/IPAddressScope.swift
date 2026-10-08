import Darwin

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
        let plain = String(address.split(separator: "%", maxSplits: 1).first ?? "")
        var v4 = in_addr()
        if inet_pton(AF_INET, plain, &v4) == 1 { return isPublic(v4: UInt32(bigEndian: v4.s_addr)) }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, plain, &v6) == 1 { return isPublic(v6: withUnsafeBytes(of: v6) { Array($0) }) }
        return false
    }

    /// Netze, deren Adressen nie öffentlich sind: (Netzadresse, Präfixlänge).
    private static let nonPublicV4: [(network: UInt32, prefix: UInt32)] = [
        (0x0000_0000, 8), (0x0A00_0000, 8), (0x6440_0000, 10), (0x7F00_0000, 8), (0xA9FE_0000, 16),
        (0xAC10_0000, 12), (0xC0A8_0000, 16), (0xE000_0000, 4), (0xF000_0000, 4),
    ]

    private static func isPublic(v4 address: UInt32) -> Bool {
        !nonPublicV4.contains { address >> (32 - $0.prefix) == $0.network >> (32 - $0.prefix) }
    }

    /// `::ffff:0:0/96` (IPv4-mapped) und `64:ff9b::/96` (NAT64): IPv4-Adresse in den letzten 32 Bit.
    private static let v4MappedPrefix: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF]
    private static let nat64Prefix: [UInt8] = [0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0]

    private static func isPublic(v6 bytes: [UInt8]) -> Bool {
        let embeddedV4 = bytes[12...].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        if bytes.prefix(12).elementsEqual(v4MappedPrefix) || bytes.prefix(12).elementsEqual(nat64Prefix) {
            return isPublic(v4: embeddedV4)
        }
        if bytes.prefix(15).allSatisfy({ $0 == 0 }), bytes[15] <= 1 { return false }
        if bytes[0] & 0xFE == 0xFC { return false }
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return false }
        return bytes[0] != 0xFF
    }
}
