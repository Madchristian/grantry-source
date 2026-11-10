import Darwin
import Foundation

/// Arbeitsspeicher, Swap und Speicherdruck für das Segment „Prozesse“ (#221) und den Task-Manager (Spec 2026-11-06
/// §2). Werte, die nicht lesbar sind, bleiben `nil`.
public struct MemoryStatus: Hashable, Sendable {
    public enum Pressure: Hashable, Sendable {
        case normal, warning, critical
    }

    public let physicalBytes: UInt64
    /// Wie „Benutzter Speicher“ der Aktivitätsanzeige: App-Speicher, fest zugeordnet und komprimiert.
    public let usedBytes: UInt64?
    public let swapUsedBytes: UInt64?
    public let swapTotalBytes: UInt64?
    public let pressure: Pressure?
    public let processCount: Int
    /// Aufteilung für die Speicheranzeige des Task-Managers; `nil`, wenn nicht lesbar.
    public let components: MemoryComponents?

    public init(physicalBytes: UInt64, usedBytes: UInt64?, swapUsedBytes: UInt64?, swapTotalBytes: UInt64?,
                pressure: Pressure?, processCount: Int, components: MemoryComponents? = nil) {
        self.physicalBytes = physicalBytes
        self.usedBytes = usedBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.pressure = pressure
        self.processCount = processCount
        self.components = components
    }

    /// Jetzt gelesen; `processCount` aus der Prozesstabelle.
    public static func current(processCount: Int) -> MemoryStatus {
        let swap = swapUsage()
        let components = vmStatistics().map { MemoryComponents(statistics: $0, pageSize: UInt64(getpagesize())) }
        return MemoryStatus(
            physicalBytes: ProcessInfo.processInfo.physicalMemory, usedBytes: components?.usedBytes,
            swapUsedBytes: swap?.xsu_used, swapTotalBytes: swap?.xsu_total,
            pressure: pressureLevel().flatMap(pressure(level:)), processCount: processCount, components: components
        )
    }

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 Warnung, 4 kritisch.
    static func pressure(level: Int32) -> Pressure? {
        switch level {
        case 1: .normal
        case 2: .warning
        case 4: .critical
        default: nil
        }
    }

    private static func swapUsage() -> xsw_usage? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 ? usage : nil
    }

    private static func pressureLevel() -> Int32? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 ? level : nil
    }

    private static func vmStatistics() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? stats : nil
    }
}

/// Bestandteile des Arbeitsspeichers wie in der Aktivitätsanzeige (`host_statistics64`).
public struct MemoryComponents: Hashable, Sendable {
    public enum Kind: Hashable, Sendable, CaseIterable {
        /// App-Speicher: anonyme Seiten ohne die löschbaren.
        case app
        /// Fest zugeordnet (`wire_count`).
        case wired
        /// Vom Kompressor belegt.
        case compressed
        /// Zwischengespeicherte Dateien: dateigestützte und löschbare Seiten.
        case cached
    }

    public let appBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let cachedBytes: UInt64

    public init(appBytes: UInt64, wiredBytes: UInt64, compressedBytes: UInt64, cachedBytes: UInt64) {
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedBytes = cachedBytes
    }

    init(statistics stats: vm_statistics64, pageSize: UInt64) {
        let anonymous = UInt64(stats.internal_page_count), purgeable = UInt64(stats.purgeable_count)
        self.init(appBytes: (anonymous - min(purgeable, anonymous)) * pageSize,
                  wiredBytes: UInt64(stats.wire_count) * pageSize,
                  compressedBytes: UInt64(stats.compressor_page_count) * pageSize,
                  cachedBytes: (UInt64(stats.external_page_count) + purgeable) * pageSize)
    }

    /// „Benutzter Speicher“: App, zugeordnet und komprimiert (ohne Cache).
    public var usedBytes: UInt64 { appBytes + wiredBytes + compressedBytes }

    public subscript(kind: Kind) -> UInt64 {
        switch kind {
        case .app: appBytes
        case .wired: wiredBytes
        case .compressed: compressedBytes
        case .cached: cachedBytes
        }
    }
}
