import Darwin
import Foundation
import Synchronization
import SystemConfiguration

/// Bytes je Netzwerkschnittstelle (Spec 2026-11-06 §3) aus `sysctl NET_RT_IFLIST2` (64-Bit-Zähler), dazu numerische
/// Adressen (`getifaddrs`) und der Anzeigename aus den Systemeinstellungen. Nur aktive Schnittstellen (`IFF_UP`).
///
/// Nur die Zähler werden bei jedem Aufruf gelesen. Name, Anzeigename und Adressen kosten ein Vielfaches (`getifaddrs`,
/// `getnameinfo`, SystemConfiguration) und ändern sich selten; sie werden zwischengespeichert und nur neu aufgelöst,
/// wenn sich die Schnittstellenliste im Routing-Puffer ändert (`layoutSignature(of:)`).
///
/// Die Schnittstelle der Default-Route kommt bei jeder Lesung aus dem SystemConfiguration-Speicher (eine Abfrage bei
/// `configd`, keine DNS-Abfrage): Sie kann wechseln, ohne dass sich Liste oder Adressen ändern (Dienstreihenfolge).
///
/// Auch die Auflösung kostet wenig: Namen und rohe Adressen kommen aus einem einzigen `getifaddrs`-Durchlauf
/// (`InterfaceTable`), `getnameinfo` läuft nur für geänderte Adressen (`AddressCache`).
public final class InterfaceThroughputSampler: MetricSource {
    struct ReadFailure: Error, Equatable {
        let code: Int32
    }

    struct RouteInterface: Equatable {
        let index: UInt16
        let isUp: Bool
        let bytesReceived: UInt64
        let bytesSent: UInt64
    }

    /// Die selten wechselnden Angaben einer Schnittstelle.
    struct Identity: Equatable, Sendable {
        let name: String
        let displayName: String?
        let addresses: [String]
    }

    /// Löst die aktiven Schnittstellen (Indizes) auf; `nil`, wenn das nicht gelang – dann gilt der alte Stand weiter und
    /// der nächste Aufruf versucht es erneut.
    typealias Resolution = @Sendable (_ activeIndices: [UInt16]) -> [UInt16: Identity]?

    /// Namen und rohe Adressen aller Schnittstellen aus einem `getifaddrs`-Durchlauf: Namen über die Link-Adresse
    /// (`sockaddr_dl.sdl_index`) statt `if_indextoname` je Schnittstelle (ein eigener `sysctl` jeweils), IPv4/IPv6 als
    /// `sockaddr`-Bytes.
    struct InterfaceTable: Equatable {
        var names: [UInt16: String] = [:]
        var addresses: [String: [[UInt8]]] = [:]

        /// `nil`, wenn `getifaddrs` fehlschlägt.
        static func current() -> InterfaceTable? {
            var list: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&list) == 0, let first = list else { return nil }
            defer { freeifaddrs(list) }
            var table = InterfaceTable()
            for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
                guard let address = entry.pointee.ifa_addr else { continue }
                let name = String(cString: entry.pointee.ifa_name)
                switch Int32(address.pointee.sa_family) {
                case AF_LINK:
                    let index = address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { $0.pointee.sdl_index }
                    table.names[index] = name
                case AF_INET, AF_INET6:
                    let bytes = UnsafeRawBufferPointer(start: address, count: Int(address.pointee.sa_len))
                    table.addresses[name, default: []].append(Array(bytes))
                default:
                    continue
                }
            }
            return table
        }
    }

    /// Numerische Adressen je Schnittstelle; formatiert wird nur, wenn sich die rohen Adressen geändert haben. Die
    /// Auflösung läuft auch, wenn eine Schnittstelle nur auf- oder abgebaut wird, ohne dass sich eine Adresse ändert
    /// (etwa ein Tunnel ohne Adresse); dann entfällt `getnameinfo` ganz.
    struct AddressCache {
        private var raw: [String: [[UInt8]]] = [:]
        private var text: [String: [String]] = [:]

        mutating func addresses(for raw: [String: [[UInt8]]], format: ([UInt8]) -> String?) -> [String: [String]] {
            if raw != self.raw {
                self.raw = raw
                text = raw.mapValues { $0.compactMap(format) }
            }
            return text
        }
    }

    /// `AddressCache` für die Auflösung des Systems, die in einer escaping Closure läuft (ein `Mutex` lässt sich nicht
    /// einfangen).
    final class SharedAddressCache: Sendable {
        private let cache = Mutex(AddressCache())

        func addresses(for raw: [String: [[UInt8]]]) -> [String: [String]] {
            cache.withLock { $0.addresses(for: raw, format: InterfaceThroughputSampler.numericHost) }
        }
    }

    private struct Cache {
        /// `layoutSignature` der Lesung, zu der `identities` gehören; `nil` vor der ersten Auflösung.
        var layout: [UInt8]?
        var identities: [UInt16: Identity] = [:]
    }

    private let readBuffer: @Sendable () throws -> [UInt8]
    private let resolve: Resolution
    private let primaryInterface: @Sendable () -> String?
    private let cache = Mutex(Cache())

    public convenience init() {
        let addresses = SharedAddressCache()
        let store = PrimaryInterfaceStore()
        self.init(readBuffer: Self.routeBuffer, resolve: { Self.systemIdentities(for: $0, addressCache: addresses) },
                  primaryInterface: store.current)
    }

    /// Mit austauschbarem Routing-Puffer, Auflösung und Default-Route, damit Tests die Zwischenspeicherung prüfen
    /// können.
    init(readBuffer: @escaping @Sendable () throws -> [UInt8], resolve: @escaping Resolution,
         primaryInterface: @escaping @Sendable () -> String? = { nil }) {
        self.readBuffer = readBuffer
        self.resolve = resolve
        self.primaryInterface = primaryInterface
    }

    public func read() throws -> [InterfaceCounters] {
        let buffer = try readBuffer()
        let active = Self.parse(buffer).filter(\.isUp)
        let identities = identities(ofActive: active.map(\.index), layout: Self.layoutSignature(of: buffer))
        let primary = primaryInterface()
        return active.compactMap { route in
            identities[route.index].map {
                InterfaceCounters(name: $0.name, bytesReceived: route.bytesReceived, bytesSent: route.bytesSent,
                                  displayName: $0.displayName, addresses: $0.addresses, isPrimary: $0.name == primary)
            }
        }
    }

    /// Schnittstellen-Nachrichten (`RTM_IFINFO2`) des Routing-Puffers; andere Nachrichten werden übersprungen, eine
    /// abgeschnittene oder leere beendet das Lesen.
    static func parse(_ buffer: [UInt8]) -> [RouteInterface] {
        buffer.withUnsafeBytes { raw in
            var interfaces: [RouteInterface] = []
            forEachMessage(in: raw) { type, range in
                if type == RTM_IFINFO2, let interface = routeInterface(in: raw, at: range) {
                    interfaces.append(interface)
                }
            }
            return interfaces
        }
    }

    /// Alles im Routing-Puffer, was sich nicht bei jedem Takt ändert: Index und Zustand jeder Schnittstelle und ihre
    /// Adressen (`RTM_NEWADDR`). Die Zähler fehlen ebenso absichtlich wie die Multicast-Gruppen (`RTM_NEWMADDR2`), die
    /// mit laufenden Programmen wechseln. Ändert sich der Auszug, hat sich die Schnittstellenliste geändert.
    static func layoutSignature(of buffer: [UInt8]) -> [UInt8] {
        buffer.withUnsafeBytes { raw in
            var signature: [UInt8] = []
            forEachMessage(in: raw) { type, range in
                if type == RTM_IFINFO2 {
                    guard let interface = routeInterface(in: raw, at: range) else { return }
                    signature.append(contentsOf: [UInt8(interface.index & 0xFF), UInt8(interface.index >> 8),
                                                  interface.isUp ? 1 : 0])
                } else if type == RTM_NEWADDR {
                    signature.append(contentsOf: raw[range])
                }
            }
            return signature
        }
    }

    /// Ruft `body` für jede vollständige Nachricht des Routing-Puffers mit ihrem Typ und Byte-Bereich auf. Eine
    /// abgeschnittene oder leere Nachricht beendet den Lauf. Vorn steht bei allen Nachrichten gleich: Länge (2 Byte),
    /// Version (1), Typ (1).
    private static func forEachMessage(in raw: UnsafeRawBufferPointer, _ body: (Int32, Range<Int>) -> Void) {
        let typeOffset = 3
        var offset = 0
        while offset + typeOffset < raw.count {
            let length = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            guard length > 0, offset + length <= raw.count else { return }
            body(Int32(raw[offset + typeOffset]), offset..<offset + length)
            offset += length
        }
    }

    private static func routeInterface(in raw: UnsafeRawBufferPointer, at range: Range<Int>) -> RouteInterface? {
        guard range.count >= MemoryLayout<if_msghdr2>.size else { return nil }
        let message = raw.loadUnaligned(fromByteOffset: range.lowerBound, as: if_msghdr2.self)
        return RouteInterface(index: message.ifm_index, isUp: message.ifm_flags & IFF_UP != 0,
                              bytesReceived: message.ifm_data.ifi_ibytes, bytesSent: message.ifm_data.ifi_obytes)
    }

    /// Hat sich die Liste seit der letzten Auflösung geändert, wird neu aufgelöst – unter der Sperre, damit gleichzeitige
    /// Aufrufe nicht doppelt auflösen.
    private func identities(ofActive indices: [UInt16], layout: [UInt8]) -> [UInt16: Identity] {
        cache.withLock { cache in
            if cache.layout != layout, let resolved = resolve(indices) {
                cache = Cache(layout: layout, identities: resolved)
            }
            return cache.identities
        }
    }

    static func routeBuffer() throws -> [UInt8] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { throw ReadFailure(code: errno) }
        size += 1_024
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { throw ReadFailure(code: errno) }
        return Array(buffer.prefix(size))
    }

    /// Name, Anzeigename und Adressen der Schnittstellen mit diesen Indizes. Eine Schnittstelle ohne Namen (zwischen
    /// Liste und Abfrage verschwunden) fehlt; schlägt `getifaddrs` fehl, ist die Auflösung gescheitert (`nil`).
    static func systemIdentities(for indices: [UInt16],
                                 addressCache: SharedAddressCache = SharedAddressCache()) -> [UInt16: Identity]? {
        guard let table = InterfaceTable.current() else { return nil }
        let addresses = addressCache.addresses(for: table.addresses)
        let displayNames = systemDisplayNames()
        return Dictionary(uniqueKeysWithValues: indices.compactMap { index in
            table.names[index].map { name in
                (index, Identity(name: name, displayName: displayNames[name], addresses: addresses[name] ?? []))
            }
        })
    }

    /// Numerische IPv4- bzw. IPv6-Adresse aus rohen `sockaddr`-Bytes; `nil`, wenn sie sich nicht darstellen lässt.
    static func numericHost(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= MemoryLayout<sockaddr>.size else { return nil }
        return bytes.withUnsafeBytes { buffer in
            let address = buffer.baseAddress!.assumingMemoryBound(to: sockaddr.self)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(buffer.count), &host, socklen_t(host.count), nil, 0,
                              NI_NUMERICHOST) == 0 else { return nil }
            return text(host)
        }
    }

    /// Nullterminierter C-Puffer als Text.
    private static func text(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func systemDisplayNames() -> [String: String] {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        let pairs = all.compactMap { interface -> (String, String)? in
            guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let displayName = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? else { return nil }
            return (bsdName, displayName)
        }
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }
}

/// Schnittstelle der Default-Route laut `configd`: zuerst IPv4, sonst IPv6. Eine Sitzung für alle Lesungen, damit nicht
/// jede Abfrage eine neue Verbindung aufbaut.
final class PrimaryInterfaceStore: @unchecked Sendable {
    // SCDynamicStore ist für Lesezugriffe aus mehreren Threads ausgelegt; die Sitzung wird nach `init` nicht verändert.
    private let store = SCDynamicStoreCreate(nil, "Grantry.TaskManager" as CFString, nil, nil)

    func current() -> String? {
        ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"].lazy.compactMap { key in
            (SCDynamicStoreCopyValue(self.store, key as CFString) as? [String: Any])?["PrimaryInterface"] as? String
        }.first
    }
}
