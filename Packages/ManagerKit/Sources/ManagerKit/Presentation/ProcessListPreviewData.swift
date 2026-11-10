#if DEBUG
import Foundation

/// Fester Stand des Prozess-Tabs für SwiftUI-Previews und Snapshots – ohne Systemzugriff. Werte so gewählt, dass jede
/// Heatmap-Stufe vorkommt; fremde Prozesse ohne Zähler wie auf einem echten Mac ohne Root.
public enum ProcessListPreviewData {
    public static let currentUID: UInt32 = 501
    public static let physicalMemory: UInt64 = 32 << 30

    public static let apps = [
        RunningApp(pid: 610, bundleID: "com.apple.Safari", bundlePath: "/Applications/Safari.app", name: "Safari"),
        RunningApp(pid: 720, bundleID: "com.apple.dt.Xcode", bundlePath: "/Applications/Xcode.app", name: "Xcode"),
        RunningApp(pid: 830, bundleID: "com.apple.mail", bundlePath: "/System/Applications/Mail.app", name: "Mail"),
        RunningApp(pid: 840, bundleID: "com.apple.Music", bundlePath: "/System/Applications/Music.app", name: "Musik"),
    ]

    public static var snapshot: TaskManagerSnapshot {
        var snapshot = TaskManagerSnapshot()
        snapshot.processes = [
            own(610, "Safari", cpu: 0.012, memory: 420, path: "/Applications/Safari.app/Contents/MacOS/Safari"),
            own(612, "Safari Web Content", parent: 610, cpu: 0.084, memory: 1_640, disk: 0.4e6),
            own(613, "Safari Graphics and Media", parent: 610, cpu: 0.021, memory: 310),
            own(720, "Xcode", cpu: 0.035, memory: 2_400, disk: 3.2e6,
                path: "/Applications/Xcode.app/Contents/MacOS/Xcode"),
            own(721, "SourceKitService", parent: 720, cpu: 0.11, memory: 1_100, disk: 0.8e6),
            own(722, "XCBBuildService", parent: 720, cpu: 0.02, memory: 600, disk: 12e6),
            own(830, "Mail", cpu: 0.002, memory: 260, path: "/System/Applications/Mail.app/Contents/MacOS/Mail"),
            own(840, "Musik", cpu: 0.006, memory: 180, path: "/System/Applications/Music.app/Contents/MacOS/Music"),
            own(2_001, "claude", cpu: 0.062, memory: 780),
            own(2_002, "codex", cpu: 0.015, memory: 320),
            own(2_003, "Dropbox", cpu: 0.004, memory: 410, disk: 2.1e6),
            own(2_004, "photoanalysisd", cpu: 0.155, memory: 640, disk: 18e6),
            own(2_005, "zsh", cpu: 0, memory: 4),
            foreign(88, "WindowServer", uid: 88),
            foreign(1, "launchd", uid: 0),
            foreign(0, "kernel_task", uid: 0),
            foreign(412, "mds_stores", uid: 0),
        ]
        return snapshot
    }

    /// Netzrate je Prozess (`NetworkActivityModel.processRates`).
    public static var network: [ProcessKey: Double] {
        [key(612): 2.4e6, key(840): 340e3, key(2_001): 1.2e6, key(2_002): 85e3, key(2_003): 6.5e6, key(412): 0]
    }

    /// CPU und Speicher fremder Prozesse wie von `ps` (`ForeignProcessUsageModel`).
    public static var foreignUsage: [Int32: ForeignProcessUsage] {
        [88: ForeignProcessUsage(uid: 88, cpuLoad: 0.064, residentBytes: 890 << 20),
         1: ForeignProcessUsage(uid: 0, cpuLoad: 0.001, residentBytes: 32 << 20),
         0: ForeignProcessUsage(uid: 0, cpuLoad: 0.021, residentBytes: 6 << 20),
         412: ForeignProcessUsage(uid: 0, cpuLoad: 0.143, residentBytes: 210 << 20)]
    }

    public static var presentation: ProcessListPresentation {
        var options = ProcessListOptions()
        options.expandedEntries = ["app:720"]
        return ProcessListPresenter.present(snapshot.fillingForeignUsage(foreignUsage, currentUID: currentUID),
                                            apps: apps, currentUID: currentUID, network: network, options: options,
                                            physicalMemory: physicalMemory)
    }

    private static func key(_ pid: Int32) -> ProcessKey { ProcessKey(pid: pid, startTime: 1) }

    /// - Parameter memory: in MiB.
    private static func own(_ pid: Int32, _ name: String, parent: Int32 = 1, cpu: Double, memory: UInt64,
                            disk: Double = 0, path: String? = nil) -> ProcessMeasurement {
        ProcessMeasurement(key: key(pid), parentPID: parent, uid: currentUID, name: name, cpuLoad: cpu,
                           memoryBytes: memory << 20, diskReadPerSecond: disk * 0.7, diskWritePerSecond: disk * 0.3,
                           threadCount: 8, executablePath: path ?? "/usr/local/bin/\(name)")
    }

    private static func foreign(_ pid: Int32, _ name: String, uid: UInt32) -> ProcessMeasurement {
        ProcessMeasurement(key: key(pid), parentPID: 1, uid: uid, name: name, cpuLoad: nil, memoryBytes: nil,
                           diskReadPerSecond: nil, diskWritePerSecond: nil, threadCount: nil)
    }
}
#endif
