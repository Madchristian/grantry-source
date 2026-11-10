import Foundation
import GrantryShared

/// Liest Volumes und Datenträger (TM15, #400) auf Abruf, ohne Takt, ohne Root und ohne Helper.
///
/// `diskutil list -plist physical` nennt die physischen Datenträger (Disk-Images und Netzlaufwerke kommen dort nicht
/// vor), `diskutil info -plist <disk>` je Datenträger Modell, Anschluss und SMART-Zustand, `diskutil apfs list -plist`
/// die Container mit Volumes, Rollen und belegter Größe; `tmutil listlocalsnapshots /` die lokalen Snapshots. Jeder
/// Befehl hat Frist und Ausgabegrenze. Den bereinigbaren Platz fragt die Quelle je eingehängtem Container einmal beim
/// Dateisystem ab – nur über lokale Einhängepunkte von Geräten dieser Container, mit Frist über `BlockingCallGuard`.
public final class VolumeInventorySource: Sendable {
    static let diskutil = "/usr/sbin/diskutil"
    static let layoutArguments = ["list", "-plist", "physical"]
    static let containerArguments = ["apfs", "list", "-plist"]
    static let commandTimeout: Duration = .seconds(10)
    /// `apfs list` ist mit vielen Simulator-Laufzeiten etwa 30 KB groß.
    static let maximumOutput = 2 * 1024 * 1024
    static let defaultCapacityTimeout: Duration = .seconds(5)

    private let runner: any CommandRunning
    private let mounts: @Sendable () -> [MountedVolume]
    private let capacity: @Sendable (String) -> VolumeUsage?
    private let callGuard: BlockingCallGuard
    private let timeZone: TimeZone
    private let capacityTimeout: Duration
    private let workQueue = BlockingWorkQueue(label: "volume-inventory")

    public convenience init() {
        self.init(runner: ProcessCommandRunner(), mounts: MountedVolume.current,
                  capacity: { VolumeUsage.read($0, includingPurgeable: true) }, callGuard: .volumes, timeZone: .current)
    }

    init(runner: any CommandRunning, mounts: @escaping @Sendable () -> [MountedVolume],
         capacity: @escaping @Sendable (String) -> VolumeUsage?, callGuard: BlockingCallGuard, timeZone: TimeZone,
         capacityTimeout: Duration = defaultCapacityTimeout) {
        self.runner = runner
        self.mounts = mounts
        self.capacity = capacity
        self.callGuard = callGuard
        self.timeZone = timeZone
        self.capacityTimeout = capacityTimeout
    }

    public func inventory() async -> VolumeInventory {
        async let layoutOutput = output(Self.diskutil, Self.layoutArguments)
        async let containerOutput = output(Self.diskutil, Self.containerArguments)
        async let snapshots = localSnapshots()
        let layout = await layoutOutput.flatMap(DiskutilPlist.physicalLayout)
        let containers = await containerOutput.flatMap(DiskutilPlist.containers)
        var isComplete = layout != nil && containers != nil

        var devices: [StorageDevice] = []
        for disk in layout?.wholeDisks ?? [] {
            let info = await output(Self.diskutil, ["info", "-plist", disk]).flatMap(DiskutilPlist.device)
                .flatMap { $0.id == disk ? $0 : nil }
            if info == nil { isComplete = false }
            var device = info ?? StorageDevice(id: disk)
            device.containers = (containers ?? []).filter { container in
                container.physicalStores.first.flatMap { layout?.wholeDisk(of: $0) } == disk
            }
            devices.append(device)
        }
        let measured = await measured(devices)
        let localSnapshots = await snapshots
        return VolumeInventory(devices: Self.sorted(measured.devices), localSnapshots: localSnapshots,
                               isComplete: isComplete && measured.isComplete && localSnapshots != nil)
    }

    /// Interne Datenträger zuerst, sonst stabil in der Reihenfolge von `diskutil`.
    private static func sorted(_ devices: [StorageDevice]) -> [StorageDevice] {
        devices.enumerated().sorted { lhs, rhs in
            let left = lhs.element.isInternal == true, right = rhs.element.isInternal == true
            return left != right ? left : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Ergänzt Einhängepunkte und je eingehängtem Container die Kapazität samt bereinigbarem Platz. `isComplete` ist
    /// `false`, wenn eine Kapazitätsabfrage scheiterte oder ihre Frist überschritt.
    private func measured(_ devices: [StorageDevice]) async -> (devices: [StorageDevice], isComplete: Bool) {
        await workQueue.run { [mounts, capacity, callGuard, capacityTimeout] in
            let localMounts = mounts().filter { $0.isLocal && $0.device != nil }
            var isComplete = true
            let devices = devices.map { device in
                var device = device
                device.containers = device.containers.map { container in
                    var container = container
                    container.volumes = container.volumes.map { volume in
                        var volume = volume
                        volume.mountPoint = Self.mountPoint(of: volume.id, in: localMounts)
                        return volume
                    }
                    guard let path = Self.capacityPath(of: container) else { return container }
                    container.usage = callGuard.run(timeout: capacityTimeout) { capacity(path) } ?? nil
                    if container.usage == nil { isComplete = false }
                    return container
                }
                return device
            }
            return (devices, isComplete)
        }
    }

    /// Einhängepunkt eines Volumes; das Systemvolume ist als versiegelter Snapshot eingehängt („disk3s1s1“).
    private static func mountPoint(of volume: String, in mounts: [MountedVolume]) -> String? {
        mounts.first { $0.device == volume }?.path ?? mounts.first { $0.device?.hasPrefix(volume + "s") == true }?.path
    }

    /// Über diesen Pfad misst das Dateisystem den ganzen Container: bevorzugt das Datenvolume, sonst das erste
    /// eingehängte Volume.
    private static func capacityPath(of container: APFSContainer) -> String? {
        container.volumes.first { $0.role == .data && $0.mountPoint != nil }?.mountPoint
            ?? container.volumes.lazy.compactMap(\.mountPoint).first
    }

    private func localSnapshots() async -> LocalSnapshotSummary? {
        guard let output = await output(TimeMachineSnapshotsProvider.tmutil, TimeMachineSnapshotsProvider.listArguments)
        else { return nil }
        let text = String(decoding: output, as: UTF8.self)
        return LocalSnapshotSummary(snapshotDates: TimeMachineSnapshotsProvider.snapshotDates(in: text),
                                    timeZone: timeZone)
    }

    /// stdout eines erfolgreichen Befehls; `nil` bei Fehler, Frist oder zu großer Ausgabe.
    private func output(_ executable: String, _ arguments: [String]) async -> Data? {
        guard let result = try? await runner.run(executable, arguments, timeout: Self.commandTimeout,
                                                 outputLimit: Self.maximumOutput),
              result.succeeded else { return nil }
        return Data(result.stdout.utf8)
    }
}
