import Darwin

/// Speicherstand für den Task-Manager (Spec 2026-11-06 §3): das vorhandene `MemoryStatus.current` mit der Zahl aller
/// Prozesse. Teilt sich die Lesefunktionen mit dem Segment „Prozesse“ (DRY).
public struct MemorySource: MetricSource {
    public init() {}

    public func read() throws -> MemoryStatus {
        MemoryStatus.current(processCount: Self.processCount())
    }

    /// Prozesse laut Kernel (`proc_listallpids` ohne Puffer); 0, wenn nicht lesbar.
    static func processCount() -> Int {
        max(0, Int(proc_listallpids(nil, 0)))
    }
}
