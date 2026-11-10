#if DEBUG
import Foundation

/// Fester Stand des Tabs „Benutzer“ für SwiftUI-Previews und Snapshots – ohne Systemzugriff: die Prozesse aus
/// `ProcessListPreviewData` (mara, root, `_windowserver`) und ein zweiter Benutzer per SSH.
public enum UserUsagePreviewData {
    public static let currentUID = ProcessListPreviewData.currentUID
    public static let measuredAt = ProcessDetailPreviewData.measuredAt
    public static let userNames = ProcessDetailPreviewData.userNames.merging([502: "jonas"]) { first, _ in first }

    public static let sessions = [
        LoginSession(user: "mara", line: "console", host: nil, loginDate: measuredAt.addingTimeInterval(-93_600)),
        LoginSession(user: "mara", line: "ttys001", host: nil, loginDate: measuredAt.addingTimeInterval(-7_260)),
        LoginSession(user: "mara", line: "ttys002", host: nil, loginDate: measuredAt.addingTimeInterval(-1_380)),
        LoginSession(user: "jonas", line: "ttys004", host: "10.0.0.7",
                     loginDate: measuredAt.addingTimeInterval(-2_940)),
    ]

    public static var snapshot: TaskManagerSnapshot {
        var snapshot = ProcessListPreviewData.snapshot
            .fillingForeignUsage(ProcessListPreviewData.foreignUsage, currentUID: currentUID)
        snapshot.processes += [
            remote(3_101, "sshd-session", cpu: 0.004, memory: 9),
            remote(3_102, "zsh", cpu: 0.001, memory: 6),
            remote(3_103, "python3", cpu: 0.182, memory: 1_250),
            remote(3_104, "vim", cpu: 0.002, memory: 24),
        ]
        return snapshot
    }

    public static var presentation: UserUsagePresentation {
        UserUsagePresenter.present(snapshot, sessions: sessions, currentUID: currentUID,
                                   network: ProcessListPreviewData.network, userName: { userNames[$0] ?? String($0) },
                                   physicalMemory: ProcessListPreviewData.physicalMemory)
    }

    /// Prozess von jonas mit Werten wie aus `ps`; `memory` in MiB.
    private static func remote(_ pid: Int32, _ name: String, cpu: Double, memory: UInt64) -> ProcessMeasurement {
        ProcessMeasurement(key: ProcessKey(pid: pid, startTime: 1), parentPID: 1, uid: 502, name: name, cpuLoad: cpu,
                           memoryBytes: memory << 20, diskReadPerSecond: nil, diskWritePerSecond: nil, threadCount: nil)
    }
}
#endif
