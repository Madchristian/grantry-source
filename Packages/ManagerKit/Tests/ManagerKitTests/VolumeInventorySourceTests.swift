import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit
import GrantryShared

/// Volumes und Datenträger (#400): Zusammenführung der `diskutil`-Ausgaben, bereinigbarer Platz, lokale Snapshots.
@Suite struct VolumeInventorySourceTests {
    private static let berlin = TimeZone(identifier: "Europe/Berlin")!

    private static func text(_ name: String) throws -> String {
        String(decoding: try DiskutilPlistTests.fixture(name), as: UTF8.self)
    }

    /// Runner mit den Ausgaben eines Macs: interne SSD, auf Wunsch mit externem USB-Gehäuse.
    private static func runner(apfs: String = "apfs-list-internal.plist", disk0: String = "info-disk0-internal.plist",
                               withUSB: Bool = false, snapshots: String = "tmutil-two-snapshots.txt") throws
        -> MockCommandRunner {
        let runner = MockCommandRunner()
        runner.stub("/usr/sbin/diskutil list -plist physical", CommandResult(
            exitCode: 0, stdout: try text(withUSB ? "list-physical-with-usb.plist" : "list-physical-internal.plist")))
        runner.stub("/usr/sbin/diskutil apfs list -plist", CommandResult(exitCode: 0, stdout: try text(apfs)))
        runner.stub("/usr/sbin/diskutil info -plist disk0", CommandResult(exitCode: 0, stdout: try text(disk0)))
        runner.stub("/usr/sbin/diskutil info -plist disk30",
                    CommandResult(exitCode: 0, stdout: try text("info-disk30-usb.plist")))
        runner.stub("/usr/bin/tmutil listlocalsnapshots /", CommandResult(exitCode: 0, stdout: try text(snapshots)))
        return runner
    }

    private static let mounts: [MountedVolume] = [
        MountedVolume(path: "/", isLocal: true, device: "disk3s1s1"),
        MountedVolume(path: "/System/Volumes/Data", isLocal: true, device: "disk3s5"),
        MountedVolume(path: "/System/Volumes/VM", isLocal: true, device: "disk3s6"),
        MountedVolume(path: "/Volumes/Archiv", isLocal: true, device: "disk31s1"),
        MountedVolume(path: "/Volumes/iOS 18.2 Simulator", isLocal: true, device: "disk6s1"),
        MountedVolume(path: "/Volumes/Freigabe", isLocal: false, device: nil),
    ]

    /// Kapazitätsabfrage, die Pfade mitschreibt.
    private final class Capacity: Sendable {
        let paths = Mutex<[String]>([])
        let usage: @Sendable (String) -> VolumeUsage?

        init(_ usage: @escaping @Sendable (String) -> VolumeUsage? = { _ in
            VolumeUsage(totalBytes: 1_000, availableBytes: 100, importantUsageAvailableBytes: 130)
        }) {
            self.usage = usage
        }

        func read(_ path: String) -> VolumeUsage? {
            paths.withLock { $0.append(path) }
            return usage(path)
        }
    }

    private static func source(_ runner: MockCommandRunner, capacity: Capacity = Capacity(),
                               mounts: [MountedVolume] = mounts,
                               callGuard: BlockingCallGuard = BlockingCallGuard(maximumHanging: 1)) -> VolumeInventorySource {
        VolumeInventorySource(runner: runner, mounts: { mounts }, capacity: { capacity.read($0) },
                              callGuard: callGuard, timeZone: berlin)
    }

    @Test func internalSSDWithSeveralVolumesAndSnapshots() async throws {
        let capacity = Capacity()
        let inventory = await Self.source(try Self.runner(), capacity: capacity).inventory()
        #expect(inventory.isComplete)
        let device = try #require(inventory.devices.first)
        #expect(inventory.devices.map(\.id) == ["disk0"])
        #expect(device.smartStatus == .verified)
        // Container auf Disk-Images (Simulator) gehören zu keinem physischen Datenträger.
        #expect(device.containers.map(\.id) == ["disk1", "disk2", "disk3"])
        let main = try #require(device.containers.first { $0.id == "disk3" })
        #expect(main.volumes.first { $0.role == .data }?.mountPoint == "/System/Volumes/Data")
        #expect(main.volumes.first { $0.role == .system }?.mountPoint == "/")
        #expect(main.volumes.first { $0.role == .recovery }?.mountPoint == nil)
        // Kapazität einmal je Container über das Datenvolume; nicht eingehängte Container bleiben ohne.
        #expect(capacity.paths.withLock { $0 } == ["/System/Volumes/Data"])
        #expect(main.usage?.purgeableBytes == 30)
        #expect(device.containers.first { $0.id == "disk1" }?.usage == nil)

        let snapshots = try #require(inventory.localSnapshots)
        #expect(snapshots.count == 2)
        #expect(snapshots.oldest == Self.date(2026, 10, 26, 16, 58, 53))
        #expect(snapshots.newest == Self.date(2026, 11, 6, 15, 1, 54))
    }

    @Test func externalUSBEnclosureWithoutSMART() async throws {
        let capacity = Capacity()
        let inventory = await Self.source(try Self.runner(apfs: "apfs-list-external-usb.plist", withUSB: true),
                                          capacity: capacity).inventory()
        #expect(inventory.isComplete)
        #expect(inventory.devices.map(\.id) == ["disk0", "disk30"])
        let usb = try #require(inventory.devices.last)
        #expect(usb.smartStatus == .notSupported)
        #expect(usb.smartStatus.tone == .neutral)
        #expect(usb.isInternal == false)
        #expect(usb.containers.map(\.id) == ["disk31"])
        #expect(usb.containers.first?.volumes.first?.mountPoint == "/Volumes/Archiv")
        #expect(capacity.paths.withLock { $0 } == ["/System/Volumes/Data", "/Volumes/Archiv"])
    }

    @Test func externalDisksFollowInternalOnes() async throws {
        let runner = try Self.runner(apfs: "apfs-list-external-usb.plist", withUSB: true)
        let layout = """
            <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
            <key>WholeDisks</key><array><string>disk30</string><string>disk0</string></array>
            <key>AllDisksAndPartitions</key><array>
            <dict><key>DeviceIdentifier</key><string>disk30</string><key>Partitions</key><array>
            <dict><key>DeviceIdentifier</key><string>disk30s2</string></dict></array></dict>
            <dict><key>DeviceIdentifier</key><string>disk0</string><key>Partitions</key><array>
            <dict><key>DeviceIdentifier</key><string>disk0s2</string></dict></array></dict>
            </array></dict></plist>
            """
        runner.stub("/usr/sbin/diskutil list -plist physical", CommandResult(exitCode: 0, stdout: layout))
        let inventory = await Self.source(runner).inventory()
        #expect(inventory.devices.map(\.id) == ["disk0", "disk30"])
    }

    @Test func fileVaultOffIsReported() async throws {
        let inventory = await Self.source(try Self.runner(apfs: "apfs-list-filevault-off.plist")).inventory()
        let volumes = inventory.devices.flatMap(\.containers).flatMap(\.volumes)
        #expect(volumes.allSatisfy { !$0.isFileVaultEnabled })
        #expect(volumes.first { $0.role == .data }?.isEncrypted == true)
    }

    @Test func noSnapshotsIsAnEmptySummary() async throws {
        let inventory = await Self.source(try Self.runner(snapshots: "tmutil-none.txt")).inventory()
        let snapshots = try #require(inventory.localSnapshots)
        #expect(snapshots.count == 0)
        #expect(snapshots.oldest == nil && snapshots.newest == nil)
        #expect(inventory.isComplete)
    }

    @Test func failingSMARTIsCritical() async throws {
        let inventory = await Self.source(try Self.runner(disk0: "info-disk0-failing.plist")).inventory()
        #expect(inventory.devices.first?.smartStatus == .failing)
        #expect(inventory.devices.first?.smartStatus.tone == .critical)
    }

    /// Scheitert ein Teil, bleibt der Rest sichtbar, das Ergebnis gilt aber nie als vollständig.
    @Test func failedDiskInfoKeepsTheDeviceAsUnknown() async throws {
        let runner = try Self.runner()
        runner.stub("/usr/sbin/diskutil info -plist disk0", CommandResult(exitCode: 1, stdout: "", stderr: "Fehler"))
        let inventory = await Self.source(runner).inventory()
        #expect(!inventory.isComplete)
        let device = try #require(inventory.devices.first)
        #expect(device.smartStatus == .unknown)
        #expect(device.isInternal == nil)
        #expect(device.containers.map(\.id) == ["disk1", "disk2", "disk3"])
    }

    @Test func failedAPFSListIsIncomplete() async throws {
        let runner = try Self.runner()
        runner.stub("/usr/sbin/diskutil apfs list -plist", CommandResult(exitCode: 0, stdout: "kaputt"))
        let inventory = await Self.source(runner).inventory()
        #expect(!inventory.isComplete)
        #expect(inventory.devices.map(\.id) == ["disk0"])
        #expect(inventory.devices.first?.containers.isEmpty == true)
    }

    @Test func failedLayoutHasNoDevices() async throws {
        let runner = try Self.runner()
        runner.stub("/usr/sbin/diskutil list -plist physical", CommandResult(exitCode: 1, stdout: ""))
        let inventory = await Self.source(runner).inventory()
        #expect(!inventory.isComplete)
        #expect(inventory.devices.isEmpty)
        #expect(!runner.calls.contains { $0.hasPrefix("/usr/sbin/diskutil info") })
    }

    @Test func failedSnapshotListIsUnknown() async throws {
        let runner = try Self.runner()
        runner.stub("/usr/bin/tmutil listlocalsnapshots /", CommandResult(exitCode: 1, stdout: ""))
        let inventory = await Self.source(runner).inventory()
        #expect(inventory.localSnapshots == nil)
        #expect(!inventory.isComplete)
    }

    /// Hängt die Kapazitätsabfrage, wartet die Quelle nur bis zur Frist; danach fragt sie den Guard nicht erneut.
    @Test func hangingCapacityIsGuarded() async throws {
        let release = DispatchSemaphore(value: 0)
        let capacity = Capacity { _ in
            release.wait()
            return nil
        }
        let callGuard = BlockingCallGuard(maximumHanging: 1)
        let source = VolumeInventorySource(runner: try Self.runner(apfs: "apfs-list-external-usb.plist", withUSB: true),
                                           mounts: { Self.mounts }, capacity: { capacity.read($0) },
                                           callGuard: callGuard, timeZone: Self.berlin,
                                           capacityTimeout: .milliseconds(50))
        let inventory = await source.inventory()
        release.signal()
        #expect(!inventory.isComplete)
        #expect(inventory.devices.flatMap(\.containers).allSatisfy { $0.usage == nil })
        // Erste Abfrage hängt, die zweite kehrt wegen des erschöpften Guards sofort zurück.
        #expect(capacity.paths.withLock { $0 } == ["/System/Volumes/Data"])
    }

    /// Netzlaufwerke und fremde Geräte (Disk-Images) fragt die Quelle nie ab.
    @Test func networkMountsAreNeverQueried() async throws {
        let capacity = Capacity()
        _ = await Self.source(try Self.runner(), capacity: capacity).inventory()
        #expect(!capacity.paths.withLock { $0 }.contains("/Volumes/Freigabe"))
        #expect(!capacity.paths.withLock { $0 }.contains("/Volumes/iOS 18.2 Simulator"))
    }

    @Test func commandsHaveATimeoutAndFixedArguments() async throws {
        let runner = try Self.runner(apfs: "apfs-list-external-usb.plist", withUSB: true)
        _ = await Self.source(runner).inventory()
        #expect(Set(runner.calls) == [
            "/usr/sbin/diskutil list -plist physical", "/usr/sbin/diskutil apfs list -plist",
            "/usr/sbin/diskutil info -plist disk0", "/usr/sbin/diskutil info -plist disk30",
            "/usr/bin/tmutil listlocalsnapshots /",
        ])
        #expect(VolumeInventorySource.commandTimeout <= .seconds(15))
    }

    @Test func oversizedOutputIsRejected() async throws {
        let runner = try Self.runner()
        runner.stub("/usr/sbin/diskutil apfs list -plist", CommandResult(
            exitCode: 0, stdout: String(repeating: " ", count: VolumeInventorySource.maximumOutput + 1)))
        let inventory = await Self.source(runner).inventory()
        #expect(!inventory.isComplete)
        #expect(inventory.devices.first?.containers.isEmpty == true)
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = berlin
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute,
                                                  second: second))!
    }
}

@Suite struct LocalSnapshotSummaryTests {
    private static let utc = TimeZone(identifier: "UTC")!

    @Test func oldestAndNewestIgnoreListOrder() throws {
        let summary = LocalSnapshotSummary(snapshotDates: ["2026-10-18-101010", "2026-10-18-111111", "2026-10-12-121509"],
                                           timeZone: Self.utc)
        #expect(summary.count == 3)
        #expect(summary.oldest == Date(timeIntervalSince1970: 1_791_807_309))
        #expect(summary.newest == Date(timeIntervalSince1970: 1_792_321_871))
    }

    @Test func unparsableDatesCountButHaveNoTime() {
        let summary = LocalSnapshotSummary(snapshotDates: ["2026-13-01-000000", "Snapshot", "2026-02-30-120000"],
                                           timeZone: Self.utc)
        #expect(summary.count == 3)
        #expect(summary.oldest == nil && summary.newest == nil)
    }

    @Test func emptyListHasNoDates() {
        let summary = LocalSnapshotSummary(snapshotDates: [], timeZone: Self.utc)
        #expect(summary.count == 0 && summary.oldest == nil && summary.newest == nil)
    }

    /// Ein Parser für Speicher und Datenträger (Issue: kein zweiter Parser).
    @Test func snapshotDatesComeFromTheSharedParser() throws {
        let output = String(decoding: try DiskutilPlistTests.fixture("tmutil-two-snapshots.txt"), as: UTF8.self)
        #expect(TimeMachineSnapshotsProvider.snapshotDates(in: output) == ["2026-10-26-165853", "2026-11-06-150154"])
        #expect(TimeMachineSnapshotsProvider.snapshotDates(in: "Snapshots for disk /:\n").isEmpty)
    }
}

@Suite struct VolumeUsagePurgeableTests {
    @Test func purgeableIsImportantUsageMinusAvailable() {
        let usage = VolumeUsage(totalBytes: 1_000, availableBytes: 248, importantUsageAvailableBytes: 279)
        #expect(usage.purgeableBytes == 31)
    }

    @Test func purgeableIsNeverNegative() {
        let usage = VolumeUsage(totalBytes: 1_000, availableBytes: 248, importantUsageAvailableBytes: 200)
        #expect(usage.purgeableBytes == 0)
    }

    @Test func purgeableIsUnknownWithoutMeasurement() {
        #expect(VolumeUsage(totalBytes: 1_000, availableBytes: 248).purgeableBytes == nil)
    }

    @Test func mountDeviceComesFromTheKernelName() {
        #expect(MountedVolume(mountPoint: "/System/Volumes/Data", isLocal: true, deviceNode: "/dev/disk3s5").device
                    == "disk3s5")
        #expect(MountedVolume(mountPoint: "/Volumes/Freigabe", isLocal: false, deviceNode: "//nas/freigabe").device
                    == nil)
    }
}

/// Opt-in gegen das echte System (`MANAGERKIT_LIVE=1`), nie in der CI: liest Volumes, Datenträger und lokale Snapshots
/// dieses Macs (nur lesend) und meldet Ergebnis und Laufzeit auf der Konsole.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MANAGERKIT_LIVE"] == "1"))
struct VolumeInventoryLiveTests {
    @Test func readsTheRealDisks() async throws {
        let source = VolumeInventorySource()
        var durations: [Duration] = []
        var inventory: VolumeInventory?
        let cpuBefore = Self.cpuSeconds()
        for _ in 0..<5 {
            let start = ContinuousClock.now
            inventory = await source.inventory()
            durations.append(ContinuousClock.now - start)
        }
        let cpu = Self.cpuSeconds()
        let capacityStart = ContinuousClock.now
        _ = VolumeUsage.read("/System/Volumes/Data", includingPurgeable: true)
        Swift.print("Kapazität samt bereinigbarem Platz: \(ContinuousClock.now - capacityStart)")
        Swift.print("CPU je Abruf: eigener Prozess \((cpu.own - cpuBefore.own) / 5) s, Befehle \((cpu.children - cpuBefore.children) / 5) s")
        let result = try #require(inventory)
        for device in result.devices {
            Swift.print("[\(device.id)] \(device.name ?? "?") · \(device.busProtocol ?? "?") · intern: \(String(describing: device.isInternal)) · SMART \(device.smartStatus.title)")
            for container in device.containers {
                let purgeable = container.usage?.purgeableBytes.map(AppTexts.formattedSize) ?? "?"
                Swift.print("  \(container.id): \(container.volumes.count) Volumes, bereinigbar \(purgeable)")
                for volume in container.volumes {
                    Swift.print("    \(volume.id) \(volume.role?.title ?? "–") \(AppTexts.formattedSize(volume.usedBytes)) FileVault: \(volume.isFileVaultEnabled) \(volume.mountPoint ?? "")")
                }
            }
        }
        Swift.print("Snapshots: \(String(describing: result.localSnapshots)), vollständig: \(result.isComplete)")
        Swift.print("Laufzeiten: \(durations.map { $0.formatted(.units(allowed: [.milliseconds])) })")
        #expect(!result.devices.isEmpty)
        #expect(result.devices.allSatisfy { $0.smartStatus != .unknown })
    }

    /// Benutzer- plus Systemzeit des Testprozesses und seiner beendeten Kindprozesse.
    private static func cpuSeconds() -> (own: Double, children: Double) {
        func seconds(_ who: Int32) -> Double {
            var usage = rusage()
            getrusage(who, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        return (seconds(RUSAGE_SELF), seconds(RUSAGE_CHILDREN))
    }
}
