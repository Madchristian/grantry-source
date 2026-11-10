import Foundation
import GrantryShared

/// Volumes und Datenträger dieses Macs (TM15, #400): physische Datenträger mit ihren APFS-Containern sowie die lokalen
/// Time-Machine-Snapshots des Startvolumes. Nur gelesen, auf Abruf (`VolumeInventorySource`).
public struct VolumeInventory: Hashable, Sendable {
    /// Interne Datenträger zuerst, sonst in der Reihenfolge von `diskutil`.
    public let devices: [StorageDevice]
    /// `nil`, wenn `tmutil` nichts Lesbares lieferte.
    public let localSnapshots: LocalSnapshotSummary?
    /// `false`, sobald eine Abfrage scheiterte oder ihre Frist überschritt – fehlende Angaben sind dann unbekannt,
    /// nicht unauffällig.
    public let isComplete: Bool

    public init(devices: [StorageDevice], localSnapshots: LocalSnapshotSummary?, isComplete: Bool) {
        self.devices = devices
        self.localSnapshots = localSnapshots
        self.isComplete = isComplete
    }
}

/// Physischer Datenträger laut `diskutil info -plist <disk>`. Ist die Abfrage gescheitert, bleiben die Angaben `nil`
/// und der SMART-Zustand `unknown`.
public struct StorageDevice: Hashable, Sendable, Identifiable {
    /// Gerätekennung des ganzen Datenträgers („disk0“).
    public let id: String
    /// Modellname (`MediaName`), eine Zeile mit Längengrenze.
    public let name: String?
    /// Anschluss (`BusProtocol`: „Apple Fabric“, „USB“, „Thunderbolt“ …).
    public let busProtocol: String?
    public let isInternal: Bool?
    public let isSolidState: Bool?
    public let sizeBytes: Int64?
    public let smartStatus: SMARTStatus
    /// APFS-Container, deren erster physischer Speicher auf diesem Datenträger liegt.
    public var containers: [APFSContainer]

    public init(id: String, name: String? = nil, busProtocol: String? = nil, isInternal: Bool? = nil,
                isSolidState: Bool? = nil, sizeBytes: Int64? = nil, smartStatus: SMARTStatus = .unknown,
                containers: [APFSContainer] = []) {
        self.id = id
        self.name = name
        self.busProtocol = busProtocol
        self.isInternal = isInternal
        self.isSolidState = isSolidState
        self.sizeBytes = sizeBytes
        self.smartStatus = smartStatus
        self.containers = containers
    }
}

/// SMART-Zustand laut `diskutil` (`SMARTStatus`). Externe Gehäuse reichen SMART meist nicht durch („Not Supported“).
public enum SMARTStatus: String, Hashable, Sendable, CaseIterable {
    case verified, failing, notSupported, unknown

    /// „Verified“, „Not Supported“; alles mit „Fail“ („Failing“, „About to Fail“) gilt als Fehler, Unbekanntes als
    /// unbekannt.
    init(diskutil value: String?) {
        switch value?.trimmingCharacters(in: .whitespaces) {
        case "Verified": self = .verified
        case "Not Supported": self = .notSupported
        case let value? where value.localizedCaseInsensitiveContains("fail"): self = .failing
        default: self = .unknown
        }
    }

    public var title: String {
        switch self {
        case .verified: "verifiziert"
        case .failing: "Fehler"
        case .notSupported: "nicht unterstützt"
        case .unknown: "unbekannt"
        }
    }

    /// Verifiziert positiv, Fehler kritisch; „nicht unterstützt“ und „unbekannt“ sind neutral, nie eine Entwarnung.
    public var tone: PresentationTone {
        switch self {
        case .verified: .positive
        case .failing: .critical
        case .notSupported, .unknown: .neutral
        }
    }
}

/// APFS-Container laut `diskutil apfs list -plist`. Seine Volumes teilen sich den Platz.
public struct APFSContainer: Hashable, Sendable, Identifiable {
    /// Gerätekennung des Containers („disk3“).
    public let id: String
    /// `CapacityCeiling`.
    public let capacityBytes: Int64
    /// `CapacityFree`.
    public let freeBytes: Int64
    /// Partitionen, auf denen der Container liegt („disk0s2“).
    public let physicalStores: [String]
    public var volumes: [APFSVolume]
    /// Kapazität laut Dateisystem samt bereinigbarem Platz; nur für eingehängte Container.
    public var usage: VolumeUsage?

    public init(id: String, capacityBytes: Int64, freeBytes: Int64, physicalStores: [String], volumes: [APFSVolume],
                usage: VolumeUsage? = nil) {
        self.id = id
        self.capacityBytes = capacityBytes
        self.freeBytes = freeBytes
        self.physicalStores = physicalStores
        self.volumes = volumes
        self.usage = usage
    }
}

/// Volume eines APFS-Containers.
public struct APFSVolume: Hashable, Sendable, Identifiable {
    /// Gerätekennung („disk3s5“).
    public let id: String
    /// Name, eine Zeile mit Längengrenze (vom Benutzer oder Dritten gewählt).
    public let name: String
    /// Erste Rolle laut APFS; `nil` für gewöhnliche Volumes ohne Rolle.
    public let role: APFSVolumeRole?
    /// `CapacityInUse`.
    public let usedBytes: Int64
    /// Verschlüsselt (`Encryption`); auf Apple Silicon auch ohne FileVault.
    public let isEncrypted: Bool
    public let isFileVaultEnabled: Bool
    public let isLocked: Bool
    /// Einhängepunkt laut Kernel; `nil`, wenn nicht eingehängt.
    public var mountPoint: String?

    public init(id: String, name: String, role: APFSVolumeRole?, usedBytes: Int64, isEncrypted: Bool,
                isFileVaultEnabled: Bool, isLocked: Bool, mountPoint: String? = nil) {
        self.id = id
        self.name = name
        self.role = role
        self.usedBytes = usedBytes
        self.isEncrypted = isEncrypted
        self.isFileVaultEnabled = isFileVaultEnabled
        self.isLocked = isLocked
        self.mountPoint = mountPoint
    }
}

/// Rolle eines Volumes im APFS-Container.
public enum APFSVolumeRole: Hashable, Sendable {
    case system, data, vm, preboot, recovery, update
    /// Weitere Rollen („xART“, „Hardware“, „Backup“ …), Name als eine Zeile.
    case other(String)

    init(diskutil value: String) {
        self = switch value {
        case "System": .system
        case "Data": .data
        case "VM": .vm
        case "Preboot": .preboot
        case "Recovery": .recovery
        case "Update": .update
        default: .other(DisplayText.singleLine(value, maximumLength: DiskutilPlist.maximumNameLength))
        }
    }

    public var title: String {
        switch self {
        case .system: "System"
        case .data: "Daten"
        case .vm: "VM"
        case .preboot: "Preboot"
        case .recovery: "Wiederherstellung"
        case .update: "Update"
        case .other(let name): name
        }
    }
}

/// Lokale Time-Machine-Snapshots des Startvolumes: Anzahl, ältester und jüngster. Größen misst nur Root.
public struct LocalSnapshotSummary: Hashable, Sendable {
    public let count: Int
    public let oldest: Date?
    public let newest: Date?

    /// `snapshotDates` aus `TimeMachineSnapshotsProvider.snapshotDates(in:)` („2026-11-06-150154“, Ortszeit).
    /// Unlesbare Daten zählen mit, bestimmen aber weder ältesten noch jüngsten.
    public init(snapshotDates: [String], timeZone: TimeZone) {
        let dates = snapshotDates.compactMap { Self.date($0, timeZone: timeZone) }
        count = snapshotDates.count
        oldest = dates.min()
        newest = dates.max()
    }

    public init(count: Int, oldest: Date?, newest: Date?) {
        self.count = count
        self.oldest = oldest
        self.newest = newest
    }

    static func date(_ name: String, timeZone: TimeZone) -> Date? {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              parts[3].count == 6, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let time = Int(parts[3]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: year, month: month, day: day, hour: time / 10_000,
                                        minute: time / 100 % 100, second: time % 100)
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }
}
