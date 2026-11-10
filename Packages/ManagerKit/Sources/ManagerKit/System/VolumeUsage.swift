import Foundation

/// Kapazität und freier Platz des Volumes, auf dem ein Pfad liegt (#226). Belegt ist alles, was nicht frei ist –
/// auch, was macOS bei Bedarf selbst freigibt (lokale Snapshots, Caches); diesen Anteil nennt `purgeableBytes` (#400).
public struct VolumeUsage: Hashable, Sendable {
    public let totalBytes: Int64
    public let availableBytes: Int64
    /// Frei für wichtige Nutzung (`volumeAvailableCapacityForImportantUsage`): frei plus, was macOS bei Bedarf
    /// freigibt; `nil`, wenn nicht gemessen.
    public let importantUsageAvailableBytes: Int64?

    public init(totalBytes: Int64, availableBytes: Int64, importantUsageAvailableBytes: Int64? = nil) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.importantUsageAvailableBytes = importantUsageAvailableBytes
    }

    public var usedBytes: Int64 { max(0, totalBytes - availableBytes) }

    /// Was macOS zusätzlich freigeben kann, nie negativ; `nil` ohne Messung.
    public var purgeableBytes: Int64? { importantUsageAvailableBytes.map { max(0, $0 - availableBytes) } }

    /// `nil`, wenn das Volume nichts meldet. Dateisystemabfrage, daher außerhalb des Aufrufer-Actors.
    @concurrent
    public static func of(_ path: String) async -> VolumeUsage? {
        read(path, includingPurgeable: false)
    }

    /// Synchrone Abfrage; `includingPurgeable` misst zusätzlich den bereinigbaren Platz (kann dauern, daher nur auf
    /// Wunsch und mit Frist, siehe `VolumeInventorySource`).
    static func read(_ path: String, includingPurgeable: Bool) -> VolumeUsage? {
        var keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        if includingPurgeable { keys.insert(.volumeAvailableCapacityForImportantUsageKey) }
        guard let values = try? URL(filePath: path).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity, total > 0 else {
            return nil
        }
        return VolumeUsage(totalBytes: Int64(total), availableBytes: Int64(available),
                           importantUsageAvailableBytes: values.volumeAvailableCapacityForImportantUsage)
    }
}
