import Foundation

/// Ein fertiger Stand für die Oberfläche: Werte des Takts und Verlauf.
public struct TaskManagerFrame: Equatable, Sendable {
    public var snapshot: TaskManagerSnapshot
    public var history: SampleHistory
    /// Zeit seit dem vorigen Takt; `nil` beim ersten. Grundlage des App-Verlaufs (Rate × Zeit).
    public var elapsed: Duration?

    public init(snapshot: TaskManagerSnapshot, history: SampleHistory, elapsed: Duration? = nil) {
        self.snapshot = snapshot
        self.history = history
        self.elapsed = elapsed
    }

    public static func empty(interval: TaskManagerInterval) -> TaskManagerFrame {
        TaskManagerFrame(snapshot: TaskManagerSnapshot(), history: SampleHistory(interval: interval.duration))
    }
}

/// Macht aus aufeinanderfolgenden Rohmessungen Raten, Auslastungen und Verlauf (Spec §3, §5). Rein und ohne Uhr: Die
/// verstrichene Zeit kommt von außen.
///
/// - Raten entstehen nur zwischen zwei erfolgreichen Messungen derselben Quelle; nach einem Ausfall ist die nächste
///   Messung wieder Basis.
/// - Prozesse gelten unter `ProcessKey` (PID + Startzeit): Eine neu vergebene PID erbt keine Zahlen.
/// - Prozess-CPU bezieht sich auf alle Kerne (100 % = alle voll, wie Windows 11); Kernzahl aus der CPU-Messung, ohne sie
///   `fallbackCoreCount`.
public struct TaskManagerAccumulator: Sendable {
    private struct Previous: Sendable {
        var processes: [ProcessKey: ProcessCounters] = [:]
        var cores: [CoreTicks]?
        var drives: [String: DriveCounters] = [:]
        var interfaces: [String: InterfaceCounters] = [:]
        /// Trend der Leistung je Prozess (`EnergyTrend`).
        var energyTrends: [ProcessKey: Double] = [:]
    }

    private let fallbackCoreCount: Int
    private var previous = Previous()
    private var history: SampleHistory
    private var recordsHistory = true

    /// - Parameter history: Verlauf eines früheren Laufs mit demselben Takt, der fortgesetzt wird; sonst beginnt er leer.
    public init(interval: TaskManagerInterval,
                fallbackCoreCount: Int = ProcessInfo.processInfo.activeProcessorCount, history: SampleHistory? = nil) {
        self.fallbackCoreCount = fallbackCoreCount
        self.history = history.flatMap { $0.interval == interval.duration ? $0 : nil }
            ?? SampleHistory(interval: interval.duration)
    }

    /// Nur Raten und Auslastungen, ohne Verlauf je Metrik – für den Wachbuch-Takt (TM-12.3), der den Verlauf selbst
    /// führt. `TaskManagerFrame.history` bleibt dann leer.
    static func withoutHistory(
        fallbackCoreCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> TaskManagerAccumulator {
        var accumulator = TaskManagerAccumulator(interval: .default, fallbackCoreCount: fallbackCoreCount)
        accumulator.recordsHistory = false
        return accumulator
    }

    /// - Parameter elapsed: Zeit seit der letzten Messung; `nil` bei der ersten.
    public mutating func ingest(_ readings: TaskManagerReadings, elapsed: Duration?) -> TaskManagerFrame {
        var snapshot = TaskManagerSnapshot()
        var next = Previous()
        var metrics: [MetricKey: Double] = [:]
        let earlier = elapsed == nil ? Previous() : previous

        if let cores = Self.value(readings.cpu, .cpu, in: &snapshot)?.cores {
            let cpu = Self.cpuLoad(cores, earlier: earlier.cores)
            snapshot.cpu = cpu
            metrics[.cpuTotal] = cpu.total
            metrics[.cpuSystem] = cpu.system
            for (index, core) in cpu.cores.enumerated() { metrics[.cpuCore(index)] = core.load }
            next.cores = cores
        }
        let coreCount = next.cores?.count ?? fallbackCoreCount
        if let processes = Self.value(readings.processes, .processes, in: &snapshot) {
            snapshot.processes = processes.map {
                Self.measurement($0, earlier: earlier.processes[$0.key], trend: earlier.energyTrends[$0.key],
                                 elapsed: elapsed, coreCount: coreCount)
            }
            // Je Prozess nur für den Verlauf; ohne ihn (Wachbuch-Takt) spart das je Takt einen Eintrag je Prozess (#530).
            if recordsHistory {
                for process in snapshot.processes { metrics[.processCPU(process.key)] = process.cpuLoad }
            }
            let energy = snapshot.processes.compactMap(\.energyMilliwatts)
            if !energy.isEmpty { metrics[.energyTotal] = energy.reduce(0, +) }
            next.processes = Dictionary(processes.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            next.energyTrends = Dictionary(snapshot.processes.compactMap { process in
                process.energyTrendMilliwatts.map { (process.key, $0) }
            }, uniquingKeysWith: { first, _ in first })
        }
        if let memory = Self.value(readings.memory, .memory, in: &snapshot) {
            snapshot.memory = memory
            // Nicht `.map(Double.init)`: Das wählt `Double(bitPattern:)` und macht aus 8 Byte 4e-323.
            metrics[.memoryUsed] = memory.usedBytes.map { Double($0) }
            for kind in MemoryComponents.Kind.allCases {
                metrics[.memory(kind)] = memory.components.map { Double($0[kind]) }
            }
        }
        if let drives = Self.value(readings.disks, .disks, in: &snapshot) {
            snapshot.drives = drives.map { drive in
                let old = earlier.drives[drive.id]
                let busy = drive.busyNanoseconds.flatMap { Self.rate(old?.busyNanoseconds, $0, elapsed) }
                return DriveThroughput(id: drive.id, name: drive.name,
                                       readPerSecond: Self.rate(old?.bytesRead, drive.bytesRead, elapsed),
                                       writePerSecond: Self.rate(old?.bytesWritten, drive.bytesWritten, elapsed),
                                       operationsPerSecond: drive.operations.flatMap {
                                           Self.rate(old?.operations, $0, elapsed)
                                       },
                                       // Parallele Vorgänge summieren sich über die Wanduhr hinaus.
                                       activeShare: busy.map { min($0 / 1_000_000_000, 1) })
            }
            for drive in snapshot.drives {
                metrics[.diskRead(drive.id)] = drive.readPerSecond
                metrics[.diskWrite(drive.id)] = drive.writePerSecond
            }
            next.drives = Dictionary(drives.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        if let interfaces = Self.value(readings.interfaces, .interfaces, in: &snapshot) {
            snapshot.interfaces = interfaces.map { interface in
                let old = earlier.interfaces[interface.name]
                return InterfaceThroughput(
                    name: interface.name,
                    receivedPerSecond: Self.rate(old?.bytesReceived, interface.bytesReceived, elapsed),
                    sentPerSecond: Self.rate(old?.bytesSent, interface.bytesSent, elapsed),
                    displayName: interface.displayName, addresses: interface.addresses,
                    isPrimary: interface.isPrimary
                )
            }
            for interface in snapshot.interfaces {
                metrics[.received(interface.name)] = interface.receivedPerSecond
                metrics[.sent(interface.name)] = interface.sentPerSecond
            }
            next.interfaces = Dictionary(interfaces.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        }
        if let gpu = Self.value(readings.gpu, .gpu, in: &snapshot) {
            snapshot.gpu = gpu
            metrics[.gpu] = gpu.utilization
        }
        if let battery = Self.value(readings.battery, .battery, in: &snapshot) {
            snapshot.battery = battery
            metrics[.batteryCharge] = battery.charge
            metrics[.systemPower] = battery.systemMilliwatts
        }

        previous = next
        if recordsHistory { history.record(metrics) }
        return TaskManagerFrame(snapshot: snapshot, history: history, elapsed: elapsed)
    }

    /// Wert einer erfolgreichen Quelle; eine ausgefallene trägt sich in `unavailable` ein.
    private static func value<Reading>(_ result: Result<Reading, any Error>?, _ source: TaskManagerSource,
                                       in snapshot: inout TaskManagerSnapshot) -> Reading? {
        switch result {
        case .success(let reading)?:
            return reading
        case .failure?:
            snapshot.unavailable.insert(source)
            return nil
        case nil:
            return nil
        }
    }

    private static func cpuLoad(_ cores: [CoreTicks], earlier: [CoreTicks]?) -> CPULoad {
        let comparable = earlier.flatMap { $0.count == cores.count ? $0 : nil }
        let loads = cores.enumerated().map { index, ticks in
            CoreLoad(kind: ticks.kind, load: comparable.flatMap { RateCalculator.load(from: $0[index], to: ticks) })
        }
        let total = comparable.flatMap { RateCalculator.load(from: .sum($0), to: .sum(cores)) }
        let system = comparable.flatMap { RateCalculator.systemShare(from: .sum($0), to: .sum(cores)) }
        return CPULoad(total: total, cores: loads, system: system)
    }

    /// - Parameter trend: bisheriger Leistungstrend dieses Prozesses (`EnergyTrend`).
    private static func measurement(_ counters: ProcessCounters, earlier: ProcessCounters?, trend: Double?,
                                    elapsed: Duration?, coreCount: Int) -> ProcessMeasurement {
        var cpuLoad: Double?
        if let previous = earlier?.cpuTimeNanoseconds, let current = counters.cpuTimeNanoseconds, let elapsed {
            cpuLoad = RateCalculator.processLoad(fromNanoseconds: previous, to: current, over: elapsed,
                                                 coreCount: coreCount)
        }
        // Nanojoule je Sekunde → Milliwatt.
        let energy = rate(earlier?.energyNanojoules, counters.energyNanojoules, elapsed).map { $0 / 1_000_000 }
        return ProcessMeasurement(
            key: counters.key, parentPID: counters.parentPID, uid: counters.uid, name: counters.name,
            cpuLoad: cpuLoad, memoryBytes: counters.memoryBytes,
            diskReadPerSecond: rate(earlier?.diskBytesRead, counters.diskBytesRead, elapsed),
            diskWritePerSecond: rate(earlier?.diskBytesWritten, counters.diskBytesWritten, elapsed),
            threadCount: counters.threadCount, executablePath: counters.executablePath,
            cpuTimeNanoseconds: counters.cpuTimeNanoseconds,
            energyMilliwatts: energy, energyTrendMilliwatts: EnergyTrend.next(trend, energy, elapsed: elapsed)
        )
    }

    private static func rate(_ previous: UInt64?, _ current: UInt64?, _ elapsed: Duration?) -> Double? {
        guard let previous, let current, let elapsed else { return nil }
        return RateCalculator.perSecond(from: previous, to: current, over: elapsed)
    }
}
