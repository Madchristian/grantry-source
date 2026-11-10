import Darwin

/// CPU-Ticks je Kern (Spec 2026-11-06 §3) über `host_processor_info`; Kerntypen aus `ChipProfile` (Gerätebaum, auf
/// Ultra mit verschränkten Nummern). Die Kerntypen stehen nach der ersten Messung fest – gelesen werden sie abseits
/// des Main Actors –, danach wird nur der Zählerpuffer gelesen.
public struct CPULoadSampler: MetricSource {
    struct ReadFailure: Error, Equatable {
        let code: kern_return_t
    }

    private static let systemKinds = ChipProfile.current.coreKinds(coreCount: Sysctl.int("hw.ncpu") ?? 0)

    public init() {}

    public func read() throws -> CPULoadReading {
        let kinds = Self.systemKinds
        var processorCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &processorCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { throw ReadFailure(code: result) }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let ticks = UnsafeBufferPointer(start: info, count: Int(infoCount)).map { UInt32(bitPattern: $0) }
        return CPULoadReading(cores: Self.cores(ticks: ticks, kinds: kinds))
    }

    /// Ticks je Kern in der Reihenfolge `CPU_STATE_USER`, `SYSTEM`, `IDLE`, `NICE`; „belegt“ = alles außer Leerlauf,
    /// dazu der Systemanteil.
    static func cores(ticks: [UInt32], kinds: [CoreKind]) -> [CoreTicks] {
        let stride = Int(CPU_STATE_MAX)
        return (0..<(ticks.count / stride)).map { core in
            let state = { (index: Int32) in UInt64(ticks[core * stride + Int(index)]) }
            return CoreTicks(kind: kinds.indices.contains(core) ? kinds[core] : .unknown,
                             busy: state(CPU_STATE_USER) + state(CPU_STATE_SYSTEM) + state(CPU_STATE_NICE),
                             idle: state(CPU_STATE_IDLE), system: state(CPU_STATE_SYSTEM))
        }
    }
}
