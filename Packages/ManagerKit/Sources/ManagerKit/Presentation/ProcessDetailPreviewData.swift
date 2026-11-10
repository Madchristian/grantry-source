#if DEBUG
import Foundation

/// Fester Stand des Tabs „Details“ für SwiftUI-Previews und Snapshots – ohne Systemzugriff. Prozesse wie
/// `ProcessListPreviewData` (fremde mit Werten aus `ps`), dazu Startzeit, CPU-Zeit und eine Minute CPU-Verlauf.
public enum ProcessDetailPreviewData {
    public static let currentUID = ProcessListPreviewData.currentUID
    public static let physicalMemory = ProcessListPreviewData.physicalMemory
    /// Zeitpunkt des letzten Takts (Bezug von Startzeit und Verlauf).
    public static let measuredAt = Date(timeIntervalSince1970: 1_793_000_000)
    public static let userNames: [UInt32: String] = [501: "mara", 0: "root", 88: "_windowserver"]

    public static var snapshot: TaskManagerSnapshot {
        var snapshot = ProcessListPreviewData.snapshot
            .fillingForeignUsage(ProcessListPreviewData.foreignUsage, currentUID: currentUID)
        snapshot.processes = snapshot.processes.enumerated().map { index, process in
            let started = measuredAt.addingTimeInterval(-Double(index + 1) * 2_917)
            let isOwn = process.uid == currentUID
            return ProcessMeasurement(
                key: ProcessKey(pid: process.key.pid, startTime: UInt64(started.timeIntervalSince1970 * 1_000_000)),
                parentPID: process.parentPID, uid: process.uid, name: process.name, cpuLoad: process.cpuLoad,
                memoryBytes: process.memoryBytes, diskReadPerSecond: process.diskReadPerSecond,
                diskWritePerSecond: process.diskWritePerSecond, threadCount: isOwn ? 4 + index * 3 : nil,
                executablePath: process.executablePath,
                cpuTimeNanoseconds: isOwn ? UInt64(Double(index + 1) * 1_917 * (process.cpuLoad ?? 0) * 1e9) : nil
            )
        }
        return snapshot
    }

    /// Eine Minute CPU je Prozess im Sekundentakt: Wellen um den aktuellen Wert, je Prozess versetzt. Wie im Betrieb
    /// nur für Prozesse mit eigener Messung (`proc_pid_rusage`); fremde Prozesse haben keinen Verlauf.
    public static var history: SampleHistory {
        var history = SampleHistory(interval: .seconds(1))
        let processes = snapshot.processes.filter { $0.uid == currentUID }
        for tick in 0..<60 {
            var values: [MetricKey: Double] = [:]
            for (index, process) in processes.enumerated() {
                let wave = sin(Double(tick) / (3 + Double(index % 4)) + Double(index)) * 0.6
                    + sin(Double(tick) / 1.7 + Double(index) * 2) * 0.25
                values[.processCPU(process.key)] = max(0, (process.cpuLoad ?? 0) * (1 + wave))
            }
            history.record(values)
        }
        return history
    }

    public static func presentation(_ options: ProcessDetailOptions = ProcessDetailOptions()) -> ProcessDetailPresentation {
        ProcessDetailPresenter.present(snapshot, currentUID: currentUID, options: options,
                                       userName: { userNames[$0] ?? String($0) }, physicalMemory: physicalMemory)
    }
}
#endif
