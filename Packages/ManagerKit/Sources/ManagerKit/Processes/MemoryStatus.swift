import Darwin
import Foundation

/// Arbeitsspeicher, Swap und Speicherdruck für das Segment „Prozesse“ (#221). Werte, die nicht lesbar sind, bleiben
/// `nil`.
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

    public init(physicalBytes: UInt64, usedBytes: UInt64?, swapUsedBytes: UInt64?, swapTotalBytes: UInt64?,
                pressure: Pressure?, processCount: Int) {
        self.physicalBytes = physicalBytes
        self.usedBytes = usedBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.pressure = pressure
        self.processCount = processCount
    }

    /// Jetzt gelesen; `processCount` aus der Prozesstabelle.
    public static func current(processCount: Int) -> MemoryStatus {
        let swap = swapUsage()
        return MemoryStatus(
            physicalBytes: ProcessInfo.processInfo.physicalMemory, usedBytes: usedMemory(),
            swapUsedBytes: swap?.xsu_used, swapTotalBytes: swap?.xsu_total,
            pressure: pressureLevel().flatMap(pressure(level:)), processCount: processCount
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

    private static func usedMemory() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pageSize = UInt64(getpagesize())
        let appPages = UInt64(stats.internal_page_count) - min(UInt64(stats.purgeable_count), UInt64(stats.internal_page_count))
        return (appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
    }
}
