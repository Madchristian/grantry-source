import Foundation
import IOKit
import Synchronization

/// Bytes, Vorgänge und Bearbeitungszeit je Laufwerk (Spec 2026-11-06 §3) aus `IOBlockStorageDriver` → `Statistics`.
/// Kennung ist der BSD-Name des Mediums darunter („disk0“), Name der des Geräts darüber. Eingebundene Disk-Images
/// zählen nicht als Laufwerk. Name, BSD-Name und Art liest der Sampler je Treiber nur einmal (`DriveIdentityCache`,
/// #489); je Takt nur die Zähler.
public struct DiskThroughputSampler: MetricSource {
    private let identities = DriveIdentityCache()

    public init() {}

    public func read() throws -> [DriveCounters] {
        var drives: [DriveCounters] = []
        var present: Set<UInt64> = []
        try IORegistryReader.forEachService(matching: "IOBlockStorageDriver") { driver in
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(driver, &entryID)
            present.insert(entryID)
            let identity = identities.identity(for: entryID) { Self.identity(of: driver) }
            if let drive = Self.counters(statistics: IORegistryReader.dictionary("Statistics", of: driver),
                                         identity: identity) {
                drives.append(drive)
            }
        }
        identities.keep(only: present)
        return drives.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private static func identity(of driver: io_registry_entry_t) -> DriveIdentity {
        let device = IORegistryReader.withParent(of: driver) {
            (IORegistryReader.dictionary("Device Characteristics", of: $0),
             IORegistryReader.dictionary("Protocol Characteristics", of: $0))
        }
        let bsdName = IORegistryReader.withFirstChild(of: driver) {
            IORegistryReader.property("BSD Name", of: $0) as? String
        } ?? nil
        return identity(bsdName: bsdName, device: device?.0, interconnect: device?.1)
    }

    /// Name, BSD-Name und Art eines Treibers aus seinem Gerät und Medium.
    static func identity(bsdName: String?, device: [String: Any]?, interconnect: [String: Any]?) -> DriveIdentity {
        let product = (device?["Product Name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return DriveIdentity(bsdName: bsdName, name: product.isEmpty ? bsdName ?? "" : product,
                             isDiskImage: isDiskImage(interconnect))
    }

    /// Zähler eines Treibers; `nil` ohne Medium, ohne Byte-Zähler oder bei einem Disk-Image.
    static func counters(statistics: [String: Any]?, bsdName: String?, device: [String: Any]?,
                         interconnect: [String: Any]?) -> DriveCounters? {
        counters(statistics: statistics, identity: identity(bsdName: bsdName, device: device, interconnect: interconnect))
    }

    static func counters(statistics: [String: Any]?, identity: DriveIdentity) -> DriveCounters? {
        guard let statistics, let bsdName = identity.bsdName, !identity.isDiskImage,
              let read = IORegistryReader.uint64(statistics["Bytes (Read)"]),
              let written = IORegistryReader.uint64(statistics["Bytes (Write)"]) else { return nil }
        return DriveCounters(
            id: bsdName, name: identity.name, bytesRead: read, bytesWritten: written,
            operations: IORegistryReader.sum(statistics["Operations (Read)"], statistics["Operations (Write)"]),
            busyNanoseconds: IORegistryReader.sum(statistics["Total Time (Read)"], statistics["Total Time (Write)"])
        )
    }

    /// Disk-Images hängen an einer virtuellen Schnittstelle: `AppleDiskImageDevice` meldet den Ort „File“,
    /// `IODiskImageBlockStorageDeviceInKernel` nur „Virtual Interface“.
    static func isDiskImage(_ interconnect: [String: Any]?) -> Bool {
        interconnect?["Physical Interconnect Location"] as? String == "File"
            || interconnect?["Physical Interconnect"] as? String == "Virtual Interface"
    }
}

/// Was ein Laufwerk ausmacht, ohne seine Zähler; ändert sich erst mit einem neuen Treiber.
struct DriveIdentity: Equatable, Sendable {
    /// `nil` ohne Medium.
    let bsdName: String?
    let name: String
    let isDiskImage: Bool
}

/// `DriveIdentity` je Registry-Eintrag eines Treibers (#489). Ein Treiber ohne Medium wird bei jedem Takt neu gelesen,
/// denn sein Medium kann noch erscheinen; verschwundene Treiber vergisst `keep(only:)`.
final class DriveIdentityCache: Sendable {
    private let identities = Mutex<[UInt64: DriveIdentity]>([:])

    func identity(for entryID: UInt64, read: () -> DriveIdentity) -> DriveIdentity {
        if let known = identities.withLock({ $0[entryID] }) { return known }
        let identity = read()
        if identity.bsdName != nil { identities.withLock { $0[entryID] = identity } }
        return identity
    }

    func keep(only entryIDs: Set<UInt64>) {
        identities.withLock { cached in cached = cached.filter { entryIDs.contains($0.key) } }
    }
}
