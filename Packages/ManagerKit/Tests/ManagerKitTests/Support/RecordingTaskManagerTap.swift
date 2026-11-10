@testable import ManagerKit

/// Merkt sich, was ein `TaskManagerTap` sieht: Laufbeginn, je Takt die gelesenen Datenträger-Bytes und die Rate, Ende.
final class RecordingTaskManagerTap: TaskManagerTap {
    enum Seen: Equatable, Sendable {
        case started
        case measured(readBytes: UInt64?, readPerSecond: Double?)
        case stopped
    }

    let seen = Recorder<Seen>()

    func taskManagerDidStart() { seen.append(.started) }

    func taskManagerDidMeasure(_ readings: TaskManagerReadings, frame: TaskManagerFrame) {
        let bytes = try? readings.disks?.get().first?.bytesRead
        seen.append(.measured(readBytes: bytes, readPerSecond: frame.snapshot.drives.first?.readPerSecond))
    }

    func taskManagerDidStop() { seen.append(.stopped) }
}
