import Foundation
import Testing
@testable import ManagerKit

/// Parser für `diskutil list -plist physical`, `diskutil info -plist` und `diskutil apfs list -plist` (#400) mit echten
/// Ausgaben eines M4 Max (UUIDs ersetzt) und daraus abgeleiteten Sonderfällen.
@Suite struct DiskutilPlistTests {
    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/Volumes"))
        return try Data(contentsOf: url)
    }

    @Test func physicalLayoutMapsPartitionsToTheirWholeDisk() throws {
        let layout = try #require(DiskutilPlist.physicalLayout(Self.fixture("list-physical-with-usb.plist")))
        #expect(layout.wholeDisks == ["disk0", "disk30"])
        #expect(layout.wholeDisk(of: "disk0s2") == "disk0")
        #expect(layout.wholeDisk(of: "disk30s2") == "disk30")
        #expect(layout.wholeDisk(of: "disk30") == "disk30")
        // Physischer Speicher eines Disk-Images (Simulator-Laufzeit) gehört zu keinem physischen Datenträger.
        #expect(layout.wholeDisk(of: "disk4s1") == nil)
        #expect(layout.wholeDisk(of: "disk10s1") == nil)
    }

    @Test func internalSSDIsVerified() throws {
        let device = try #require(DiskutilPlist.device(Self.fixture("info-disk0-internal.plist")))
        #expect(device.id == "disk0")
        #expect(device.name == "APPLE SSD AP1024Z")
        #expect(device.busProtocol == "Apple Fabric")
        #expect(device.isInternal == true)
        #expect(device.isSolidState == true)
        #expect(device.sizeBytes == 1_000_555_581_440)
        #expect(device.smartStatus == .verified)
        #expect(device.containers.isEmpty)
    }

    @Test func externalUSBEnclosureHasNoSMART() throws {
        let device = try #require(DiskutilPlist.device(Self.fixture("info-disk30-usb.plist")))
        #expect(device.id == "disk30")
        #expect(device.name == "Portable SSD")
        #expect(device.busProtocol == "USB")
        #expect(device.isInternal == false)
        #expect(device.smartStatus == .notSupported)
    }

    @Test func failingSMARTIsRecognized() throws {
        #expect(try DiskutilPlist.device(Self.fixture("info-disk0-failing.plist"))?.smartStatus == .failing)
    }

    @Test func apfsListKeepsContainersWithRolesAndUsedSize() throws {
        let containers = try #require(DiskutilPlist.containers(Self.fixture("apfs-list-internal.plist")))
        #expect(containers.map(\.id) == ["disk1", "disk2", "disk3", "disk6"])
        let main = try #require(containers.first { $0.id == "disk3" })
        #expect(main.capacityBytes == 994_662_584_320)
        #expect(main.freeBytes == 98_806_865_920)
        #expect(main.physicalStores == ["disk0s2"])
        #expect(main.volumes.map(\.id) == ["disk3s1", "disk3s2", "disk3s3", "disk3s4", "disk3s5", "disk3s6"])
        #expect(main.volumes.map(\.role) == [.system, .preboot, .recovery, .update, .data, .vm])
        let data = try #require(main.volumes.first { $0.role == .data })
        #expect(data.name == "Data")
        #expect(data.usedBytes == 870_650_318_848)
        #expect(data.isEncrypted && data.isFileVaultEnabled && !data.isLocked)
        #expect(data.mountPoint == nil)
        // Rollen außerhalb der bekannten bleiben erhalten, Volumes ohne Rolle haben keine.
        let isc = try #require(containers.first { $0.id == "disk1" })
        #expect(isc.volumes.map(\.role) == [.preboot, .other("xART"), .other("Hardware"), .recovery])
        #expect(containers.last?.volumes.first?.role == nil)
    }

    @Test func fileVaultOffKeepsHardwareEncryption() throws {
        let containers = try #require(DiskutilPlist.containers(Self.fixture("apfs-list-filevault-off.plist")))
        let data = try #require(containers.flatMap(\.volumes).first { $0.role == .data })
        #expect(data.isEncrypted)
        #expect(!data.isFileVaultEnabled)
    }

    @Test func foreignVolumeNamesAreOneBoundedLine() throws {
        let containers = try #require(DiskutilPlist.containers(Self.fixture("apfs-list-external-usb.plist")))
        let volume = try #require(containers.first { $0.id == "disk31" }?.volumes.first)
        #expect(volume.name == "Archiv extern")
        #expect(!volume.isEncrypted && !volume.isFileVaultEnabled)

        let long = String(repeating: "x", count: 500)
        let plist: [String: Any] = ["Containers": [[
            "ContainerReference": "disk9", "CapacityCeiling": 10, "CapacityFree": 5,
            "PhysicalStores": [["DeviceIdentifier": "disk8s2"]],
            "Volumes": [["DeviceIdentifier": "disk9s1", "Name": long, "Roles": [], "CapacityInUse": 1]],
        ]]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let name = try #require(DiskutilPlist.containers(data)?.first?.volumes.first?.name)
        #expect(name.count == DiskutilPlist.maximumNameLength)
        #expect(name.hasSuffix("…"))
    }

    @Test func implausibleIdentifiersAreDropped() throws {
        let plist: [String: Any] = ["Containers": [
            ["ContainerReference": "disk3; rm", "CapacityCeiling": 1, "CapacityFree": 1, "PhysicalStores": [],
             "Volumes": []],
            ["ContainerReference": "disk7", "CapacityCeiling": 1, "CapacityFree": 1,
             "PhysicalStores": [["DeviceIdentifier": "../disk1"], ["DeviceIdentifier": "disk6s1"]],
             "Volumes": [["DeviceIdentifier": "disk7s1 x", "Name": "A", "CapacityInUse": 1],
                         ["DeviceIdentifier": "disk7s2", "Name": "B", "CapacityInUse": 1]]],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let containers = try #require(DiskutilPlist.containers(data))
        #expect(containers.map(\.id) == ["disk7"])
        #expect(containers.first?.physicalStores == ["disk6s1"])
        #expect(containers.first?.volumes.map(\.id) == ["disk7s2"])
    }

    @Test func unreadableOutputIsNil() {
        let garbage = Data("kein plist".utf8)
        #expect(DiskutilPlist.physicalLayout(garbage) == nil)
        #expect(DiskutilPlist.device(garbage) == nil)
        #expect(DiskutilPlist.containers(garbage) == nil)
    }

    @Test(arguments: [
        ("Verified", SMARTStatus.verified), ("Failing", .failing), ("About to Fail", .failing),
        ("Not Supported", .notSupported), ("", .unknown), ("Etwas Neues", .unknown),
    ])
    func smartStatusFromDiskutil(raw: String, expected: SMARTStatus) {
        #expect(SMARTStatus(diskutil: raw) == expected)
    }

    @Test func smartStatusWithoutValueIsUnknown() {
        #expect(SMARTStatus(diskutil: nil) == .unknown)
    }

    /// Abbildung laut Issue: verifiziert positiv, Fehler kritisch, nicht unterstützt neutral – „unbekannt“ ist nie
    /// eine Entwarnung.
    @Test func smartToneMapping() {
        #expect(SMARTStatus.verified.tone == .positive)
        #expect(SMARTStatus.failing.tone == .critical)
        #expect(SMARTStatus.notSupported.tone == .neutral)
        #expect(SMARTStatus.unknown.tone == .neutral)
        #expect(SMARTStatus.allCases.map(\.title) == ["verifiziert", "Fehler", "nicht unterstützt", "unbekannt"])
    }

    @Test func roleTitles() {
        #expect(APFSVolumeRole.system.title == "System")
        #expect(APFSVolumeRole.data.title == "Daten")
        #expect(APFSVolumeRole.vm.title == "VM")
        #expect(APFSVolumeRole.preboot.title == "Preboot")
        #expect(APFSVolumeRole.recovery.title == "Wiederherstellung")
        #expect(APFSVolumeRole.update.title == "Update")
        #expect(APFSVolumeRole.other("xART").title == "xART")
    }
}
