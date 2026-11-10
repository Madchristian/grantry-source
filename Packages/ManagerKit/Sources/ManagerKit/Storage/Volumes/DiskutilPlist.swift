import Foundation
import GrantryShared

/// Parser für die Plist-Ausgaben von `diskutil` (#400). Nur die genannten Schlüssel zählen, alle anderen bleiben
/// unbeachtet. Gerätekennungen müssen wie „disk3s5“ aussehen – sonst fällt der Eintrag weg, denn sie werden später
/// als Argument an `diskutil` gereicht. Namen kommen von Benutzern oder Herstellern und laufen durch
/// `DisplayText.singleLine` mit Längengrenze. `nil`, wenn die Ausgabe kein lesbares Plist ist.
enum DiskutilPlist {
    /// Längste angezeigte Namen (Volumes, Modelle, Anschlüsse).
    static let maximumNameLength = 64

    /// Physische Datenträger laut `diskutil list -plist physical` (ohne Disk-Images und synthetische APFS-Datenträger).
    struct PhysicalLayout: Hashable, Sendable {
        let wholeDisks: [String]
        private let wholeDiskByIdentifier: [String: String]

        init(wholeDisks: [String], partitions: [String: [String]]) {
            self.wholeDisks = wholeDisks
            var map: [String: String] = [:]
            for disk in wholeDisks {
                map[disk] = disk
                for partition in partitions[disk] ?? [] { map[partition] = disk }
            }
            wholeDiskByIdentifier = map
        }

        /// Ganzer physischer Datenträger, zu dem `identifier` gehört; `nil` für alles andere (etwa Disk-Images).
        func wholeDisk(of identifier: String) -> String? { wholeDiskByIdentifier[identifier] }
    }

    static func physicalLayout(_ data: Data) -> PhysicalLayout? {
        guard let output = dictionary(data), let wholeDisks = output["WholeDisks"] as? [String] else { return nil }
        let partitions = dictionaries(output["AllDisksAndPartitions"]).reduce(into: [String: [String]]()) { result, disk in
            guard let wholeDisk = identifier(disk["DeviceIdentifier"]) else { return }
            result[wholeDisk] = dictionaries(disk["Partitions"]).compactMap { identifier($0["DeviceIdentifier"]) }
        }
        return PhysicalLayout(wholeDisks: wholeDisks.filter(isDeviceIdentifier), partitions: partitions)
    }

    /// Datenträger laut `diskutil info -plist <disk>`, noch ohne Container.
    static func device(_ data: Data) -> StorageDevice? {
        guard let output = dictionary(data), let id = identifier(output["DeviceIdentifier"]) else { return nil }
        return StorageDevice(id: id, name: displayName(output["MediaName"]),
                             busProtocol: displayName(output["BusProtocol"]), isInternal: output["Internal"] as? Bool,
                             isSolidState: output["SolidState"] as? Bool, sizeBytes: output["Size"] as? Int64,
                             smartStatus: SMARTStatus(diskutil: output["SMARTStatus"] as? String))
    }

    /// APFS-Container laut `diskutil apfs list -plist`, in dessen Reihenfolge.
    static func containers(_ data: Data) -> [APFSContainer]? {
        guard let output = dictionary(data), output["Containers"] is [Any] else { return nil }
        return dictionaries(output["Containers"]).compactMap { container in
            guard let id = identifier(container["ContainerReference"]) else { return nil }
            return APFSContainer(id: id, capacityBytes: bytes(container["CapacityCeiling"]),
                                 freeBytes: bytes(container["CapacityFree"]),
                                 physicalStores: dictionaries(container["PhysicalStores"])
                                     .compactMap { identifier($0["DeviceIdentifier"]) },
                                 volumes: dictionaries(container["Volumes"]).compactMap(volume))
        }
    }

    private static func volume(_ volume: [String: Any]) -> APFSVolume? {
        guard let id = identifier(volume["DeviceIdentifier"]) else { return nil }
        return APFSVolume(id: id, name: displayName(volume["Name"]) ?? id,
                          role: (volume["Roles"] as? [String])?.first.map(APFSVolumeRole.init(diskutil:)),
                          usedBytes: bytes(volume["CapacityInUse"]), isEncrypted: volume["Encryption"] as? Bool ?? false,
                          isFileVaultEnabled: volume["FileVault"] as? Bool ?? false,
                          isLocked: volume["Locked"] as? Bool ?? false)
    }

    /// „disk3“, „disk3s5“, „disk3s1s1“ – nichts, was ein Argument oder einen Pfad verändern könnte.
    static func isDeviceIdentifier(_ text: String) -> Bool {
        text.wholeMatch(of: /disk[0-9]{1,4}(s[0-9]{1,4}){0,2}/) != nil
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let text = value as? String, isDeviceIdentifier(text) else { return nil }
        return text
    }

    private static func displayName(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let line = DisplayText.singleLine(text, maximumLength: maximumNameLength)
        return line.isEmpty ? nil : line
    }

    /// Größe in Bytes, nie negativ; fehlt sie, 0.
    private static func bytes(_ value: Any?) -> Int64 { max(0, value as? Int64 ?? 0) }

    private static func dictionary(_ data: Data) -> [String: Any]? {
        try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private static func dictionaries(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }
}
