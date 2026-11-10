/// Eine Messquelle des Task-Managers (Spec 2026-11-06 §3): liefert bei jedem Aufruf den aktuellen Stand – Zähler
/// kumulativ, Auslastungen als Momentwert. Raten bildet erst `TaskManagerAccumulator`. `read()` darf kurz blockieren
/// (Syscalls, IOKit) und läuft nie auf dem Main Actor.
public protocol MetricSource<Reading>: Sendable {
    associatedtype Reading: Sendable
    func read() throws -> Reading
}

/// Die Quellen des Task-Managers, etwa für „ausgefallen“-Hinweise und das Ausblenden von Kacheln.
public enum TaskManagerSource: String, Hashable, Sendable, CaseIterable {
    case processes, cpu, memory, disks, interfaces, gpu, battery
}

/// Eingerichtete Quellen; eine fehlende (`nil`) liefert keine Werte – ihre Kachel blendet die Oberfläche aus.
public struct TaskManagerSources: Sendable {
    public var processes: (any MetricSource<[ProcessCounters]>)?
    public var cpu: (any MetricSource<CPULoadReading>)?
    public var memory: (any MetricSource<MemoryStatus>)?
    public var disks: (any MetricSource<[DriveCounters]>)?
    public var interfaces: (any MetricSource<[InterfaceCounters]>)?
    public var gpu: (any MetricSource<GPULoadReading>)?
    public var battery: (any MetricSource<BatteryReading>)?

    public init(
        processes: (any MetricSource<[ProcessCounters]>)? = nil,
        cpu: (any MetricSource<CPULoadReading>)? = nil,
        memory: (any MetricSource<MemoryStatus>)? = nil,
        disks: (any MetricSource<[DriveCounters]>)? = nil,
        interfaces: (any MetricSource<[InterfaceCounters]>)? = nil,
        gpu: (any MetricSource<GPULoadReading>)? = nil,
        battery: (any MetricSource<BatteryReading>)? = nil
    ) {
        self.processes = processes
        self.cpu = cpu
        self.memory = memory
        self.disks = disks
        self.interfaces = interfaces
        self.gpu = gpu
        self.battery = battery
    }

    /// Quellen der App: Prozesse seit TM3; TM4 (Leistung) misst CPU, Speicher, Laufwerke, Netz und die GPU, TM8 den
    /// Akku. Die GPU-Quelle prüft ihre Lesbarkeit erst im Messtakt (siehe `GPULoadSampler`); die Akku-Quelle gibt es
    /// nur auf Macs mit Akku und wird dafür einmalig beim Erzeugen gelesen (`BatterySampler.ifAvailable()`, rund 0,3 ms).
    public static let system = TaskManagerSources(
        processes: ProcessUsageSampler(),
        cpu: CPULoadSampler(),
        memory: MemorySource(),
        disks: DiskThroughputSampler(),
        interfaces: InterfaceThroughputSampler(),
        gpu: GPULoadSampler(),
        battery: BatterySampler.ifAvailable()
    )

    /// Quellen des Wachbuch-Takts (TM-12.3): wie `system`, Prozesse und Akku aber nur mit dem, was das Wachbuch führt
    /// (`ProcessUsageSampler.ownLoad`, `BatterySampler.chargeAndSource`). Ohne Fenster läuft der Takt gedrosselt; dort
    /// kostete der volle Satz rund doppelt so viel (#530).
    public static let watchbook = TaskManagerSources(
        processes: ProcessUsageSampler.ownLoad(), cpu: system.cpu, memory: system.memory, disks: system.disks,
        interfaces: system.interfaces, gpu: system.gpu, battery: system.battery.map { _ in BatterySampler.chargeAndSource() }
    )

    public var configured: Set<TaskManagerSource> {
        let present: [(TaskManagerSource, Bool)] = [
            (.processes, processes != nil), (.cpu, cpu != nil), (.memory, memory != nil),
            (.disks, disks != nil), (.interfaces, interfaces != nil), (.gpu, gpu != nil), (.battery, battery != nil),
        ]
        return Set(present.filter(\.1).map(\.0))
    }
}
