/// Ein Prozess mit Raten. Raten sind `nil` bei der ersten Messung, nach einem Ausfall oder einer neu vergebenen PID –
/// die Oberfläche zeigt dann „–“, nie 0 (Spec §5).
public struct ProcessMeasurement: Hashable, Sendable, Identifiable {
    public let key: ProcessKey
    public let parentPID: Int32
    public let uid: UInt32
    public let name: String
    /// Anteil an allen Kernen (0…1; 100 % = alle Kerne voll, wie Windows 11).
    public let cpuLoad: Double?
    public let memoryBytes: UInt64?
    public let diskReadPerSecond: Double?
    public let diskWritePerSecond: Double?
    public let threadCount: Int?
    /// Programmpfad, nur bei eigenen Prozessen (`ProcessCounters.executablePath`).
    public let executablePath: String?
    /// CPU-Zeit seit Prozessstart (Benutzer + System) in Nanosekunden; `nil`, wenn nicht lesbar (andere Benutzer).
    public let cpuTimeNanoseconds: UInt64?
    /// Leistung aus `ri_energy_nj` in Milliwatt; `nil` bei Prozessen anderer Benutzer, ohne Apple Silicon und bei der
    /// ersten Messung.
    public let energyMilliwatts: Double?
    /// Gleitender Mittelwert der Leistung über rund zwei Minuten (`EnergyTrend`).
    public let energyTrendMilliwatts: Double?

    public var id: ProcessKey { key }

    public init(key: ProcessKey, parentPID: Int32, uid: UInt32, name: String, cpuLoad: Double?, memoryBytes: UInt64?,
                diskReadPerSecond: Double?, diskWritePerSecond: Double?, threadCount: Int?,
                executablePath: String? = nil, cpuTimeNanoseconds: UInt64? = nil, energyMilliwatts: Double? = nil,
                energyTrendMilliwatts: Double? = nil) {
        self.key = key
        self.parentPID = parentPID
        self.uid = uid
        self.name = name
        self.cpuLoad = cpuLoad
        self.memoryBytes = memoryBytes
        self.diskReadPerSecond = diskReadPerSecond
        self.diskWritePerSecond = diskWritePerSecond
        self.threadCount = threadCount
        self.executablePath = executablePath
        self.cpuTimeNanoseconds = cpuTimeNanoseconds
        self.energyMilliwatts = energyMilliwatts
        self.energyTrendMilliwatts = energyTrendMilliwatts
    }
}

public struct CoreLoad: Hashable, Sendable {
    public let kind: CoreKind
    /// 0…1.
    public let load: Double?

    public init(kind: CoreKind, load: Double?) {
        self.kind = kind
        self.load = load
    }
}

public struct CPULoad: Hashable, Sendable {
    /// Gesamtauslastung, nach Ticks gewichtet (0…1).
    public let total: Double?
    public let cores: [CoreLoad]
    /// Systemanteil an der Gesamtauslastung, ebenso gewichtet (0…1); Benutzer ist der Rest von `total`.
    public let system: Double?

    public init(total: Double?, cores: [CoreLoad], system: Double? = nil) {
        self.total = total
        self.cores = cores
        self.system = system
    }
}

public struct DriveThroughput: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let readPerSecond: Double?
    public let writePerSecond: Double?
    public let operationsPerSecond: Double?
    /// „Aktive Zeit“ wie Windows 11: Anteil der Zeit, in der das Laufwerk arbeitet (0…1).
    public let activeShare: Double?

    public init(id: String, name: String, readPerSecond: Double?, writePerSecond: Double?,
                operationsPerSecond: Double? = nil, activeShare: Double? = nil) {
        self.id = id
        self.name = name
        self.readPerSecond = readPerSecond
        self.writePerSecond = writePerSecond
        self.operationsPerSecond = operationsPerSecond
        self.activeShare = activeShare
    }
}

public struct InterfaceThroughput: Hashable, Sendable, Identifiable {
    public let name: String
    public let receivedPerSecond: Double?
    public let sentPerSecond: Double?
    public let displayName: String?
    public let addresses: [String]
    /// Schnittstelle der Default-Route (`InterfaceCounters.isPrimary`).
    public let isPrimary: Bool

    public var id: String { name }

    public init(name: String, receivedPerSecond: Double?, sentPerSecond: Double?, displayName: String? = nil,
                addresses: [String] = [], isPrimary: Bool = false) {
        self.name = name
        self.receivedPerSecond = receivedPerSecond
        self.sentPerSecond = sentPerSecond
        self.displayName = displayName
        self.addresses = addresses
        self.isPrimary = isPrimary
    }
}

/// Werte eines Takts. Leere Listen und `nil` heißen „nicht gemessen“; `unavailable` nennt eingerichtete Quellen, die
/// in diesem Takt ausgefallen sind.
public struct TaskManagerSnapshot: Equatable, Sendable {
    public var processes: [ProcessMeasurement] = []
    public var cpu: CPULoad?
    public var memory: MemoryStatus?
    public var drives: [DriveThroughput] = []
    public var interfaces: [InterfaceThroughput] = []
    public var gpu: GPULoadReading?
    public var battery: BatteryReading?
    /// Thermischer Zustand und Energiesparmodus aus `ThermalStateSource` (per Wechselbenachrichtigung, nicht je Takt
    /// gelesen); `nil`, wenn nicht gelesen.
    public var thermal: ThermalCondition?
    public var unavailable: Set<TaskManagerSource> = []

    public init() {}
}
