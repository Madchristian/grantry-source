import Darwin

/// Numerische IPv4- oder IPv6-Adresse aus ihrer Textform (`inet_pton`), ohne DNS. Eine Zone (`%en0`) wird ignoriert.
enum NumericIPAddress: Hashable, Sendable {
    case v4(UInt32)
    /// Obere und untere 64 Bit in Netzwerk-Reihenfolge gelesen.
    case v6(high: UInt64, low: UInt64)

    /// `nil` für alles, was keine numerische Adresse ist (auch `*`).
    init?(_ text: String) {
        let plain = String(text.split(separator: "%", maxSplits: 1).first ?? "")
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, plain, &v4) == 1 {
            self = .v4(UInt32(bigEndian: v4.s_addr))
        } else if inet_pton(AF_INET6, plain, &v6) == 1 {
            let halves = withUnsafeBytes(of: v6) { bytes in
                (UInt64(bigEndian: bytes.loadUnaligned(as: UInt64.self)),
                 UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt64.self)))
            }
            self = .v6(high: halves.0, low: halves.1)
        } else {
            return nil
        }
    }

    /// Die IPv4-Adresse selbst bzw. die in `::ffff:0:0/96` (IPv4-mapped) oder `64:ff9b::/96` (NAT64) eingebettete.
    var embeddedV4: UInt32? {
        switch self {
        case .v4(let address): address
        case .v6(let high, let low):
            (high == 0 && low >> 32 == 0xFFFF) || (high == 0x0064_FF9B_0000_0000 && low >> 32 == 0)
                ? UInt32(truncatingIfNeeded: low) : nil
        }
    }
}
