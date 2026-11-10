/// Ergebnisse eines Takts je Quelle; `nil` = Quelle nicht eingerichtet.
public struct TaskManagerReadings: Sendable {
    public var processes: Result<[ProcessCounters], any Error>?
    public var cpu: Result<CPULoadReading, any Error>?
    public var memory: Result<MemoryStatus, any Error>?
    public var disks: Result<[DriveCounters], any Error>?
    public var interfaces: Result<[InterfaceCounters], any Error>?
    public var gpu: Result<GPULoadReading, any Error>?
    public var battery: Result<BatteryReading, any Error>?

    public init(
        processes: Result<[ProcessCounters], any Error>? = nil,
        cpu: Result<CPULoadReading, any Error>? = nil,
        memory: Result<MemoryStatus, any Error>? = nil,
        disks: Result<[DriveCounters], any Error>? = nil,
        interfaces: Result<[InterfaceCounters], any Error>? = nil,
        gpu: Result<GPULoadReading, any Error>? = nil,
        battery: Result<BatteryReading, any Error>? = nil
    ) {
        self.processes = processes
        self.cpu = cpu
        self.memory = memory
        self.disks = disks
        self.interfaces = interfaces
        self.gpu = gpu
        self.battery = battery
    }

    /// Liest alle eingerichteten Quellen nebenläufig; eine werfende Quelle betrifft nur ihr eigenes Ergebnis.
    static func read(_ sources: TaskManagerSources) async -> TaskManagerReadings {
        async let processes = read(sources.processes)
        async let cpu = read(sources.cpu)
        async let memory = read(sources.memory)
        async let disks = read(sources.disks)
        async let interfaces = read(sources.interfaces)
        async let gpu = read(sources.gpu)
        async let battery = read(sources.battery)
        return await TaskManagerReadings(processes: processes, cpu: cpu, memory: memory, disks: disks,
                                         interfaces: interfaces, gpu: gpu, battery: battery)
    }

    /// Liest alle eingerichteten Quellen nacheinander in einem Task außerhalb des Aufrufers – für den Wachbuch-Takt im
    /// Hintergrund (#530): Er wartet auf niemanden, und gedrosselt kostet jeder Kind-Task samt Threadwechsel messbar.
    @concurrent
    static func readSequentially(_ sources: TaskManagerSources) async -> TaskManagerReadings {
        TaskManagerReadings(processes: result(sources.processes), cpu: result(sources.cpu), memory: result(sources.memory),
                            disks: result(sources.disks), interfaces: result(sources.interfaces), gpu: result(sources.gpu),
                            battery: result(sources.battery))
    }

    private static func result<Reading: Sendable>(_ source: (any MetricSource<Reading>)?) -> Result<Reading, any Error>? {
        guard let source else { return nil }
        return Result { try source.read() }
    }

    @concurrent
    private static func read<Reading: Sendable>(_ source: (any MetricSource<Reading>)?) async
        -> Result<Reading, any Error>? {
        result(source)
    }

    /// Ausgefallene Quellen dieses Takts mit ihrem Fehler.
    var failures: [(TaskManagerSource, any Error)] {
        let all: [(TaskManagerSource, (any Error)?)] = [
            (.processes, Self.error(processes)), (.cpu, Self.error(cpu)), (.memory, Self.error(memory)),
            (.disks, Self.error(disks)), (.interfaces, Self.error(interfaces)), (.gpu, Self.error(gpu)),
            (.battery, Self.error(battery)),
        ]
        return all.compactMap { source, error in error.map { (source, $0) } }
    }

    private static func error<Reading>(_ result: Result<Reading, any Error>?) -> (any Error)? {
        if case .failure(let error)? = result { error } else { nil }
    }
}
