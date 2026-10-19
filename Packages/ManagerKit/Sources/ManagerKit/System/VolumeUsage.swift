import Foundation

/// Kapazität und freier Platz des Volumes, auf dem ein Pfad liegt (#226). Belegt ist alles, was nicht frei ist –
/// auch, was macOS bei Bedarf selbst freigibt (lokale Snapshots, Caches).
public struct VolumeUsage: Hashable, Sendable {
    public let totalBytes: Int64
    public let availableBytes: Int64

    public init(totalBytes: Int64, availableBytes: Int64) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    public var usedBytes: Int64 { max(0, totalBytes - availableBytes) }

    /// `nil`, wenn das Volume nichts meldet. Dateisystemabfrage, daher außerhalb des Aufrufer-Actors.
    @concurrent
    public static func of(_ path: String) async -> VolumeUsage? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        guard let values = try? URL(filePath: path).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity, total > 0 else {
            return nil
        }
        return VolumeUsage(totalBytes: Int64(total), availableBytes: Int64(available))
    }
}
